# terragrunt/staging/terragrunt.hcl
#
# Staging — mirrors prod as closely as possible.
# This is where you catch problems that only appear under prod-like conditions
# (2 nodes across 2 AZs, same instance type as prod, same Kyverno policies).
#
# The rule of thumb: if staging doesn't catch it, prod will.
# Make staging hurt to find bugs cheaply.
#
# HOW TO APPLY:
#   cd infra/terragrunt/staging
#   terragrunt init
#   terragrunt plan
#   terragrunt apply

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../terraform"
}

inputs = {
  # 2 nodes across 2 AZs — same topology as prod.
  # This is where you'd catch "works on my single node dev cluster" bugs.
  node_instance_type = "t3.medium"
  node_desired_count = 2
  node_min_count     = 2
  node_max_count     = 3
}
