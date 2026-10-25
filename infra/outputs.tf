# Consumed by the k8s stack via terraform_remote_state, and by the Makefile.
output "region" {
  value = var.region
}

output "name_prefix" {
  value = var.name_prefix
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca" {
  value = module.eks.cluster_ca
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "db_host" {
  value = module.rds.address
}

output "db_port" {
  value = module.rds.port
}

output "db_name" {
  value = module.rds.db_name
}

output "db_master_secret_arn" {
  value = module.rds.master_secret_arn
}

output "irsa_role_arns" {
  value = {
    consumer         = module.consumer_role.arn
    db-init          = module.db_init_role.arn
    external-secrets = module.external_secrets_role.arn
  }
}

# Names only: the values never leave Secrets Manager except through External Secrets.
output "grafana_admin_secret_name" {
  value = aws_secretsmanager_secret.grafana_admin.name
}

output "grafana_db_secret_name" {
  value = aws_secretsmanager_secret.grafana_db.name
}

output "grafana_db_secret_arn" {
  value = aws_secretsmanager_secret.grafana_db.arn
}
