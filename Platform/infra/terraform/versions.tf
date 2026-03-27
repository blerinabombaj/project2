# versions.tf
#
# Two things live here:
#   1. terraform block  — which providers to use and what versions
#   2. backend block    — where to store state (our S3 bucket from bootstrap)
#
# WHY PIN VERSIONS?
#   Provider updates can introduce breaking changes. If you don't pin versions,
#   a `terraform init` on a fresh machine 6 months later might pull a newer
#   provider that breaks your config. Pinning makes runs reproducible.
#   "~> 5.0" means: >= 5.0, < 6.0. Patch updates are allowed, major are not.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ── Remote backend ──────────────────────────────────────────────────────────
  #
  # After running bootstrap/, paste the output values here.
  # This tells Terraform: "store your state file in S3, not locally".
  #
  # WHY REMOTE STATE?
  #   - Survives laptop death / disk wipe
  #   - Team members can all run Terraform against the same state
  #   - State locking via DynamoDB prevents concurrent applies
  #
  # NOTE: The backend block cannot use variables — values must be hardcoded.
  #       This is a known Terraform limitation. Terragrunt (step 3) solves this.

  backend "s3" {
    bucket         = "platform-terraform-state-REPLACE_WITH_ACCOUNT_ID"
    key            = "eks/terraform.tfstate"  # path inside the bucket
    region         = "us-east-1"
    dynamodb_table = "platform-terraform-state-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  # Tag every resource created by Terraform with these default tags.
  # Makes it easy to find all project resources in the AWS console,
  # and to set up billing alerts per project.
  default_tags {
    tags = {
      Project     = "platform"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
