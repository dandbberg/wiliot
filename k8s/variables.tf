variable "infra_state_key" {
  description = "State key of this environment's infra stack (outputs: cluster, RDS, roles)."
  type        = string
}

variable "image_tag" {
  description = "Tag of the app image in ECR, pushed by scripts/build-push.sh (git SHA)."
  type        = string
}
