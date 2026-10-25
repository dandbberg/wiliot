output "ui_urls" {
  description = "The web UIs. The certificate is from the cluster's own CA, so the browser warns once."
  value = {
    grafana      = "https://${local.ui_host}:3000/d/trades-pipeline"
    kafka_ui     = "https://${local.ui_host}:8080/ui/clusters/eks/all-topics/trades"
    prometheus   = "https://${local.ui_host}:9090/alerts"
    alertmanager = "https://${local.ui_host}:9093/"
  }
}
