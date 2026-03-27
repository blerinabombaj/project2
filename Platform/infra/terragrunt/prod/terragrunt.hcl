# terragrunt/prod/terragrunt.hcl
#
# Prod — treat this environment with care.
# Higher node count, larger instances, stricter everything.
#
# GOLDEN RULE: never run `terragrunt apply` directly in prod.
# In a real team, prod applies go through CI only (GitHub Actions),
# triggered by a merge to main, after staging has been verified.
# We'll enforce this in step 4 (GitHub Actions pipeline).
#
# For now, you can apply manually — but get in the habit of always
# running `terragrunt plan` and reading the output carefully first.
#
# HOW TO APPLY (for learning purposes):
#   cd infra/terragrunt/prod
#   terragrunt plan    ← always read this first
#   terragrunt apply

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../terraform"
}

inputs = {
  # Larger instance for real workloads.
  # t3.large = 2 vCPU, 8GB RAM — comfortable for 3 services + observability.
  node_instance_type = "t3.large"
  node_desired_count = 2
  node_min_count     = 2
  node_max_count     = 4

  # Keep more images in prod — you want more rollback options.
  ecr_image_retention_count = 10
}
