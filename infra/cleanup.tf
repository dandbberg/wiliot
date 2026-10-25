# EKS leaves things behind that Terraform doesn't own: the VPC CNI's network
# interfaces from nodes that are already gone ("aws-K8S-i-..."), and then the
# cluster security group EKS couldn't delete while they used it. Either one
# blocks deleting the subnets and the VPC. This runs on destroy only, after the
# cluster (module.eks depends on it) and before the network (it depends on that).
resource "terraform_data" "eks_leftovers" {
  input = {
    vpc_id  = module.network.vpc_id
    cluster = local.name
    region  = var.region
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    environment = {
      VPC        = self.input.vpc_id
      CLUSTER    = self.input.cluster
      AWS_REGION = self.input.region
    }
    command = <<-EOT
      set -u
      for eni in $(aws ec2 describe-network-interfaces \
          --filters Name=vpc-id,Values=$VPC Name=status,Values=available Name=description,Values='aws-K8S-*' \
          --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
        echo "deleting leftover CNI interface $eni"; aws ec2 delete-network-interface --network-interface-id $eni
      done
      for sg in $(aws ec2 describe-security-groups \
          --filters Name=vpc-id,Values=$VPC Name=tag:aws:eks:cluster-name,Values=$CLUSTER \
          --query 'SecurityGroups[].GroupId' --output text); do
        echo "deleting leftover cluster security group $sg"; aws ec2 delete-security-group --group-id $sg
      done
      true
    EOT
  }
}
