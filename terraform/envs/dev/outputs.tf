output "cluster_name" {
  value = module.platform.cluster_name
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the cluster"
  value       = "aws eks update-kubeconfig --name ${module.platform.cluster_name} --region ${var.region}"
}

output "ecr_repository_urls" {
  value = module.platform.ecr_repository_urls
}

output "github_actions_role_arn" {
  description = "Put this in the app repo's AWS_ROLE_ARN GitHub secret"
  value       = module.platform.github_actions_role_arn
}

output "argocd_admin_password_command" {
  description = "Run this (after configure_kubectl) to retrieve the ArgoCD initial admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

output "argocd_ingress_hostname_command" {
  description = "Run this to get the LoadBalancer hostname that fronts ArgoCD (and app ingresses)"
  value       = "kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo"
}
