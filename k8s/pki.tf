# cert-manager and the internal CA for Kafka mTLS. Keys and certificates are
# generated inside the cluster as Kubernetes Secrets; none passes through
# Terraform, so none is in state.

resource "kubernetes_namespace_v1" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "oci://quay.io/jetstack/charts"
  chart      = "cert-manager"
  version    = "v1.21.3"
  namespace  = kubernetes_namespace_v1.cert_manager.metadata[0].name
  wait       = true
  timeout    = 600

  values = [yamlencode({
    crds      = { enabled = true }
    resources = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "256Mi" } }
  })]
}

resource "helm_release" "kafka_pki" {
  name      = "kafka-pki"
  chart     = "${path.module}/charts/kafka-pki"
  namespace = kubernetes_namespace_v1.cert_manager.metadata[0].name

  depends_on = [helm_release.cert_manager] # needs its CRDs and webhook
}
