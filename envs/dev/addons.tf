# Cluster add-ons installed via Helm as part of `terraform apply`, per the project spec.

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.3"
  namespace        = "ingress-nginx"
  create_namespace = true

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  depends_on = [module.platform]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.7"
  namespace        = "argocd"
  create_namespace = true

  # Expose the ArgoCD UI via the ingress controller's load balancer for easy access.
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  set {
    name  = "server.ingress.enabled"
    value = "true"
  }

  set {
    name  = "server.ingress.ingressClassName"
    value = "nginx"
  }

  # ArgoCD server speaks HTTP behind the ingress; this avoids redirect loops with TLS terminated at the LB.
  set {
    name  = "server.extraArgs[0]"
    value = "--insecure"
  }

  depends_on = [helm_release.ingress_nginx]
}

locals {
  # Name of the Kubernetes Secret (created manually, see README) holding the
  # Slack webhook URL under the key "slack_api_url" - never a Terraform
  # variable, so the actual URL never touches this repo, tfvars, or state.
  slack_secret_name = "slack-webhook"
  slack_secret_key  = "slack_api_url"

  # merge()/concat() (not a raw ?: between object literals of different shape)
  # deliberately, since Terraform's conditional operator requires both branches
  # of a ?: to have identical attribute sets for object literals - merge/concat
  # sidestep that and let enabled/disabled cleanly share one structure.
  alertmanager_config = {
    global = merge(
      { resolve_timeout = "5m" },
      # Alertmanager reads the webhook from the file mounted from the Secret
      # named in alertmanagerSpec.secrets below, instead of a literal value.
      var.enable_slack_alerts ? { slack_api_url_file = "/etc/alertmanager/secrets/${local.slack_secret_name}/${local.slack_secret_key}" } : {}
    )
    route = {
      receiver = "default"
      routes = var.enable_slack_alerts ? [
        {
          # Catches KubePodCrashLooping and every other default kube-prometheus-stack
          # alert tagged warning/critical (KubePodNotReady, KubeJobFailed,
          # KubeDeploymentReplicasMismatch, etc.) - not just crash-loops.
          matchers = ["severity =~ \"warning|critical\""]
          receiver = "slack-notifications"
        },
      ] : []
    }
    receivers = concat(
      [{ name = "default" }],
      var.enable_slack_alerts ? [
        {
          name = "slack-notifications"
          slack_configs = [
            {
              channel       = "#alerts"
              send_resolved = true
              title         = "{{ .CommonAnnotations.summary }}"
              text          = "{{ .CommonAnnotations.description }}"
            },
          ]
        },
      ] : []
    )
  }

  alertmanager_values = {
    config = local.alertmanager_config
    alertmanagerSpec = {
      # Mounts the pre-created Secret's keys as files under
      # /etc/alertmanager/secrets/<secret-name>/<key> in the Alertmanager pod.
      # Empty when disabled, so there's nothing to mount and no dependency on
      # the Secret existing yet.
      secrets = var.enable_slack_alerts ? [local.slack_secret_name] : []
    }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "65.5.1"
  namespace        = "monitoring"
  create_namespace = true

  values = [
    yamlencode({
      alertmanager = local.alertmanager_values
      # Keep storage requests modest for a small spot node group.
      prometheus = {
        prometheusSpec = {
          resources = {
            requests = { cpu = "100m", memory = "512Mi" }
            limits   = { cpu = "500m", memory = "1Gi" }
          }
        }
      }
    })
  ]

  depends_on = [module.platform]
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns"
  chart            = "external-dns"
  version          = "1.15.0"
  namespace        = "external-dns"
  create_namespace = true

  values = [
    yamlencode({
      provider = { name = "aws" }
      # Only manage records for our domain, and only from Ingress resources.
      domainFilters = [var.domain_name]
      sources       = ["ingress"]
      # "sync" would delete records it no longer owns; "upsert-only" is safer
      # for a zone that must survive cluster teardown - stale records are
      # simply overwritten on the next cluster bring-up.
      policy = "upsert-only"
      # TXT ownership records let ExternalDNS track which records it created.
      txtOwnerId = "expense-tracker-dev"
      serviceAccount = {
        create = true
        name   = "external-dns"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.external_dns_irsa_role.iam_role_arn
        }
      }
    })
  ]

  depends_on = [helm_release.ingress_nginx]
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.16.2"
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "crds.enabled"
    value = "true"
  }

  depends_on = [module.platform]
}

# ClusterIssuer telling cert-manager how to get certs from Let's Encrypt.
# HTTP-01 validation: LE hits http://<host>/.well-known/acme-challenge/... via
# the nginx ingress, so no extra IAM is needed (unlike DNS-01).
resource "kubernetes_manifest" "letsencrypt_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.letsencrypt_email
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [
          {
            http01 = {
              ingress = {
                ingressClassName = "nginx"
              }
            }
          }
        ]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}
