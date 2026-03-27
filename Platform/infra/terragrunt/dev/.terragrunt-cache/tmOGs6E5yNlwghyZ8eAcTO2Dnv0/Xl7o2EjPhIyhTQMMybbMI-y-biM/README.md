# Step 2 — Terraform: EKS + ECR

## Prerequisites

```bash
# Install AWS CLI
brew install awscli        # mac
# or download from https://aws.amazon.com/cli/

# Install Terraform
brew install terraform     # mac
# or https://developer.hashicorp.com/terraform/install

# Configure AWS credentials
aws configure
# Enter: Access Key ID, Secret Access Key, region (us-east-1), output format (json)
# Get keys from: AWS Console → IAM → Your user → Security credentials → Access keys
```

## Cost warning

| Resource | Cost |
|---|---|
| EKS control plane | $0.10/hr (~$72/month) |
| 2x t3.medium nodes | ~$0.083/hr each (~$120/month total) |
| NAT Gateway | ~$0.045/hr + data |
| S3 + DynamoDB | Free tier |

**Always run `terraform destroy` when done for the day.**
Set up a billing alert: AWS Console → Billing → Budgets → Create budget → $50/month threshold.

---

## Step 1 — Bootstrap (run once, never again)

This creates the S3 bucket and DynamoDB table for remote state.

```bash
cd infra/terraform/bootstrap
terraform init
terraform apply
```

After apply, you'll see output like:
```
state_bucket_name = "platform-terraform-state-123456789012"
dynamodb_table_name = "platform-terraform-state-lock"
```

Copy the bucket name into `versions.tf`:
```hcl
backend "s3" {
  bucket = "platform-terraform-state-123456789012"  # <-- paste here
  ...
}
```

---

## Step 2 — Apply the main config

```bash
cd infra/terraform
terraform init        # downloads providers and modules (~2 minutes)
terraform plan        # shows what will be created — read this carefully
terraform apply       # creates everything (~15 minutes for EKS)
```

After apply you'll see:
```
cluster_name = "platform-dev"
configure_kubectl = "aws eks update-kubeconfig --region us-east-1 --name platform-dev"
ecr_repository_urls = {
  "api-gateway"   = "123456789.dkr.ecr.us-east-1.amazonaws.com/platform/api-gateway"
  "user-service"  = "123456789.dkr.ecr.us-east-1.amazonaws.com/platform/user-service"
  "order-service" = "123456789.dkr.ecr.us-east-1.amazonaws.com/platform/order-service"
}
```

---

## Step 3 — Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name platform-dev
kubectl get nodes     # should show 2 nodes in Ready state
kubectl get pods -A   # shows system pods running
```

---

## Step 4 — Push your first image to ECR

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin \
    123456789.dkr.ecr.us-east-1.amazonaws.com

# Build and push api-gateway
cd apps/api-gateway
docker build -t platform/api-gateway .
docker tag platform/api-gateway \
  123456789.dkr.ecr.us-east-1.amazonaws.com/platform/api-gateway:latest
docker push \
  123456789.dkr.ecr.us-east-1.amazonaws.com/platform/api-gateway:latest
```

---

## Destroy when done

```bash
cd infra/terraform
terraform destroy     # tears down EKS, nodes, VPC, ECR — stops all charges

# Do NOT destroy the bootstrap resources — you'll lose the state bucket
# cd infra/terraform/bootstrap
# terraform destroy  <-- don't do this
```

---

## What to notice

- `terraform plan` always before `terraform apply`. Plan shows you exactly what will change.
  Red = destroy, green = create, yellow = modify. Never apply without reading the plan.

- The `.terraform.lock.hcl` file that `init` creates pins exact provider versions.
  Commit this file — it's like package-lock.json. Ensures everyone gets the same providers.

- `terraform state list` shows every resource Terraform is tracking.
  If a resource drifts (someone manually changed it in the console), `terraform plan`
  will show the diff and `terraform apply` will fix it back. This is idempotency.
