#!/usr/bin/env bash
# Make whoever runs this (an AWS admin of the account) a cluster admin, so
# kubectl, make health, make db and the rest work for them. EKS access entries
# are separate from IAM: being AWS admin alone gets "Unauthorized" from kubectl.
#   CLUSTER=<name> scripts/grant-access.sh      (make access)
# Safe to re-run. The entry is deleted with the cluster.
set -euo pipefail
export AWS_REGION="${AWS_REGION:-ca-central-1}"
: "${CLUSTER:?CLUSTER is required}"

caller=$(aws sts get-caller-identity --query Arn --output text)
case "$caller" in
  *:assumed-role/*)
    # A role session (SSO, assumed role): the entry must name the role itself.
    role=$(echo "$caller" | cut -d/ -f2)
    principal=$(aws iam get-role --role-name "$role" --query Role.Arn --output text)
    ;;
  *:user/*) principal="$caller" ;;
  *) echo "can't grant access to $caller; use an IAM user or role" >&2; exit 1 ;;
esac
echo "granting cluster admin on $CLUSTER to $principal"

if aws eks describe-access-entry --cluster-name "$CLUSTER" --principal-arn "$principal" >/dev/null 2>&1; then
  echo "  access entry already exists"
else
  # SSO roles have a path (/aws-reserved/sso.amazonaws.com/...); if EKS refuses
  # the full ARN, retry with the path left out.
  aws eks create-access-entry --cluster-name "$CLUSTER" --principal-arn "$principal" >/dev/null 2>&1 || {
    principal="arn:aws:iam::$(echo "$principal" | cut -d: -f5):role/${principal##*/}"
    aws eks create-access-entry --cluster-name "$CLUSTER" --principal-arn "$principal" >/dev/null
  }
  echo "  access entry created"
fi

aws eks associate-access-policy --cluster-name "$CLUSTER" --principal-arn "$principal" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster >/dev/null
echo "  cluster-admin policy associated"
