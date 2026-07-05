variable "project_name" {
  description = "Name prefix used for the state bucket and lock table"
  type        = string
  default     = "expense-tracker"
}

variable "region" {
  description = "AWS region to create the state bucket and lock table in"
  type        = string
  default     = "eu-central-1"
}

variable "domain_name" {
  description = "Public domain for the app, delegated from GoDaddy to this Route 53 zone"
  type        = string
  default     = "expensetracker.skin"
}