# Producer + consumer (and their topic/db init Jobs). Same chart as minikube;
# only these values differ.
resource "helm_release" "pipeline" {
  name      = "pipeline"
  chart     = "${path.module}/charts/pipeline"
  namespace = kubernetes_namespace_v1.this["trades"].metadata[0].name
  wait      = true
  timeout   = 600

  values = [yamlencode({
    image = {
      repository = local.infra.ecr_repository_url
      tag        = var.image_tag
      pullPolicy = "IfNotPresent"
    }
    region = local.infra.region

    kafka = {
      bootstrap = "kafka.kafka.svc.cluster.local:9092"
      auth      = "none" # in-cluster only: no Service outside the cluster, no load balancer
      # Single broker: one replica per partition.
      replication       = 1
      minInsyncReplicas = 1
    }

    db = {
      host           = local.infra.db_host
      port           = local.infra.db_port
      name           = local.infra.db_name
      auth           = "iam" # consumer logs in with its IAM role; no password
      user           = "consumer"
      adminSecretArn = local.infra.db_master_secret_arn # read only by db-init
    }

    serviceAccounts = {
      producer   = "default" # needs no AWS access
      consumer   = kubernetes_service_account_v1.irsa["consumer"].metadata[0].name
      dbAdmin    = kubernetes_service_account_v1.irsa["db-init"].metadata[0].name
      topicAdmin = "default"
    }

    monitoring = {
      enabled   = true
      dashboard = "trades-pipeline-iam.json"
    }
  })]

  # topic-init needs Kafka up; the PodMonitor/rules need the monitoring CRDs.
  depends_on = [helm_release.kafka, helm_release.monitoring]
}
