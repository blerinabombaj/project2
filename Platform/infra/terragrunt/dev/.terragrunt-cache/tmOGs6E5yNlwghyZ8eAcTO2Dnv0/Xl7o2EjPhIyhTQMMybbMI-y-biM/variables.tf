# variables.tf
#
# Variables are how you make Terraform reusable.
# Instead of hardcoding "us-east-1" everywhere, you define it once here
# and reference it as var.aws_region throughout the config.
#
# Each variable has:
#   description — what it's for (shows up in `terraform plan` output)
#   type        — string, number, bool, list, map (Terraform validates this)
#   default     — optional. If set, you don't have to supply it on apply.
#                 If not set, Terraform will prompt you for it.

variable "aws_region" {
  description = "AWS region to deploy everything into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name (dev / staging / prod). Used in resource names and tags."
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Short name for this project. Used as a prefix on all resource names."
  type        = string
  default     = "platform"
}

# ── EKS variables ─────────────────────────────────────────────────────────────

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "node_instance_type" {
  description = <<-EOT
    EC2 instance type for EKS worker nodes.

    COST WARNING:
      t3.medium = $0.0416/hr per node (~$60/month for 2 nodes)
      EKS control plane = $0.10/hr (~$72/month) regardless of node count
      Total: ~$132/month if left running

    Always run `terraform destroy` when done for the day.
    Set up a billing alert in AWS to catch runaway costs.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "node_desired_count" {
  description = "Desired number of worker nodes. 2 is minimum for real workloads (one per AZ)."
  type        = number
  default     = 2
}

variable "node_min_count" {
  description = "Minimum nodes (auto-scaling lower bound)"
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum nodes (auto-scaling upper bound). Keep low to control cost."
  type        = number
  default     = 3
}

# ── ECR variables ──────────────────────────────────────────────────────────────

variable "ecr_repositories" {
  description = "List of ECR repository names to create — one per microservice."
  type        = list(string)
  default     = ["api-gateway", "user-service", "order-service"]
}

variable "ecr_image_retention_count" {
  description = <<-EOT
    How many images to keep per repository.
    Old images are deleted automatically to avoid storage costs.
    ECR free tier: 500MB/month. Each image ~100-200MB, so 5 is safe.
  EOT
  type        = number
  default     = 5
}
