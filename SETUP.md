# SETUP.md — Complete setup guide

Everything you need to change and every command to run, in exact order.
Nothing is assumed. Follow this top to bottom.

---

## Before you start — install the tools

```bash
# Mac (using Homebrew — install from https://brew.sh if you don't have it)
brew install awscli
brew install terraform
brew install terragrunt
brew install helm
brew install kubectl

# Verify everything installed
aws --version
terraform --version
terragrunt --version
helm version
kubectl version --client

# Install istioctl separately
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.21.0 sh -
cd istio-1.21.0
export PATH=$PWD/bin:$PATH
istioctl version
```

---

## Phase 1 — AWS credentials

### Step 1.1 — Create an IAM user for your work

Go to: AWS Console → IAM → Users → Create user
- Username: `platform-admin`
- Attach policies directly: `AdministratorAccess` (for learning — scope this down for real jobs)
- After creating: Security credentials tab → Create access key → Command Line Interface

Copy the Access Key ID and Secret Access Key — you only see the secret once.

### Step 1.2 — Configure the AWS CLI

```bash
aws configure
# AWS Access Key ID:     paste your access key
# AWS Secret Access Key: paste your secret key
# Default region:        us-east-1
# Default output format: json

# Verify it works
aws sts get-caller-identity
# Should print your account ID, user ID, and ARN
```

### Step 1.3 — Note your account ID

```bash
aws sts get-caller-identity --query Account --output text
# Example output: 123456789012
# Save this — you will replace REPLACE_WITH_ACCOUNT_ID with this number
# in many files throughout this guide.
```

---

## Phase 2 — GitHub repository

### Step 2.1 — Create the repo

Go to GitHub → New repository
- Name: `platform`
- Private
- Do NOT initialise with README (you already have files)

### Step 2.2 — Push your code

```bash
cd platform   # your project root
git init
git add .
git commit -m "initial commit"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/platform.git
git push -u origin main
```

### Step 2.3 — Create a CI IAM user (separate from your personal user)

Go to: AWS Console → IAM → Users → Create user
- Username: `platform-ci`
- Attach policies:
  - `AmazonEC2ContainerRegistryPowerUser`

After creating: Security credentials → Create access key → Application running outside AWS

### Step 2.4 — Add GitHub secrets

Go to: GitHub repo → Settings → Secrets and variables → Actions → New repository secret

Add these three secrets exactly as named:

| Secret name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access key for platform-ci user |
| `AWS_SECRET_ACCESS_KEY` | Secret key for platform-ci user |
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID from step 1.3 |

### Step 2.5 — Set up branch protection

Go to: GitHub repo → Settings → Branches → Add branch protection rule
- Branch name pattern: `main`
- Check: Require a pull request before merging
- Check: Require status checks to pass before merging
  - Search and add: `Lint` and `Security scan (Trivy)`
- Check: Do not allow bypassing the above settings
- Save

---

## Phase 3 — Terraform: remote state bootstrap

### Step 3.1 — Run the bootstrap (once only, never again)

```bash
cd infra/terraform/bootstrap
terraform init
terraform apply
# Type: yes
```

After it completes you will see output like:
```
state_bucket_name  = "platform-terraform-state-123456789012"
dynamodb_table_name = "platform-terraform-state-lock"
```

### Step 3.2 — Update versions.tf with your bucket name

Open `infra/terraform/versions.tf`

Find this block:
```hcl
backend "s3" {
  bucket         = "platform-terraform-state-REPLACE_WITH_ACCOUNT_ID"
```

Change it to your actual bucket name from the output above:
```hcl
backend "s3" {
  bucket         = "platform-terraform-state-123456789012"
```

---

## Phase 4 — Terraform: create EKS cluster and ECR repos

### Step 4.1 — Set a billing alert first

Go to: AWS Console → Billing → Budgets → Create budget
- Budget type: Cost budget
- Amount: $50
- Alert threshold: 80% ($40)
- Email: your email

**The EKS cluster costs ~$0.27/hr when running. Always destroy when not using it.**

### Step 4.2 — Apply Terraform

```bash
cd infra/terraform
terraform init    # downloads providers, takes ~2 minutes
terraform plan    # read this carefully before applying
terraform apply   # takes ~15 minutes for EKS
# Type: yes
```

After it completes, note the outputs — you will need the ECR URLs.

