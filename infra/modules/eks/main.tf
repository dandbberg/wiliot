# EKS cluster, worker nodes, add-ons, and the IAM pieces that only exist for
# them: cluster/node roles, the secrets KMS key, the OIDC provider (IRSA) and
# the EBS CSI driver's role. Every role is dan-berg-* with the boundary.

# --- secrets encryption ----------------------------------------------------------

# Envelope encryption for Kubernetes Secrets in etcd.
resource "aws_kms_key" "eks" {
  description             = "${var.name} EKS secrets encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7 # shortest allowed; the key is gone a week after destroy
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# --- control plane role ------------------------------------------------------------

data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name                 = "${var.name}-eks-cluster"
  assume_role_policy   = data.aws_iam_policy_document.eks_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# The cluster role encrypts/decrypts Secrets with our key; the managed policy
# doesn't include KMS.
data "aws_iam_policy_document" "eks_cluster_kms" {
  statement {
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey", "kms:CreateGrant"]
    resources = [aws_kms_key.eks.arn]
  }
}

resource "aws_iam_role_policy" "eks_cluster_kms" {
  name   = "kms"
  role   = aws_iam_role.eks_cluster.id
  policy = data.aws_iam_policy_document.eks_cluster_kms.json
}

# --- node role ------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name                 = "${var.name}-eks-node"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",         # join the cluster
    "AmazonEKS_CNI_Policy",              # VPC CNI assigns pod IPs from node ENIs
    "AmazonEC2ContainerRegistryReadOnly" # pull our image from ECR
  ])
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.key}"
}

# --- cluster ------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true # nodes talk to the API inside the VPC
    endpoint_public_access  = true # kubectl/helm from the dev machine
    public_access_cidrs     = var.api_public_cidrs
  }

  # Access entries instead of the aws-auth ConfigMap; whoever runs Terraform
  # (dan-berg) is cluster admin.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  # Standard support only: extended support costs extra per hour.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster,
    aws_iam_role_policy.eks_cluster_kms,
  ]
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = var.node_subnet_ids

  ami_type       = "AL2023_ARM_64_STANDARD"
  instance_types = [var.node_instance_type]
  capacity_type  = "ON_DEMAND"
  disk_size      = 20

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count + 1 # room for a surge node during upgrades/drains
  }

  update_config {
    max_unavailable = 1 # roll one node at a time
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node,
    aws_eks_addon.vpc_cni, # pods need IPs as soon as nodes join
  ]
}

# --- add-ons ----------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  # Enforce Kubernetes NetworkPolicy (Kafka admits only the pipeline's pods).
  configuration_values = jsonencode({ enableNetworkPolicy = "true" })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.default] # its pods need nodes
}

# Provisions the gp3 volume behind Kafka.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.ebs_csi_role.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.default]
}

# --- IRSA ---------------------------------------------------------------------------

# Lets IAM trust tokens issued by the cluster to its ServiceAccounts.
resource "aws_iam_openid_connect_provider" "eks" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
}

module "ebs_csi_role" {
  source                   = "../irsa-role"
  name                     = "${var.name}-irsa-ebs-csi"
  permissions_boundary_arn = var.permissions_boundary_arn
  oidc_provider_arn        = aws_iam_openid_connect_provider.eks.arn
  oidc_host                = local.oidc_host
  namespace                = "kube-system"
  service_account          = "ebs-csi-controller-sa"
  managed_policy_arns      = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
}

locals {
  oidc_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}
