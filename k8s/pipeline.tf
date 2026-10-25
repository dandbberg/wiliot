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
      auth      = "mtls" # TLS + client certificate; ACLs per component (charts/kafka)
      # 3 brokers: every partition on all 3, writes need 2 in sync.
      replication       = 3
      minInsyncReplicas = 2
    }

    db = {
      host           = local.infra.db_host
      port           = local.infra.db_port
      name           = local.infra.db_name
      auth           = "iam" # consumer logs in with its IAM role; no password
      user           = "consumer"
      adminSecretArn = local.infra.db_master_secret_arn # read only by db-init
      # db-init creates the read-only "grafana" user with this secret's password.
      readerSecretArn = local.infra.grafana_db_secret_arn
    }

    serviceAccounts = {
      producer   = "default" # needs no AWS access
      consumer   = kubernetes_service_account_v1.irsa["consumer"].metadata[0].name
      dbAdmin    = kubernetes_service_account_v1.irsa["db-init"].metadata[0].name
      topicAdmin = "default"
    }

    consumer = {
      autoscaling = { enabled = true } # KEDA, 2-12 replicas on lag
    }

    monitoring = {
      enabled   = true
      dashboard = "trades-pipeline.json" # same as minikube, SQL panels included
    }
  })]

  # topic-init needs Kafka up; the PodMonitor/rules need the monitoring CRDs.
  depends_on = [helm_release.kafka, helm_release.monitoring, helm_release.keda]
}
