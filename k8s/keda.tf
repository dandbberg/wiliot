# KEDA: scales the consumer on Kafka consumer-group lag (ScaledObject in the
# pipeline chart). It authenticates to Kafka with its own client certificate.
resource "kubernetes_namespace_v1" "keda" {
  metadata {
    name = "keda"
  }
}

resource "helm_release" "keda" {
  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = "2.21.0"
  namespace  = kubernetes_namespace_v1.keda.metadata[0].name
  wait       = true
  timeout    = 600

  values = [yamlencode({
    resources = {
      operator     = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "512Mi" } }
      metricServer = { requests = { cpu = "50m", memory = "64Mi" }, limits = { memory = "256Mi" } }
      webhooks     = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
    }
  })]
}
