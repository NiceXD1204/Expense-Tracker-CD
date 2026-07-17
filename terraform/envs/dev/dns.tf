# DNS + TLS wiring for the public domain.
# The hosted zone itself lives in ../../bootstrap so it survives `terraform destroy`
# of this environment (its NS values must stay stable for the GoDaddy delegation).

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# IRSA role for ExternalDNS - lets the external-dns pod manage records in the
# hosted zone (and nothing else), following the same pattern as the EBS CSI role.
module "external_dns_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name                     = "expense-tracker-dev-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [data.aws_route53_zone.main.arn]

  oidc_providers = {
    main = {
      provider_arn               = module.platform.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }
}
