# Public hosted zone for the app domain. Lives in bootstrap (not envs/dev) so it
# survives `terraform destroy` of the dev environment - the zone's NS values must
# stay stable, since GoDaddy delegates to them. Costs ~$0.50/month.
resource "aws_route53_zone" "main" {
  name    = var.domain_name
  comment = "Hosted zone for the Expense Tracker app - delegated from GoDaddy"
}