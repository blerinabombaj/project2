# Step 3 — Terragrunt: multi-environment setup

## Why Terragrunt on top of Terraform?

Without Terragrunt, multi-environment Terraform looks like this:
```
terraform/
├── dev/
│   ├── main.tf        # copy of the same file
│   ├── variables.tf   # copy of the same file
│   ├── versions.tf    # copy of the same file, bucket name hardcoded
│   └── terraform.tfvars
├── staging/
│   ├── main.tf        # same again
│   ├── variables.tf   # same again
│   ├── versions.tf    # same again, different hardcoded key
│   └── terraform.tfvars
└── prod/
    ├── main.tf        # same again
    ...
```

With Terragrunt:
```
terragrunt/
├── terragrunt.hcl     # written once — S3 backend, provider, shared inputs
├── dev/
│   └── terragrunt.hcl # 15 lines — just the overrides
├── staging/
│   └── terragrunt.hcl # 15 lines — just the overrides
└── prod/
    └── terragrunt.hcl # 15 lines — just the overrides
```

Each environment gets its own isolated state file automatically:
- `s3://platform-terraform-state-ACCOUNT_ID/dev/terraform.tfstate`
- `s3://platform-terraform-state-ACCOUNT_ID/staging/terraform.tfstate`
- `s3://platform-terraform-state-ACCOUNT_ID/prod/terraform.tfstate`

---

## Install Terragrunt

```bash
brew install terragrunt    # mac

# or download from https://github.com/gruntwork-io/terragrunt/releases
# and put the binary in your PATH
```

---

## Apply a single environment

```bash
# Dev only (start here — cheapest)
cd infra/terragrunt/dev
terragrunt init
terragrunt plan
terragrunt apply

# Configure kubectl for dev cluster
aws eks update-kubeconfig --region us-east-1 --name platform-dev
kubectl get nodes
```

---

## Apply all environments at once

Terragrunt has a `run-all` command that runs the same command across
every environment in parallel. Use this with caution — in a real project
you'd only do this for plan, never for apply without reviewing each plan.

```bash
cd infra/terragrunt
terragrunt run-all plan     # plans all 3 environments in parallel
terragrunt run-all apply    # applies all 3 (be sure you want this)
terragrunt run-all destroy  # destroys all 3 (useful for cleanup)
```

---

## Destroy when done

```bash
# Destroy one environment
cd infra/terragrunt/dev
terragrunt destroy

# Destroy all environments (end of day cleanup)
cd infra/terragrunt
terragrunt run-all destroy
```

---

## Interview question this answers

"How do you manage Terraform across multiple environments without duplicating code?"

Answer structure:
1. Terraform modules make the infrastructure reusable (step 2)
2. Terragrunt calls those modules from per-environment configs
3. The root terragrunt.hcl defines the S3 backend once — the key path is
   derived automatically from the folder name, so each env gets isolated state
4. Each environment's terragrunt.hcl is ~15 lines — just the overrides
5. `run-all` lets you plan/apply/destroy all environments with one command

Contrast with Terraform workspaces (the alternative interviewers often ask about):
- Workspaces share the same state bucket key structure and can be confusing
- Terragrunt's folder-per-environment is more explicit, easier to audit,
  and easier to give different teams access to different environments via IAM
