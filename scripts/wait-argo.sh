#!/usr/bin/env bash
# Wait until Argo CD has deployed everything: every Application synced and
# healthy. Prints progress; gives up after 25 minutes with the apps that aren't.
set -uo pipefail
deadline=$(( $(date +%s) + 1500 ))
last=""
while :; do
  status=$(kubectl -n argocd get applications --no-headers \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null)
  total=$(echo "$status" | grep -c . ); ready=$(echo "$status" | awk '$2=="Synced" && $3=="Healthy"' | grep -c .)
  line="argo: $ready/$total apps synced and healthy"
  [ "$line" != "$last" ] && { echo "$(date +%H:%M:%S) $line"; last=$line; }
  # root + 10 apps
  [ "$total" -ge 11 ] && [ "$ready" = "$total" ] && exit 0
  if [ "$(date +%s)" -gt "$deadline" ]; then
    echo "not ready after 25 minutes:" >&2
    echo "$status" | awk '!($2=="Synced" && $3=="Healthy")' >&2
    exit 1
  fi
  sleep 15
done
