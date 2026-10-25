# Passwords come from Secrets Manager through External Secrets: none is
# generated here, so none is in this stack's state.

resource "kubernetes_namespace_v1" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "oci://ghcr.io/external-secrets/charts"
  chart      = "external-secrets"
  version    = "2.14.0"
  namespace  = kubernetes_namespace_v1.external_secrets.metadata[0].name
  wait       = true
  timeout    = 600

  values = [yamlencode({
    serviceAccount = {
      name = "external-secrets"
      # IRSA: may read only the UI secrets in infra/secrets.tf.
      annotations = { "eks.amazonaws.com/role-arn" = local.infra.irsa_role_arns["external-secrets"] }
    }
    resources = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
  })]
}

resource "helm_release" "external_secrets_config" {
  name      = "external-secrets-config"
  chart     = "${path.module}/charts/external-secrets-config"
  namespace = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  values = [yamlencode({
    region             = local.infra.region
    namespace          = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
    grafanaAdminSecret = local.infra.grafana_admin_secret_name
    grafanaDbSecret    = local.infra.grafana_db_secret_name
  })]

  depends_on = [helm_release.external_secrets] # needs its CRDs
}

resource "helm_release" "monitoring" {
  name       = "monitoring"
  repository = "oci://ghcr.io/prometheus-community/charts"
  chart      = "kube-prometheus-stack"
  version    = "92.11.0"
  namespace  = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  wait       = true
  timeout    = 900

  values = [
    file("${path.module}/values/kube-prometheus-stack.yaml"),
    # Only the parts that depend on infra outputs.
    yamlencode({
      grafana = {
        additionalDataSources = [{
          name = "Trades DB"
          uid  = "trades-db" # the dashboard's SQL panels reference this uid
          type = "grafana-postgresql-datasource"
          url  = "${local.infra.db_host}:${local.infra.db_port}"
          user = "grafana"
          jsonData = {
            database        = local.infra.db_name
            sslmode         = "require" # RDS enforces TLS
            postgresVersion = 1700
          }
          secureJsonData = { password = "$TRADES_DB_PASSWORD" } # from the synced Secret, at runtime
        }]
      }
    }),
  ]

  depends_on = [helm_release.external_secrets_config]
}

# Postgres server metrics for the dashboard's database panels, as the same
# read-only user.
resource "helm_release" "postgres_exporter" {
  name       = "postgres-exporter"
  repository = "oci://ghcr.io/prometheus-community/charts"
  chart      = "prometheus-postgres-exporter"
  version    = "8.2.0"
  namespace  = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  wait       = true
  timeout    = 300

  values = [yamlencode({
    config = {
      datasource = {
        host           = local.infra.db_host
        user           = "grafana"
        passwordSecret = { name = "grafana-trades-db", key = "password" }
        database       = local.infra.db_name
        sslmode        = "require"
      }
    }
    serviceMonitor = { enabled = true }
    resources      = { requests = { cpu = "20m", memory = "32Mi" }, limits = { memory = "128Mi" } }
  })]

  # Its DB user is created by the pipeline's db-init Job.
  depends_on = [helm_release.monitoring, helm_release.pipeline]
}
