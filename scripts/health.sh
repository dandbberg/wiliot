#!/usr/bin/env bash
# One-command pipeline health: HEALTHY / UNHEALTHY / UNKNOWN (exit 0 / 1 / 2).
# Runs the app image's healthcheck in its own short-lived pod rather than
# inside a consumer, so it still works when the consumers are what's down.
set -uo pipefail

IMAGE=$(kubectl -n trades get deploy/producer -o jsonpath='{.spec.template.spec.containers[0].image}') || exit 2
POD="healthcheck-$RANDOM"

kubectl -n trades run "$POD" --restart=Never --image="$IMAGE" --command -- python -m trades.healthcheck >/dev/null || exit 2
kubectl -n trades wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD" --timeout=60s >/dev/null 2>&1 \
  || kubectl -n trades wait --for=jsonpath='{.status.phase}'=Failed "pod/$POD" --timeout=5s >/dev/null 2>&1
kubectl -n trades logs "$POD"
code=$(kubectl -n trades get pod "$POD" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')
kubectl -n trades delete pod "$POD" --wait=false >/dev/null
exit "${code:-2}"
