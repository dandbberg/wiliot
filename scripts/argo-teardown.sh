#!/usr/bin/env bash
# Run by Terraform before it deletes Argo CD (k8s/argocd.tf). Deleting the root
# app alone would remove every app at once, and an operator (KEDA, cert-manager)
# could go before the objects whose finalizers it handles, leaving namespaces
# stuck. So: stop the root app, then delete the apps wave by wave, newest first.
set -uo pipefail
: "${CLUSTER:?}" "${AWS_REGION:?}"

export KUBECONFIG; KUBECONFIG=$(mktemp)
trap 'rm -f "$KUBECONFIG"' EXIT
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG" >/dev/null || exit 0

if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then exit 0; fi
# Without this, the root app would re-create the apps as they are deleted.
kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null 2>&1

for wave in 4 3 2 1 0; do
  apps=$(kubectl -n argocd get applications -l "trades/wave=$wave" -o name 2>/dev/null)
  [ -z "$apps" ] && continue
  echo "deleting wave $wave: $(echo $apps | sed 's|application.argoproj.io/||g')"
  kubectl -n argocd delete $apps --wait=true --timeout=600s >/dev/null \
    || echo "  wave $wave did not finish deleting in 10 minutes" >&2
done