### Step 4.3 — Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name platform-dev

# Verify connection
kubectl get nodes
# Should show 2 nodes in Ready state after a minute or two
```

---

## Phase 5 — Update all placeholder values

This is the most important phase — every file that has a placeholder needs updating.

### Step 5.1 — Replace your account ID everywhere at once

```bash
cd platform   # your project root

# Replace in all helm values files
find helm/ -name "*.yaml" -exec sed -i \
  's/REPLACE_WITH_ACCOUNT_ID/YOUR_ACCOUNT_ID/g' {} \;

# Replace in ArgoCD application files
find gitops/argocd/ -name "*.yaml" -exec sed -i \
  's/YOUR_USERNAME/your-actual-github-username/g' {} \;

# Replace in Kyverno trusted registry policy
sed -i 's/ACCOUNT_ID/YOUR_ACCOUNT_ID/g' \
  policy/kyverno/require-trusted-registry.yaml
sed -i 's/REGION/us-east-1/g' \
  policy/kyverno/require-trusted-registry.yaml
```

Replace `YOUR_ACCOUNT_ID` with your 12-digit account ID and `your-actual-github-username` with your GitHub username.

### Step 5.2 — Verify replacements worked

```bash
# Should print NO results — means all placeholders are gone
grep -r "REPLACE_WITH_ACCOUNT_ID" helm/
grep -r "YOUR_USERNAME" gitops/argocd/
grep -r "ACCOUNT_ID" policy/kyverno/require-trusted-registry.yaml
```

### Step 5.3 — Commit the changes

```bash
git add .
git commit -m "chore: replace placeholder values with real account/username"
git push origin main
```

---

## Phase 6 — Terragrunt: verify multi-env config

You don't need to apply staging and prod right now — they cost money and you're still learning.
Just verify the config is correct:

```bash
cd infra/terragrunt/dev
terragrunt init
terragrunt plan
# Should show the same plan as terraform — but reading config from terragrunt.hcl
# Do NOT apply — you already have the cluster from Phase 4
```

When you're ready to test multi-env (later):
```bash
# To spin up staging separately
cd infra/terragrunt/staging
terragrunt init && terragrunt apply

# To destroy it when done
terragrunt destroy
```

---

## Phase 7 — Push your first image to ECR

```bash
# Get your ECR registry URL (from terraform output or build it from account ID)
ECR_REGISTRY="YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com"

# Log Docker into ECR
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin $ECR_REGISTRY

# Build and push api-gateway
docker build -t $ECR_REGISTRY/platform/api-gateway:test apps/api-gateway/
docker push $ECR_REGISTRY/platform/api-gateway:test

# Do the same for the other two services
docker build -t $ECR_REGISTRY/platform/user-service:test apps/user-service/
docker push $ECR_REGISTRY/platform/user-service:test

docker build -t $ECR_REGISTRY/platform/order-service:test apps/order-service/
docker push $ECR_REGISTRY/platform/order-service:test

# Verify they appear in ECR
aws ecr list-images --repository-name platform/api-gateway
```

---

## Phase 8 — Install Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --version 3.2.0

# Wait for it to be ready (~1 minute)
kubectl wait pod \
  --for=condition=Ready \
  --namespace kyverno \
  --selector=app.kubernetes.io/component=admission-controller \
  --timeout=120s

# Apply your policies
kubectl apply -f policy/kyverno/

# Verify
kubectl get clusterpolicy
# Should show 3 policies all with READY=True
```

---

## Phase 9 — Install Istio

```bash
# Verify cluster is ready
istioctl x precheck

# Install Istio
istioctl install --set profile=default -y

# Wait for control plane
kubectl wait deployment istiod \
  --namespace istio-system \
  --for=condition=Available \
  --timeout=120s

# Apply namespace labels (enables sidecar injection)
kubectl apply -f gitops/istio/namespace-labels.yaml

# Apply mTLS enforcement
kubectl apply -f gitops/istio/peer-authentication.yaml

# Apply traffic rules
kubectl apply -f gitops/istio/destination-rules.yaml
kubectl apply -f gitops/istio/virtual-services.yaml
kubectl apply -f gitops/istio/gateway.yaml

# Verify
kubectl get pods -n istio-system
# Should show istiod and istio-ingressgateway Running
```

---

## Phase 10 — Install ArgoCD and deploy your services

