# terraform.tfvars
#
# This file sets actual values for the variables defined in variables.tf.
# Terraform automatically loads it when you run plan/apply.
#
# WHAT TO COMMIT TO GIT:
#   This file is safe to commit — no secrets here, just config.
#   If you had secrets (DB passwords etc.), you'd use a terraform.tfvars.secret
#   file and add it to .gitignore. For now everything here is fine.
#
# COST-CONSCIOUS SETTINGS:
#   These settings minimise cost while still being functional.
#   Bump node counts when you're actively testing, destroy when done.

aws_region   = "us-east-1"
environment  = "dev"
project_name = "platform"

# EKS
cluster_version    = "1.31"
node_instance_type = "c7i-flex.large"  # minimum that works well with EKS
node_desired_count = 2            # 1 per AZ — minimum for real workloads
node_min_count     = 1
node_max_count     = 3

# ECR
ecr_repositories        = ["api-gateway", "user-service", "order-service"]
ecr_image_retention_count = 5
