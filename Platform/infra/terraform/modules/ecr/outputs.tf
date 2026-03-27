# Outputs expose values from inside the module to whoever calls it.
# The root main.tf uses these to print repository URLs after apply.

output "repository_urls" {
  description = "Map of service name to ECR repository URL"
  # e.g. { "api-gateway" = "123456789.dkr.ecr.us-east-1.amazonaws.com/platform/api-gateway" }
  value = {
    for name, repo in aws_ecr_repository.this : name => repo.repository_url
  }
}

output "registry_id" {
  description = "The AWS account ID — needed for docker login command"
  value       = values(aws_ecr_repository.this)[0].registry_id
}
