# terragrunt/terragrunt.hcl  (ROOT)
#
# This file is the heart of Terragrunt. Every environment's terragrunt.hcl
# starts with `include "root"` which pulls everything defined here.
#
# TWO THINGS THIS FILE DOES:
#
# 1. REMOTE STATE — defines the S3 backend once, for all environments.
#    Each environment automatically gets its own state file at a different
#    S3 key (path), derived from the folder it lives in.
#    No more copy-pasting the backend block into every environment.
#
# 2. GENERATE PROVIDER — injects the AWS provider block into every
#    environment without you writing it manually each time.
#
# THE KEY INSIGHT:
#   In plain Terraform, the backend block is static — you can't use variables.
#   So if you had 3 environments as separate Terraform roots, you'd have to
#   hardcode the bucket name + key in 3 places. If you rename the bucket,
#   you update 3 files. Terragrunt solves this by computing the backend
#   config dynamically before Terraform even starts.

# ── Remote state (S3 backend) ──────────────────────────────────────────────────

remote_state {
  backend = "s3"

  # generate = "required" means: if the backend config doesn't exist,
  # create it automatically. Terragrunt writes a backend.tf file in
  # each environment's working directory before running Terraform.
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket         = "platform-terraform-state-${get_aws_account_id()}"
    region         = "us-east-1"
    dynamodb_table = "platform-terraform-state-lock"
    encrypt        = true

    # THIS IS THE MAGIC:
    # path_relative_to_include() returns the path of the environment folder
    # relative to this root file.
    #
    # So for dev/:     key = "dev/terraform.tfstate"
    # For staging/:    key = "staging/terraform.tfstate"
    # For prod/:       key = "prod/terraform.tfstate"
    #
    # Each environment gets its own isolated state file in the same bucket.
    # They can never interfere with each other.
    key = "${path_relative_to_include()}/terraform.tfstate"
  }
}

# ── Generate AWS provider ──────────────────────────────────────────────────────
#
# Instead of writing a versions.tf in every environment, we generate it once
# here. Terragrunt writes this file before running Terraform.
# Each environment's terragrunt.hcl passes the region as an input,
# and we read it here via local.common_vars.

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.6"
      required_providers {
        aws = {
          source  = "hashicorp/aws"
          version = "~> 5.0"
        }
      }
    }

    provider "aws" {
      region = "${local.aws_region}"

      default_tags {
        tags = {
          Project     = "platform"
          ManagedBy   = "terragrunt"
          Environment = "${local.environment}"
        }
      }
    }
  EOF
}

# ── Local values ───────────────────────────────────────────────────────────────
#
# locals block reads values that are shared across the root config.
# We read them from the environment-specific terragrunt.hcl via inputs,
# but we also need them here for the provider generation above.
#
# The pattern: each env's terragrunt.hcl sets locals, then we read them here
# using read_terragrunt_config() to get the environment name for tagging.

locals {
  # Extract environment name from the directory name automatically.
  # get_path_from_repo_root() returns e.g. "infra/terragrunt/dev"
  # basename() extracts the last segment: "dev"
  # This means you never have to manually set environment = "dev" in each folder —
  # Terragrunt infers it from the folder name.
  environment = basename(get_terragrunt_dir())

  # Read the aws_region from inputs if set, otherwise default to us-east-1
  aws_region = "us-east-1"
}

# ── Inputs shared across all environments ─────────────────────────────────────
#
# Values here are merged with each environment's inputs.
# Environment-specific inputs override these if there's a conflict.

inputs = {
  project_name = "platform"
  aws_region   = local.aws_region
  environment  = local.environment

  # ECR repos are the same across all environments — same 3 services.
  # In a real project you might have more services in prod, but for learning,
  # keeping them the same is cleaner.
  ecr_repositories          = ["api-gateway", "user-service", "order-service"]
  ecr_image_retention_count = 5

  # Kubernetes version pinned here — change it once to upgrade all envs.
  cluster_version = "1.29"
}
