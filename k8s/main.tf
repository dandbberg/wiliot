# What the cluster needs before Argo CD can deploy the apps, and what carries
# AWS-specific values: namespaces, the IRSA service accounts and the storage
# class. Everything else is deployed by Argo CD (argocd.tf, charts/apps).

resource "kubernetes_namespace_v1" "this" {
  for_each = toset(["trades", "kafka", "monitoring", "cert-manager", "keda", "external-secrets"])
  metadata {
    name = each.key
  }
}

# gp3, encrypted. Kafka's and Prometheus's volumes; deleted with their claims.
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

# IRSA: the consumer connects to RDS with its IAM role (no password); db-init
# reads the master secret once to create the DB users.
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
