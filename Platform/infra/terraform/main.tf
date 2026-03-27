# main.tf
#
# The root module — this is the entrypoint for `terraform apply`.
# It calls the EKS and ECR modules, passing variables into them.
#
# MENTAL MODEL:
#   modules/eks/  = a function definition
#   modules/ecr/  = a function definition
#   main.tf       = calling those functions with specific arguments
#
# WHY MODULES MATTER FOR THIS PROJECT:
#   In step 3 (Terragrunt), you'll have dev/staging/prod folders that each
#   call these same modules with different variable values.
#   - dev:     node_desired_count=1, node_instance_type=t3.medium
#   - staging: node_desired_count=2, node_instance_type=t3.medium
#   - prod:    node_desired_count=3, node_instance_type=t3.large
#   Same module, different config. No copy-pasting.

module "eks" {
  source = "./modules/eks"

  project_name       = var.project_name
  environment        = var.environment
  cluster_version    = var.cluster_version
  node_instance_type = var.node_instance_type
  node_desired_count = var.node_desired_count
  node_min_count     = var.node_min_count
  node_max_count     = var.node_max_count
}

module "ecr" {
  source = "./modules/ecr"

  project_name          = var.project_name
  repository_names      = var.ecr_repositories
  image_retention_count = var.ecr_image_retention_count
}
