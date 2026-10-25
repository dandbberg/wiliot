variable "infra_state_key" {
  description = "State key of this environment's infra stack (outputs: cluster, RDS, roles)."
  type        = string
}

variable "ui_allowed_cidrs" {
  description = "Who may reach the UI gateway (CIDRs). Add an address to let someone else in."
  type        = list(string)
  validation {
    condition     = length(var.ui_allowed_cidrs) > 0 && alltrue([for c in var.ui_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "ui_allowed_cidrs needs at least one valid CIDR; an empty list would open the UIs to everyone."
  }
}

variable "image_tag" {
  description = "Tag of the app image in ECR, pushed by scripts/build-push.sh (git SHA)."
  type        = string
}
