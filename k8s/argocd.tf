# Argo CD deploys everything that runs in the cluster, from this repository
# (k8s/charts/apps). Terraform only installs Argo CD and creates the root
# Application, handing it the values that come from AWS.

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.10.2" # Argo CD v3.5.4
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  wait       = true
  timeout    = 600

  values = [yamlencode({
    # TLS and the login are the UI gateway's job; Argo CD has its own login too.
    configs = {
      params = { "server.insecure" = true }
      cm = {
        # Application health, so sync waves wait for the apps before them.
        "resource.customizations.health.argoproj.io_Application" = <<-EOT
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil and obj.status.health ~= nil then
            hs.status = obj.status.health.status
            if obj.status.health.message ~= nil then hs.message = obj.status.health.message end
          end
          return hs
        EOT
      }
    }
    dex            = { enabled = false }
    notifications  = { enabled = false }
    applicationSet = { replicas = 0 }
    controller     = { resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "1Gi" } } }
    repoServer     = { resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "512Mi" } } }
    server         = { resources = { requests = { cpu = "20m", memory = "64Mi" }, limits = { memory = "256Mi" } } }
    redis          = { resources = { requests = { cpu = "10m", memory = "32Mi" }, limits = { memory = "128Mi" } } }
  })]
}

resource "helm_release" "argocd_root" {
  name      = "argocd-root"
  chart     = "${path.module}/charts/argocd-root"
  namespace = kubernetes_namespace_v1.argocd.metadata[0].name

  values = [yamlencode({
    repoURL  = var.git_repo_url
    revision = var.git_revision
    aws = {
      region                 = local.infra.region
      ecrRepository          = local.infra.ecr_repository_url
      imageTag               = var.image_tag
      dbHost                 = local.infra.db_host
      dbPort                 = local.infra.db_port
      dbName                 = local.infra.db_name
      dbMasterSecretArn      = local.infra.db_master_secret_arn
      grafanaDbSecretArn     = local.infra.grafana_db_secret_arn
      grafanaAdminSecret     = local.infra.grafana_admin_secret_name
      grafanaDbSecret        = local.infra.grafana_db_secret_name
      uiAdminSecret          = try(local.infra.ui_admin_secret_name, "")
      externalSecretsRoleArn = local.infra.irsa_role_arns["external-secrets"]
      uiAllowedCidrs         = var.ui_allowed_cidrs
    }
  })]

  # The apps need the namespaces, service accounts and storage class Terraform
  # creates; on destroy they go first (argo_teardown), these after.
  depends_on = [
    helm_release.argocd,
    kubernetes_namespace_v1.this,
    kubernetes_service_account_v1.irsa,
    kubernetes_storage_class_v1.gp3,
  ]
}

# On destroy: stop the root app from re-creating its children, then delete the
# apps in reverse wave order and wait for each wave to be gone, so operators
# (KEDA, cert-manager) outlive the objects whose finalizers they handle.
resource "terraform_data" "argo_teardown" {
  input = {
    cluster = local.infra.cluster_name
    region  = local.infra.region
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    environment = {
      CLUSTER    = self.input.cluster
      AWS_REGION = self.input.region
    }
    command = "${path.module}/../scripts/argo-teardown.sh"
  }

  depends_on = [helm_release.argocd_root]
}
