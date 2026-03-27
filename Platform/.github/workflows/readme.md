# Step 4 — GitHub Actions CI pipeline

## What the pipeline does on every push to main

```
push to main
    │
    ▼
[lint] — ruff checks all 3 services (~5 seconds)
    │ fail = stop here
    ▼
[scan] — Trivy scans each service image for CVEs, in parallel (~2 minutes)
    │ CRITICAL or HIGH found = stop here
    ▼
[build-push] — builds images, tags with git SHA, pushes to ECR (~3 minutes)
    │
    ▼
[deploy] — updates image tag in helm/SERVICE/values-dev.yaml, commits + pushes
    │
    └── ArgoCD detects the git change and syncs the cluster automatically
```

On PRs and feature branches: only lint + scan run. No push, no deploy.

---

## One-time setup: GitHub Secrets

The pipeline needs 3 secrets. Add them at:
GitHub repo → Settings → Secrets and variables → Actions → New repository secret

| Secret name | Where to get it |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS Console → IAM → Users → your user → Security credentials → Create access key |
| `AWS_SECRET_ACCESS_KEY` | Same place — shown once on creation, copy it immediately |
| `AWS_ACCOUNT_ID` | AWS Console → top-right corner, or run: `aws sts get-caller-identity --query Account --output text` |

**IAM permissions the CI user needs:**
The IAM user (whose keys you use above) needs these policies:
- `AmazonEC2ContainerRegistryPowerUser` — push/pull images to ECR
- A custom policy for the deploy step (updating values files only needs git, no AWS)

Create the IAM user just for CI — don't use your personal admin user.
If the CI keys are ever leaked, you want to be able to revoke just the CI user.

---

## One-time setup: Branch protection rules

This is what forces every change to go through the pipeline before merging.
Without this, anyone can push broken code directly to main.

GitHub repo → Settings → Branches → Add branch protection rule

Branch name pattern: `main`

Check these boxes:
- [x] Require a pull request before merging
- [x] Require status checks to pass before merging
  - Search for and add: `Lint`, `Security scan (Trivy)`
- [x] Require branches to be up to date before merging
- [x] Do not allow bypassing the above settings

After this, no one — not even repo admins — can push to main without
the lint and scan jobs passing first.

---

## Update the ECR repository URLs

Before the pipeline runs for the first time, update the `image.repository`
in each values file with your actual AWS account ID:

```bash
# Get your account ID
aws sts get-caller-identity --query Account --output text

# Replace the placeholder in all values files
find helm/ -name "values-dev.yaml" -exec sed -i \
  's/REPLACE_WITH_ACCOUNT_ID/YOUR_ACCOUNT_ID/g' {} \;
```

---

## Test the pipeline locally before pushing

```bash
# Install ruff
pip install ruff

# Run lint the same way the pipeline does
ruff check apps/api-gateway/ --select E,F,W
ruff check apps/user-service/ --select E,F,W
ruff check apps/order-service/ --select E,F,W

# Install Trivy locally
brew install aquasecurity/trivy/trivy   # mac

# Build and scan locally
docker build -t api-gateway:test apps/api-gateway/
trivy image --severity CRITICAL,HIGH --ignore-unfixed api-gateway:test
```

---

## Understanding the image tag strategy

Every image pushed to ECR is tagged with the git commit SHA:
```
123456789.dkr.ecr.us-east-1.amazonaws.com/platform/api-gateway:3a4b5c6
```

This means:
- You can always trace a running pod back to the exact commit that built it
- `kubectl describe pod api-gateway-xxx` → image tag → `git show 3a4b5c6`
- Rolling back = changing the tag in values-dev.yaml to a previous SHA + committing

Never use `latest` in production. `latest` is a lie — it changes silently
and you can never tell what code is actually running.

---

## What ArgoCD does with the values file change

When the deploy job commits a new image tag to `helm/user-service/values-dev.yaml`:
1. ArgoCD (running in the cluster) polls the git repo every 3 minutes
2. It detects that `values-dev.yaml` changed
3. It runs `helm template` with the new values
4. It compares the rendered manifests to what's running in the cluster
5. If different, it applies the changes — rolling update begins
6. Old pods are terminated only after new pods pass readiness probes

No manual kubectl. No manual helm upgrade. The commit IS the deploy.
