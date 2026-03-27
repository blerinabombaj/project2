# bootstrap/main.tf
#
# PURPOSE: Create the S3 bucket and DynamoDB table that Terraform uses
#          to store its state remotely.
#
# WHY THIS EXISTS AS A SEPARATE FOLDER:
#   Terraform stores state somewhere. By default that's a local file (terraform.tfstate).
#   The problem: if you lose that file, Terraform loses track of everything it created
#   and can never manage those resources again.
#
#   The solution is remote state — store the state file in S3 instead.
#   But here's the chicken-and-egg problem: to create the S3 bucket using Terraform,
#   Terraform needs somewhere to store state... which is the bucket we haven't created yet.
#
#   So we solve this with a bootstrap step:
#     1. Run THIS folder first (state stored locally — that's fine, it's just a bucket)
#     2. Then the main Terraform config uses that bucket as its backend
#
#   You only ever run this once. After that, leave it alone.
#
# COST: S3 + DynamoDB are free tier eligible. This step costs nothing.
#
# HOW TO RUN:
#   cd infra/terraform/bootstrap
#   terraform init
#   terraform apply

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # change this if you prefer a different region
}

# ── S3 bucket for Terraform state ─────────────────────────────────────────────

resource "aws_s3_bucket" "terraform_state" {
  # Bucket names must be globally unique across all AWS accounts.
  # Using your account ID in the name makes collisions essentially impossible.
  bucket = "platform-terraform-state-${data.aws_caller_identity.current.account_id}"

  # Prevent accidental deletion of this bucket.
  # If you ever want to destroy it, you have to set this to false first
  # and apply, then destroy. This is intentional friction.
  lifecycle {
    prevent_destroy = true
  }
}

# Turn on versioning so every change to the state file is preserved.
# If something goes wrong (corrupted state, bad apply), you can roll back
# to a previous version of the state file.
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest. State files contain sensitive values (passwords,
# keys) in plaintext, so encryption is mandatory.
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access. State files must never be public.
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── DynamoDB table for state locking ──────────────────────────────────────────
#
# WHY STATE LOCKING EXISTS:
#   Imagine two people run `terraform apply` at the same time.
#   Both read the current state, both plan changes, both try to write back.
#   The second write overwrites the first — your infrastructure is now inconsistent.
#
#   DynamoDB locking prevents this: before Terraform reads or writes state,
#   it writes a lock entry to DynamoDB. If a lock already exists, the second
#   apply fails immediately with "state is locked by another process".
#   When the apply finishes, the lock is deleted.
#
# COST: PAY_PER_REQUEST means you only pay for actual reads/writes.
#       For a solo project this is essentially free (a few cents per month at most).

resource "aws_dynamodb_table" "terraform_state_lock" {
  name         = "platform-terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID" # Terraform expects exactly this key name

  attribute {
    name = "LockID"
    type = "S" # S = String
  }
}

# ── Data sources ──────────────────────────────────────────────────────────────

# Fetch the current AWS account ID — used to make the bucket name unique.
data "aws_caller_identity" "current" {}

# ── Outputs ───────────────────────────────────────────────────────────────────
# Print these after apply — you'll copy them into versions.tf in the main config.

output "state_bucket_name" {
  value       = aws_s3_bucket.terraform_state.bucket
  description = "Copy this into the backend block in versions.tf"
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.terraform_state_lock.name
  description = "Copy this into the backend block in versions.tf"
}
