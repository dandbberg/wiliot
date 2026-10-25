variable "image_tag" {
  description = "Tag of the app image in ECR, pushed by scripts/build-push.sh (git SHA)."
  type        = string
}
