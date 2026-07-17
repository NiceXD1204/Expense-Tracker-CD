module "platform" {
  source = "../../modules/platform"

  region      = var.region
  environment = "dev"
  github_repo = var.github_repo

  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}

# Cluster auth for the kubernetes/helm providers below. Re-evaluated on every
# plan/apply since EKS auth tokens are short-lived.
data "aws_eks_cluster_auth" "this" {
  name = module.platform.cluster_name
}

provider "kubernetes" {
  host                   = module.platform.cluster_endpoint
  cluster_ca_certificate = base64decode(module.platform.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.platform.cluster_endpoint
    cluster_ca_certificate = base64decode(module.platform.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
