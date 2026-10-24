terraform {
  # >= 1.10 for S3-native state locking (use_lockfile), no DynamoDB lock table.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # Partial configuration; values come from backend.hcl (see backend.hcl.example).
  backend "s3" {}
}

locals {
  default_tags = {
    Project    = var.project
    ManagedBy  = "terraform"
    Repository = "github.com/Monkmode-tech/aws-multi-region-dr"
    Owner      = var.owner
  }
}

# Primary region - serves traffic while healthy.
provider "aws" {
  region = var.primary_region

  default_tags {
    tags = merge(local.default_tags, { Role = "primary" })
  }
}

# DR region - warm standby that takes traffic on failover. It is also
# us-east-1, where Route 53 publishes health-check metrics.
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = merge(local.default_tags, { Role = "dr" })
  }
}
