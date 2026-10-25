data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.name_prefix}-${var.environment}" # e.g. dan-berg-staging; still matches the account's dan-berg-* rule
  # ca-central-1 has 1a, 1b and 1d (no 1c), so never hard-code zone names.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

# VPC with three tiers per AZ: public (NAT only), private (EKS), database (RDS,
# no route to the internet).
module "network" {
  source   = "./modules/network"
  name     = local.name
  vpc_cidr = var.vpc_cidr
  azs      = local.azs
}

module "eks" {
  source                   = "./modules/eks"
  name                     = local.name
  kubernetes_version       = var.kubernetes_version
  permissions_boundary_arn = var.permissions_boundary_arn
  subnet_ids               = module.network.private_subnet_ids
  # Nodes in one AZ: EBS volumes are AZ-bound, so a broker evicted by a drain can
  # restart on another node with its volume. Production would also spread nodes
  # and brokers across AZs (and accept that an AZ's broker waits for its AZ).
  node_subnet_ids    = [module.network.private_subnet_ids[0]]
  node_instance_type = var.node_instance_type
  node_count         = var.node_count
  api_public_cidrs   = var.api_public_cidrs
}

module "rds" {
  source                    = "./modules/rds"
  name                      = local.name
  vpc_id                    = module.network.vpc_id
  subnet_ids                = module.network.database_subnet_ids
  allowed_security_group_id = module.eks.cluster_security_group_id
  instance_class            = var.db_instance_class
  postgres_version          = var.postgres_version
}

# --- workload roles (IRSA): each trusts exactly one ServiceAccount ---------------

# Consumer: IAM login to Postgres as the "consumer" DB user, nothing else.
module "consumer_role" {
  source                   = "./modules/irsa-role"
  name                     = "${local.name}-irsa-consumer"
  permissions_boundary_arn = var.permissions_boundary_arn
  oidc_provider_arn        = module.eks.oidc_provider_arn
  oidc_host                = module.eks.oidc_host
  namespace                = "trades"
  service_account          = "consumer"
  inline_policy_name       = "rds-db-connect"
  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:aws:rds-db:${var.region}:${var.account_id}:dbuser:${module.rds.resource_id}/consumer"
    }]
  })
}

# db-init: read the RDS-managed master secret (to create the users) and the
# grafana-db secret (to set that read-only user's password). Nothing else.
module "db_init_role" {
  source                   = "./modules/irsa-role"
  name                     = "${local.name}-irsa-db-init"
  permissions_boundary_arn = var.permissions_boundary_arn
  oidc_provider_arn        = module.eks.oidc_provider_arn
  oidc_host                = module.eks.oidc_host
  namespace                = "trades"
  service_account          = "db-init"
  inline_policy_name       = "master-secret"
  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = [module.rds.master_secret_arn, aws_secretsmanager_secret.grafana_db.arn]
    }]
  })
}
