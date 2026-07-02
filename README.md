# expense-tracker-infra

Terraform infrastructure + GitOps desired-state for the [expense-tracker](https://github.com/NiceXD1204/expense-tracker)
app: VPC, EKS, ECR, GitHub Actions OIDC role, and cluster add-ons (ingress-nginx, ArgoCD,
kube-prometheus-stack), plus the ArgoCD `Application` manifests ArgoCD watches to deploy
the app.

## ⚠️ Cost management - read this first

A managed EKS control plane costs **~$0.10/hour (~$73/month)** even with zero worker
nodes, plus ~$0.045/hour for the NAT gateway and a small amount for the spot worker
node(s) and load balancer. This project is designed to be brought up for a working
session and torn down afterward:

```
terraform apply    # ~15-20 min, starts billing
... demo / grade / develop ...
terraform destroy  # tears everything down
```

Rough cost for a few hours of use: well under $5. Don't leave the cluster running
overnight/across days unless you intend to.

## Layout

```
bootstrap/   # one-time: S3 state bucket + DynamoDB lock table
modules/platform/  # reusable module: VPC, EKS, ECR, GitHub OIDC IAM role
envs/dev/    # the (only, for cost reasons) environment - calls modules/platform
             # and installs cluster add-ons via Helm
gitops/dev/  # ArgoCD Application manifests + per-env Helm values for the app
```

## One-time setup

### 1. Create the Terraform state backend

```bash
cd bootstrap
terraform init
terraform apply
terraform output backend_config_hcl
```

Copy the output into `envs/dev/backend.hcl` (see `backend.hcl.example`).

### 2. Configure envs/dev

```bash
cd envs/dev
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl
# edit both files: set github_repo to your "owner/repo", paste backend config
terraform init -backend-config=backend.hcl
```

> Note: if your AWS account already has a GitHub OIDC provider
> (`token.actions.githubusercontent.com`) configured, remove the
> `module "github_oidc_provider"` block in
> `modules/platform/iam-github-oidc.tf` to avoid a duplicate-resource error.

### 3. Apply

```bash
terraform plan
terraform apply
```

This creates the VPC/EKS/ECR/IAM, then installs ingress-nginx, ArgoCD, and
kube-prometheus-stack via the Helm provider.

## After apply

### Access the cluster

```bash
$(terraform output -raw configure_kubectl)
kubectl get nodes
```

### Access ArgoCD

```bash
# Get the LoadBalancer hostname (may take a minute to provision)
terraform output -raw argocd_ingress_hostname_command | bash

# Get the admin password
terraform output -raw argocd_admin_password_command | bash
```

Open `http://<the-hostname>` in a browser, log in as `admin` with that password.

### Deploy the app via ArgoCD (GitOps)

Point ArgoCD at the "app of apps" once:

```bash
kubectl apply -f ../../gitops/dev/root-app.yaml
```

ArgoCD will then create and sync the `expense-tracker-backend-dev`,
`expense-tracker-frontend-dev`, and `expense-tracker-db-dev` Applications from
`gitops/dev/*-app.yaml`, which pull Helm charts from the `expense-tracker` app repo
and env-specific values from `gitops/dev/values-*.yaml` in this repo.

### CI/CD wiring

Set these GitHub Actions secrets/variables in the `expense-tracker` app repo:

- `AWS_ROLE_ARN` = `terraform output -raw github_actions_role_arn`
- ECR repo URLs: `terraform output ecr_repository_urls`
- `SLACK_WEBHOOK_URL` = your Slack Incoming Webhook URL (used by the CI/deploy
  workflows to post build/deploy failure and success notifications). Only
  needed in the `expense-tracker` app repo, not this one - only its workflows
  post to Slack.

### Slack alerts for pod issues (optional)

Alertmanager (part of kube-prometheus-stack) can post to Slack when pods
crash-loop or any other default warning/critical alert fires. The webhook URL
is never a Terraform variable - it lives only in a Kubernetes Secret you
create directly in the cluster, so it never touches this repo or Terraform
state:

```bash
kubectl create namespace monitoring
kubectl create secret generic slack-webhook \
  --namespace monitoring \
  --from-literal=slack_api_url='<YOUR_SLACK_WEBHOOK_URL>'
```

Then set `enable_slack_alerts = true` in `terraform.tfvars` and re-apply
(`terraform apply`) so Alertmanager mounts the secret and starts routing
`severity =~ "warning|critical"` alerts (including the built-in
`KubePodCrashLooping` rule) to Slack.

If you enable it before the secret exists, the `kube-prometheus-stack` release
will fail because Alertmanager can't mount a Secret that isn't there yet -
create the secret first.

## Tear down

```bash
cd envs/dev
terraform destroy
```

(Run `bootstrap`'s `terraform destroy` too only if you're done with the project entirely -
it holds the state bucket/lock table for `envs/dev`.)
