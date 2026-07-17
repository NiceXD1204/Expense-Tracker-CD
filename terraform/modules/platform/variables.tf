variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "expense-tracker"
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, production) - kept to a single 'dev' env for this project to control cost"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across"
  type        = number
  default     = 2
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "node_instance_types" {
  description = "Instance types for the EKS managed node group (spot)"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 1
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 2
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the CI role, in 'owner/repo' form (e.g. NiceXD1204/expense-tracker)"
  type        = string
}

variable "tags" {
  description = "Extra tags applied to all resources"
  type        = map(string)
  default     = {}
}
