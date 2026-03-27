# terragrunt/dev/terragrunt.hcl
#
# Dev environment — cheap, disposable, no redundancy needed.
# This is where you test changes before promoting to staging.
#
# WHAT THIS FILE ACTUALLY IS:
#   Just overrides. Everything not mentioned here comes from the root
#   terragrunt.hcl via the include block. This file is intentionally tiny.
#   That's the point of Terragrunt — each environment only declares
#   what makes it different.
#
# HOW TO APPLY:
#   cd infra/terragrunt/dev
#   terragrunt init
#   terragrunt plan
#   terragrunt apply
#
# HOW TO DESTROY WHEN DONE FOR THE DAY:
#   terragrunt destroy

# Pull in everything from the root terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
  # find_in_parent_folders() walks up the directory tree until it finds
  # a terragrunt.hcl — in this case, the root one two levels up.
  # This is how Terragrunt knows to look at infra/terragrunt/terragrunt.hcl.
}

# Point to the Terraform module to run.
# This is a relative path from THIS file to the terraform root.
# Terragrunt copies the module into a temp directory and runs it there.
terraform {
  source = "../../terraform"
}

# ── Environment-specific overrides ────────────────────────────────────────────
#
# These are merged with the root inputs block.
# Only the things that differ from the root defaults need to be here.

inputs = {
  # Smallest viable setup — 1 node is enough for dev.
  # You're not testing availability here, just functionality.
  node_instance_type = "t3.medium"
  node_desired_count = 1
  node_min_count     = 1
  node_max_count     = 2
}
