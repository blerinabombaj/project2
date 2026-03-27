# These values are needed by other parts of the config:
# - cluster_name and cluster_endpoint: for kubectl and ArgoCD
# - cluster_certificate_authority_data: for kubectl authentication
# - node_role_arn: for IRSA setup in step 3
# - oidc_provider_arn: for IRSA — lets pods assume IAM roles

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider — needed for IRSA in step 3"
  value       = module.eks.oidc_provider_arn
}

output "node_role_arn" {
  value = module.eks.eks_managed_node_groups["default"].iam_role_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}
