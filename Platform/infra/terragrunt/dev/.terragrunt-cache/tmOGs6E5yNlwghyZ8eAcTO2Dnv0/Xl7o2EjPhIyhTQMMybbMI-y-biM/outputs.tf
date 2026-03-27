# outputs.tf
#
# These print after `terraform apply` succeeds.
# They're also how other Terraform configs (e.g. Terragrunt environments)
# can reference values from this config via `terraform_remote_state`.

output "cluster_name" {
  description = "EKS cluster name — use in: aws eks update-kubeconfig --name <this>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = module.eks.cluster_endpoint
}

output "ecr_repository_urls" {
  description = "ECR URLs per service — use these in your docker push commands and Helm values"
  value       = module.ecr.repository_urls
}

output "configure_kubectl" {
  description = "Run this command after apply to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "ecr_login_command" {
  description = "Run this to authenticate Docker with ECR before pushing images"
  value       = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${module.ecr.registry_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}
