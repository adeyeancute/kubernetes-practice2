data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  # nodes and pods live in the private subnets, load balancers in the public ones
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 3, i)]      # /19 each
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 6, 48 + i)] # /22 each

  enable_nat_gateway = true
  single_nat_gateway = true # one NAT for the whole VPC: cheaper, fine for non-prod

  # tags read by the AWS Load Balancer Controller to place load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
