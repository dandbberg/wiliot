# One public entry point for the web UIs: an NLB (no DNS in this account, so
# AWS's own hostname), TLS from the cluster CA, one login from Secrets Manager.
# Only var.ui_allowed_cidrs can reach it.
resource "helm_release" "ui_gateway" {
  name      = "ui-gateway"
  chart     = "${path.module}/charts/ui-gateway"
  namespace = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  wait      = true # until the NLB has a hostname
  timeout   = 600

  values = [yamlencode({
    allowedCidrs = var.ui_allowed_cidrs
    # try(): lets destroy run against an infra state from before this output existed.
    adminSecret = try(local.infra.ui_admin_secret_name, "")
  })]

  # Its certificate, login and upstreams must exist first.
  depends_on = [helm_release.kafka_pki, helm_release.external_secrets_config, helm_release.monitoring, helm_release.kafka]
}

data "kubernetes_service_v1" "ui_gateway" {
  metadata {
    name      = "ui-gateway"
    namespace = helm_release.ui_gateway.namespace
  }
  depends_on = [helm_release.ui_gateway]
}

locals {
  # try(): empty while the NLB is still being created, and during destroy.
  ui_host = try(data.kubernetes_service_v1.ui_gateway.status[0].load_balancer[0].ingress[0].hostname, "")
}
