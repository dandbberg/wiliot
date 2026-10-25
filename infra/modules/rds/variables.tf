variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "The database tier: subnets with no route to the internet."
  type        = list(string)
}

variable "allowed_security_group_id" {
  description = "The only security group allowed to reach 5432 (the EKS nodes)."
  type        = string
}

variable "instance_class" {
  type = string
}

variable "postgres_version" {
  type = string
}
