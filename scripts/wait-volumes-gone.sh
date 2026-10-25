#!/usr/bin/env bash
# After the k8s stack is destroyed, the EBS CSI driver deletes Kafka's volume
# asynchronously. Wait for that before destroying the cluster (and the driver).
set -euo pipefail
export AWS_REGION="${AWS_REGION:-ca-central-1}"

for _ in $(seq 1 60); do
  n=$(aws ec2 describe-volumes --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name \
        --query 'length(Volumes)' --output text)
  [ "$n" = "0" ] && { echo "no Kubernetes-created EBS volumes left"; exit 0; }
  echo "waiting for $n EBS volume(s) to be deleted..."
  sleep 10
done
echo "volumes still present after 10 minutes; check before destroying infra" >&2
exit 1
