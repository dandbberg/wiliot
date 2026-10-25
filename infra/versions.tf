terraform {
  required_version = ">= 1.10"

  # State bucket and lock table are pre-provisioned by the sandbox (see environment PDF).
  backend "s3" {
    bucket         = "dan-berg-tfstate-092988563851"
    key            = "infra/terraform.tfstate"
    region         = "ca-central-1"
    dynamodb_table = "dan-berg-tflock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Guard against accidentally pointing at another account or region.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = var.name_prefix
      ManagedBy = "terraform"
      Stack     = "infra"
      # The sandbox's IAM policy recognises our objects by this tag (as well as
      # by the dan-berg-* name), so every role and policy carries it.
      candidate = var.name_prefix
    }
  }
}
