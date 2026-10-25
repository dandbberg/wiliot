# Grafana's admin password: generated here, stored as a Kubernetes Secret
# (encrypted in etcd with the infra KMS key). It is also in this stack's
# Terraform state, which lives in the private, encrypted state bucket.
# Viewing dashboards needs no login (anonymous Viewer).
resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  }
}

resource "helm_release" "monitoring" {
  name       = "monitoring"
  repository = "oci://ghcr.io/prometheus-community/charts"
  chart      = "kube-prometheus-stack"
  version    = "92.11.0"
  namespace  = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  values     = [file("${path.module}/values/kube-prometheus-stack.yaml")]
  wait       = true
  timeout    = 900

  depends_on = [kubernetes_secret_v1.grafana_admin]
}
