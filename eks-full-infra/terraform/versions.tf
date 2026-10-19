terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  # Local state by default. For a team, store the state in S3 (state locking is built in):
  # backend "s3" {
  #   bucket       = "<your-tfstate-bucket>"
  #   key          = "eks-full-infra/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}
