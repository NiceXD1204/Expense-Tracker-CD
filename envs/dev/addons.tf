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

# "App of apps" root Application - previously bootstrapped by hand via
# `kubectl apply -f gitops/dev/root-app.yaml` per the README. Once ArgoCD
# adopts this, it creates/manages the backend/frontend/db Applications from
# gitops/dev/*-app.yaml on its own.
# Mirrors the kubernetes_manifest.letsencrypt_issuer pattern below: the
# Application CRD is installed by helm_release.argocd in this same apply, so
# this resource depends on that release rather than a separately-installed CRD.
resource "kubernetes_manifest" "argocd_root_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "expense-tracker-dev"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io"
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/NiceXD1204/Expense-Tracker-CD.git"
        targetRevision = "HEAD"
        path           = "gitops/dev"
        directory = {
          include = "{backend-app.yaml,frontend-app.yaml,db-app.yaml}"
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  }

  depends_on = [helm_release.argocd]
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

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

# Slack webhook secret, managed by Terraform (value from the gitignored
# terraform.tfvars, never committed). Previously created manually via
# `kubectl create secret` per the README. Only created when both alerts are
# enabled AND a URL is actually supplied - see var.slack_webhook_url.
resource "kubernetes_secret" "slack_webhook" {
  count = var.enable_slack_alerts && var.slack_webhook_url != "" ? 1 : 0

  metadata {
    name      = local.slack_secret_name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    (local.slack_secret_key) = var.slack_webhook_url
  }

  type = "Opaque"
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

  # kubernetes_secret.slack_webhook must exist BEFORE this release, not after:
  # helm_release defaults to wait=true, so if enable_slack_alerts=true this
  # release blocks until Alertmanager is Ready, which requires the Secret
  # (mounted via alertmanagerSpec.secrets) to already be there. Safe to list
  # even when the secret has count=0 (enable_slack_alerts=false) - Terraform
  # treats a zero-count resource in depends_on as a no-op dependency.
  depends_on = [module.platform, kubernetes_namespace.monitoring, kubernetes_secret.slack_webhook]
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

# --- Backend JWT secret, managed by Terraform ---------------------------------
# Previously created manually via `kubectl create secret`, which meant it was
# lost on every destroy/apply cycle and the backend seed job would fail with
# CreateContainerConfigError until recreated. Generating it here makes the
# environment rebuild cleanly from `terraform apply` alone. The value lives in
# Terraform state (encrypted S3 backend) - acceptable for this dev environment.

# The app namespace is normally created by ArgoCD (CreateNamespace=true), but
# that happens after apply. Create it here so the Secret has somewhere to live;
# ArgoCD will adopt the existing namespace on sync.
resource "kubernetes_namespace" "app" {
  metadata {
    name = "expense-tracker"
  }
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "kubernetes_secret" "backend_jwt" {
  metadata {
    name      = "expense-tracker-backend-secret"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  data = {
    JWT_SECRET_KEY = random_password.jwt_secret.result
  }

  type = "Opaque"
}
