# Workloads on EKS, applied after infra/. Destroy runs in reverse: the pipeline,
# then Kafka (its StatefulSet deletes its EBS-backed PVC), then monitoring.

resource "kubernetes_namespace_v1" "this" {
  for_each = toset(["trades", "kafka", "monitoring"])
  metadata {
    name = each.key
  }
}

# EBS gp3 for Kafka. WaitForFirstConsumer creates the volume in the AZ of the
# node the pod lands on; Delete removes it when the PVC goes.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

# ServiceAccounts for the two workloads that need AWS: IRSA maps each to its own
# IAM role (created in infra/, trusting exactly this namespace/name).
resource "kubernetes_service_account_v1" "irsa" {
  for_each = toset(["consumer", "db-init"])
  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.this["trades"].metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = local.infra.irsa_role_arns[each.key]
    }
  }
}

resource "helm_release" "kafka" {
  name      = "kafka"
  chart     = "${path.module}/charts/kafka"
  namespace = kubernetes_namespace_v1.this["kafka"].metadata[0].name
  wait      = true
  timeout   = 600

  depends_on = [kubernetes_storage_class_v1.gp3]
}
