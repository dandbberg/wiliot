resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids # the database tier, not the app subnets
}

# Only the EKS nodes (where pod traffic originates) may connect, and only on 5432.
resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "PostgreSQL from EKS nodes only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_eks" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from EKS nodes and pods"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.allowed_security_group_id
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "trades"
  username = "trades_admin"
  # RDS generates the master password and keeps it in Secrets Manager; it never
  # appears in Git or Terraform state. Only the db-init Job reads it.
  manage_master_user_password = true
  # Applications log in with their IAM role instead of a password.
  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false # documented shortcut

  # TLS is enforced by default on PostgreSQL 15+ (rds.force_ssl=1).

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Tear down cleanly: the reviewers run destroy.
  skip_final_snapshot      = true
  deletion_protection      = false
  delete_automated_backups = true
}
