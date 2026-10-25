#!/usr/bin/env bash
# After the k8s stack is destroyed, AWS resources that Kubernetes created are
# deleted asynchronously: Kafka's and Prometheus's EBS volumes, and the UI
# gateway's load balancer. Wait for them before destroying the cluster and the
# VPC, which can't be deleted while a load balancer is still in it.
#   CLUSTER=<name> scripts/wait-k8s-cleanup.sh
set -euo pipefail
export AWS_REGION="${AWS_REGION:-ca-central-1}"
: "${CLUSTER:?CLUSTER is required}"

volumes() {
  aws ec2 describe-volumes --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name \
    --query 'length(Volumes)' --output text
}
load_balancers() { # tagged by EKS with kubernetes.io/cluster/<name>
  local arns n=0
  arns=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text)
  for arn in $arns; do
    aws elbv2 describe-tags --resource-arns "$arn" \
      --query "TagDescriptions[].Tags[?Key=='kubernetes.io/cluster/$CLUSTER']" --output text | grep -q . && n=$((n + 1))
  done
  echo $n
}

for _ in $(seq 1 60); do
  v=$(volumes); l=$(load_balancers)
  [ "$v" = "0" ] && [ "$l" = "0" ] && { echo "no Kubernetes-created volumes or load balancers left"; exit 0; }
  echo "waiting for $v EBS volume(s) and $l load balancer(s) to be deleted..."
  sleep 10
done
echo "still present after 10 minutes; check before destroying infra" >&2
exit 1