### Step 10.1 — Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait deployment argocd-server \
  --namespace argocd \
  --for=condition=Available \
  --timeout=120s
```

### Step 10.2 — Get the admin password

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
# Copy this password
```

### Step 10.3 — Open the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open https://localhost:8080 (accept the self-signed cert warning)
- Username: `admin`
- Password: from step above

### Step 10.4 — Connect your private repo (if private)

In ArgoCD UI: Settings → Repositories → Connect Repo
- Type: HTTPS
- Repo URL: https://github.com/YOUR_USERNAME/platform
- Username: your GitHub username
- Password: a GitHub Personal Access Token
  (GitHub → Settings → Developer settings → Personal access tokens → Generate new token → repo scope)

### Step 10.5 — Deploy everything with one command

```bash
# This one command bootstraps everything.
# ArgoCD reads gitops/argocd/ and creates all three service applications.
kubectl apply -f gitops/argocd/app-of-apps.yaml

# Watch the applications appear
kubectl get applications -n argocd
# After ~2 minutes all should show Synced and Healthy
```

### Step 10.6 — Verify pods are running

```bash
kubectl get pods -n dev
# NAME                             READY   STATUS
# api-gateway-xxx                  2/2     Running   ← 2/2 = app + Istio sidecar
# user-service-xxx                 2/2     Running
# order-service-xxx                2/2     Running
```

If pods show `1/2` or `CrashLoopBackOff`:
```bash
# Check what's wrong
kubectl describe pod POD_NAME -n dev
kubectl logs POD_NAME -n dev -c api-gateway
```

---

## Phase 11 — Test the full pipeline end to end

```bash
# Make a small change — add a comment to any service
echo "# test" >> apps/api-gateway/main.py

git add .
git commit -m "test: trigger full CI pipeline"
git push origin main
```

Now watch:
1. GitHub Actions: https://github.com/YOUR_USERNAME/platform/actions
   - Lint job runs (~10 seconds)
   - Trivy scan runs (~2 minutes)
   - Build and push runs (~3 minutes)
   - Deploy job commits new image tag to `helm/api-gateway/values-dev.yaml`

2. ArgoCD detects the commit and syncs (within 3 minutes or force sync in UI)

3. Verify the new image:
```bash
kubectl describe pod -n dev -l app=api-gateway | grep Image:
# Image: YOUR_ECR/platform/api-gateway:3a4b5c6   ← git SHA from your commit
```

---

## Phase 12 — Test your services are actually working

```bash
# Port-forward to the api-gateway (bypassing Istio gateway for now)
kubectl port-forward svc/api-gateway 8000:8000 -n dev &

# Create a user
curl -X POST http://localhost:8000/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "email": "alice@example.com"}'
# Expected: {"id": 1, "name": "Alice", ...}

# Create an order (triggers cross-service call to user-service)
curl -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d '{"user_id": 1, "item": "Laptop", "quantity": 1}'
# Expected: {"id": 1, "user_id": 1, "item": "Laptop", ...}

# Try a bad user ID — should be rejected by order-service
curl -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d '{"user_id": 999, "item": "Ghost", "quantity": 1}'
# Expected: 422 User 999 does not exist
```

---

## Daily workflow — cost management

**Start of day:**
```bash
# If you destroyed the cluster, recreate it
cd infra/terraform && terraform apply
aws eks update-kubeconfig --region us-east-1 --name platform-dev
```

**End of day:**
```bash
# ALWAYS do this — saves ~$6/day
cd infra/terraform && terraform destroy
# Type: yes
```

**Do NOT destroy:**
- The bootstrap S3 bucket and DynamoDB (infra/terraform/bootstrap)
- Your ECR repos (images are cheap, rebuilding the repos is annoying)

---

## Troubleshooting quick reference

| Problem | Command to diagnose |
|---|---|
| Pod not starting | `kubectl describe pod POD_NAME -n dev` |
| Pod crashing | `kubectl logs POD_NAME -n dev` |
| ArgoCD not syncing | `kubectl get application -n argocd` then check UI |
| Kyverno blocking a pod | `kubectl get policyreport -A` |
| Istio sidecar not injected (1/1 instead of 2/2) | `kubectl rollout restart deployment/SERVICE -n dev` |
| ECR pull failure | Re-run `aws ecr get-login-password ... \| docker login ...` |
| Terraform state locked | `terraform force-unlock LOCK_ID` |
