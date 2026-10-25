#!/usr/bin/env bash
# Open the cluster's web UIs on localhost. Nothing is exposed publicly (no load
# balancer, no DNS), so this port-forwards each one through the Kubernetes API.
#
#   make ui ENV=<env>          (or: CLUSTER=<name> scripts/ui.sh [--open])
#
# - uses eks.kubeconfig (written by make kubeconfig), never ~/.kube/config
# - picks the next free port if one is taken
# - reconnects a forward that drops (e.g. its pod restarted)
# - Ctrl+C stops everything; nothing keeps running afterwards
# Needs: aws CLI v2, kubectl, credentials for the account.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${CLUSTER:-dan-berg-staging}"
GRAFANA_ADMIN_SECRET="${GRAFANA_ADMIN_SECRET:-$CLUSTER/grafana-admin}"
export AWS_REGION="${AWS_REGION:-ca-central-1}"
export KUBECONFIG="${KUBECONFIG:-$ROOT/eks.kubeconfig}"
OPEN=false; [ "${1:-}" = "--open" ] && OPEN=true

# name | namespace | service | preferred local port | service port | path to open
UIS="Grafana|monitoring|monitoring-grafana|3000|80|/d/trades-pipeline
Kafka UI|kafka|kafka-ui|8080|8080|/ui/clusters/eks/all-topics/trades
Prometheus|monitoring|monitoring-kube-prometheus-prometheus|9090|9090|/alerts
Alertmanager|monitoring|monitoring-kube-prometheus-alertmanager|9093|9093|/"

die() { echo "error: $*" >&2; exit 1; }
command -v aws >/dev/null || die "aws CLI not found"
command -v kubectl >/dev/null || die "kubectl not found"

if ! kubectl get ns monitoring >/dev/null 2>&1; then
  echo "Writing kubeconfig for cluster $CLUSTER to $KUBECONFIG"
  aws eks update-kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --alias "$CLUSTER" >/dev/null \
    || die "can't get cluster credentials (check AWS_PROFILE / region)"
  kubectl get ns monitoring >/dev/null 2>&1 \
    || die "cluster reachable but access denied: your IAM principal needs an EKS access entry (see README)"
fi

port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
free_port() {
  local p=$1
  while ! port_free "$p"; do p=$((p + 1)); done
  echo "$p"
}

LOGDIR="$(mktemp -d)"
PIDS=""
cleanup() {
  trap - INT TERM EXIT
  echo; echo "Stopping port-forwards..."
  exec 2>/dev/null                # bash reports each killed job ("Terminated"); not useful here
  for pid in $PIDS; do
    pkill -P "$pid" 2>/dev/null   # the kubectl inside the loop
    kill "$pid" 2>/dev/null
  done
  wait $PIDS 2>/dev/null          # reap them quietly (no "Terminated" job notices)
  rm -rf "$LOGDIR"
}
trap cleanup INT TERM EXIT

# Keep one forward alive: kubectl port-forward exits when its pod goes away.
forward() {
  local ns=$1 svc=$2 local_port=$3 remote_port=$4 log=$5
  while true; do
    kubectl -n "$ns" port-forward --address 127.0.0.1 "svc/$svc" "$local_port:$remote_port" >>"$log" 2>&1
    echo "$(date +%T) forward ended, reconnecting" >>"$log"
    sleep 2
  done
}

ROWS=""
while IFS='|' read -r name ns svc want remote path; do
  if ! kubectl -n "$ns" get svc "$svc" >/dev/null 2>&1; then
    ROWS="$ROWS$name|not deployed|\n"; continue
  fi
  port=$(free_port "$want")
  forward "$ns" "$svc" "$port" "$remote" "$LOGDIR/$svc.log" &
  PIDS="$PIDS $!"
  ROWS="$ROWS$name|http://localhost:$port$path|$port\n"
done <<EOF
$UIS
EOF

echo "Waiting for the UIs to answer..."
printf "$ROWS" | while IFS='|' read -r name url port; do
  [ -z "$port" ] && continue
  for _ in $(seq 1 30); do
    curl -s -o /dev/null -m 2 "http://127.0.0.1:$port/" && break
    sleep 1
  done
done

echo
printf "$ROWS" | while IFS='|' read -r name url port; do
  status="ok"
  [ -n "$port" ] && ! curl -s -o /dev/null -m 2 "http://127.0.0.1:$port/" && status="not answering yet"
  [ -z "$port" ] && status="-"
  printf "  %-13s %-58s %s\n" "$name" "$url" "$status"
  $OPEN && [ -n "$port" ] && command -v open >/dev/null && open "$url"
done
cat <<EOF

  Grafana: no login needed to view. Admin password, if you want to edit:
    aws secretsmanager get-secret-value --secret-id $GRAFANA_ADMIN_SECRET --query SecretString --output text

  Kafka UI is read-only. Ctrl+C stops everything.
EOF

wait
