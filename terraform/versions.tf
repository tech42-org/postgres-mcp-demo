terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    # All account-specific values are supplied via:
    #   terraform init -backend-config=backend.hcl
    encrypt = true
  }

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }

    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
