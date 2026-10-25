variable "name" {
  description = "Role name; the account requires the dan-berg- prefix."
  type        = string
}

variable "permissions_boundary_arn" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_host" {
  description = "Cluster OIDC issuer without https://"
  type        = string
}

variable "namespace" {
  type = string
}

variable "service_account" {
  type = string
}

variable "inline_policy" {
  description = "Optional inline policy JSON."
  type        = string
  default     = null
}

variable "inline_policy_name" {
  type    = string
  default = "inline"
}

variable "managed_policy_arns" {
  type    = list(string)
  default = []
}
