variable "region" {
  description = "The only region the sandbox allows."
  type        = string
  default     = "ca-central-1"
}

variable "account_id" {
  description = "Sandbox account; the provider refuses to run against any other."
  type        = string
  default     = "092988563851"
}

variable "environment" {
  description = "Which environment this state describes. Resources are named <name_prefix>-<environment>."
  type        = string
  validation {
    condition     = contains(["staging", "perf", "prod"], var.environment)
    error_message = "environment must be staging, perf or prod."
  }
}

variable "name_prefix" {
  description = "Account-enforced prefix for IAM roles, policies and S3 buckets."
  type        = string
  default     = "dan-berg"
}

variable "permissions_boundary_arn" {
  description = "Boundary the account requires on every IAM role."
  type        = string
  default     = "arn:aws:iam::092988563851:policy/CandidateBoundary"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "kubernetes_version" {
  description = "Within standard support in ca-central-1 (1.34-1.37 as of 2026-10)."
  type        = string
  default     = "1.36"
}

variable "node_instance_type" {
  description = "Graviton: images are built natively on the arm64 dev machine."
  type        = string
  default     = "t4g.large"
}

variable "node_count" {
  description = "One node per Kafka broker (3), so losing or draining a node takes down at most one broker."
  type        = number
  default     = 3
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "postgres_version" {
  type    = string
  default = "17.5"
}

variable "api_public_cidrs" {
  description = "Who may reach the EKS API endpoint from the internet. Narrow to your IP for real use."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
