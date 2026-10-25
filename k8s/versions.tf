terraform {
  required_version = ">= 1.10"

  # Separate state from infra/ so the cluster exists before the kubernetes/helm
  # providers are configured, and so destroy can remove workloads first.
  backend "s3" {
    bucket         = "dan-berg-tfstate-092988563851"
    key            = "k8s/terraform.tfstate"
    region         = "ca-central-1"
    dynamodb_table = "dan-berg-tflock"
    encrypt        = true
  }

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.38"
    }
  }
}

data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "dan-berg-tfstate-092988563851"
    key    = "infra/terraform.tfstate"
    region = "ca-central-1"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs

  # Short-lived token from the AWS CLI on every call; no static credentials.
  cluster_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.infra.cluster_name, "--region", local.infra.region]
  }
}

provider "kubernetes" {
  host                   = local.infra.cluster_endpoint
  cluster_ca_certificate = base64decode(local.infra.cluster_ca)
  exec {
    api_version = local.cluster_exec.api_version
    command     = local.cluster_exec.command
    args        = local.cluster_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.infra.cluster_endpoint
    cluster_ca_certificate = base64decode(local.infra.cluster_ca)
    exec                   = local.cluster_exec
  }
}
