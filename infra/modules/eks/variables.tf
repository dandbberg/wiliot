variable "name" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "permissions_boundary_arn" {
  type = string
}

variable "subnet_ids" {
  description = "Control plane ENIs; EKS requires subnets in at least two AZs."
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Where worker nodes run."
  type        = list(string)
}

variable "node_instance_type" {
  type = string
}

variable "node_count" {
  type = number
}

variable "api_public_cidrs" {
  type = list(string)
}
