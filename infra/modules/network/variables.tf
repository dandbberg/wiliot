variable "name" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  description = "Exactly three availability zones."
  type        = list(string)
}
