data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  vpc_name = "${data.terraform_remote_state.env.outputs.project}-vpc"

  az_count = 4
  azs      = slice(data.aws_availability_zones.available.names, 0, min(local.az_count, length(data.aws_availability_zones.available.names)))

  # 10.20.0.0/16 → /19 subnet (실제 사용 AZ 수 * 2개)
  vpc_cidr        = data.terraform_remote_state.env.outputs.vpc_cidr
  public_subnets  = [for i in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 3, i)]
  private_subnets = [for i in range(length(local.azs)) : cidrsubnet(local.vpc_cidr, 3, i + length(local.azs))]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = local.vpc_name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = true   # 비용 때문에 NAT 1개만 사용
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # VPC + IGW + RT + NAT + EIP 전반 태그
  tags = merge(
    data.terraform_remote_state.env.outputs.default_tags,
    { Name = local.vpc_name }
  )

  # Public Subnet (ALB용)
  public_subnet_tags = merge(
    data.terraform_remote_state.env.outputs.default_tags,
    {
      Name                                        = "${local.vpc_name}-public"
      "kubernetes.io/role/elb"                    = "1"
      "kubernetes.io/cluster/${data.terraform_remote_state.env.outputs.cluster_name}" = "shared"
    }
  )

  # Private Subnet (EKS Pod / Internal ALB, Karpenter discovery)
  private_subnet_tags = merge(
    data.terraform_remote_state.env.outputs.default_tags,
    {
      Name                                        = "${local.vpc_name}-private"
      "kubernetes.io/role/internal-elb"           = "1"
      "kubernetes.io/cluster/${data.terraform_remote_state.env.outputs.cluster_name}" = "shared"
      "karpenter.sh/discovery"                   = data.terraform_remote_state.env.outputs.cluster_name
    }
  )
}

# -----------------------------------------------------------------------------
# VPC Endpoints: S3 / ECR → NAT Gateway 우회 (비용 절감)
# -----------------------------------------------------------------------------
# - S3 Gateway: 무료. S3 접근 + ECR 이미지 레이어 풀에 사용
# - ECR API/DKR: Interface 엔드포인트. ecr get-login, docker pull 시 NAT 미경유
# -----------------------------------------------------------------------------

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "6.6.0"

  vpc_id               = module.vpc.vpc_id
  create_security_group = true # Interface 엔드포인트용 SG 자동 생성 (VPC CIDR → 443 허용)

  endpoints = {
    # S3: Gateway (무료). Private RT에 라우트 추가 → S3 트래픽이 NAT 대신 엔드포인트로
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags            = { Name = "${local.vpc_name}-s3" }
    }

    # ECR API: ecr get-login, describe 등 API 호출
    ecr_api = {
      service            = "ecr.api"
      private_dns_enabled = true
      subnet_ids         = module.vpc.private_subnets
      tags               = { Name = "${local.vpc_name}-ecr-api" }
    }

    # ECR DKR: Docker registry API (이미지 메타데이터). 레이어 데이터는 S3 Gateway로
    ecr_dkr = {
      service            = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids         = module.vpc.private_subnets
      tags               = { Name = "${local.vpc_name}-ecr-dkr" }
    }
  }

  tags = merge(
    data.terraform_remote_state.env.outputs.default_tags,
    { Name = "${local.vpc_name}-endpoints" }
  )
}
