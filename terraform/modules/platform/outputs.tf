output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_arn" {
  value = module.eks.cluster_arn
}

output "region" {
  value = var.region
}

output "ecr_repository_urls" {
  description = "Map of service name -> ECR repository URL"
  value       = { for k, repo in aws_ecr_repository.this : k => repo.repository_url }
}

output "github_actions_role_arn" {
  description = "IAM role ARN for the GitHub Actions OIDC role - put this in the repo's AWS_ROLE_ARN secret"
  value       = module.github_actions_role.arn
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN for the EKS cluster - used for IRSA roles (ExternalDNS etc.)"
  value       = module.eks.oidc_provider_arn
}
