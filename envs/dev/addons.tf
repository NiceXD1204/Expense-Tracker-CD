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
