variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the CI role, in 'owner/repo' form (e.g. NiceXD1204/expense-tracker)"
  type        = string
}

variable "node_instance_types" {
  description = "Instance types for the EKS managed node group (spot)"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 1
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 2
}

variable "enable_slack_alerts" {
  description = <<-EOT
    Whether Alertmanager sends Slack notifications for pod crash-loops and
    other warning/critical alerts. The webhook URL itself is never a
    Terraform variable - it lives only in a Kubernetes Secret you create
    directly in the cluster (see expense-tracker-infra/README.md), so it
    never touches Terraform state or this repo. Leave this false until that
    secret exists, or the kube-prometheus-stack release will fail to start
    (Alertmanager can't mount a Secret that isn't there yet).
  EOT
  type        = bool
  default     = false
}
