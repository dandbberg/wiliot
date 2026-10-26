#!/usr/bin/env bash
# Stress tests against the running pipeline. Each test breaks something while
# trades keep flowing, then checks the database: no duplicates, no new holes in
# the trade-id sequences, and how late the rows stored meanwhile were.
#
#   scripts/chaos.sh <test>...    (make chaos-<test>, or make chaos for all)
#
#   consumer   force-kill one consumer mid-batch
#   producer   force-kill one producer (its WebSocket drops; the others cover)
#   broker     force-kill one Kafka broker (2 of 3 replicas stay in sync)
#   drain      drain the node running broker-0 (and whatever else is there)
#   outbox     revoke the producers' Kafka write ACL for 2 minutes
#   replay     rewind the consumer group to offset 0 and reprocess everything
#   keda       slow the consumers, replay the last 10 min, watch KEDA scale 3 -> 12 -> 3
#   security   four connections to Kafka that must all be refused
#
# Exits 1 if any test lost or duplicated data. Needs kubectl on the cluster.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAILED=0
ts()    { date -u +%H:%M:%SZ; }
now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
pause() { local t=$(( $(date +%s) + $1 )); until [ "$(date +%s)" -ge $t ]; do sleep 2; done; }
say()   { echo "$@"; }
run()   { say "\$ $*   # $(ts)"; "$@" >/dev/null 2>&1; }

db()   { ./scripts/check-db.sh; }
sql()  { CHECK_DB_SQL="$1" ./scripts/check-db.sh; }
field() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

# Worst and p99 latency (trade time -> stored) of rows stored between two times.
latency() {
  sql "SELECT count(*) || ' rows stored, p99 ' ||
         coalesce(round((percentile_cont(0.99) WITHIN GROUP (ORDER BY extract(epoch FROM ingested_at - trade_time)))::numeric, 1), 0) ||
         ' s, worst ' || coalesce(round(max(extract(epoch FROM ingested_at - trade_time))::numeric, 1), 0) || ' s'
       FROM trades WHERE ingested_at BETWEEN '$1' AND '$2'"
}

# Kafka admin commands run as the broker's principal (the only super user).
kafka() {
  local tool=$1; shift
  kubectl -n kafka exec broker-0 -- bash -c '
    cat /etc/kafka/tls-src/tls.key /etc/kafka/tls-src/tls.crt > /tmp/admin.pem
    printf "security.protocol=SSL\nssl.keystore.type=PEM\nssl.keystore.location=/tmp/admin.pem\nssl.truststore.type=PEM\nssl.truststore.location=/etc/kafka/tls-src/ca.crt\n" > /tmp/admin.properties
    /opt/kafka/bin/'"$tool"' --bootstrap-server kafka.kafka.svc.cluster.local:9092 --command-config /tmp/admin.properties '"$*"' 2>/dev/null'
}
group() { kafka kafka-consumer-groups.sh --group trades-consumer "$@"; }
lag()   { group --describe | awk '$2=="trades" && $6 ~ /^[0-9]+$/ {s+=$6} END {print s+0}'; }
# Argo CD would undo a manual change within minutes (self-heal). The root app
# owns the pipeline app, so both are paused.
argo_pause()  { for a in root pipeline; do kubectl -n argocd patch application $a --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null; done; }
argo_resume() { for a in pipeline root; do kubectl -n argocd patch application $a --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null; done; }
consumers() { kubectl -n trades get deploy consumer -o jsonpath='{.status.readyReplicas}/{.spec.replicas}'; }

# Before/after bookkeeping shared by every test.
begin() {
  say; say "### $1"
  BEFORE=$(db); T0=$(now)
  say "before: $BEFORE"
}
finish() {
  pause 45 # rows of the last 30 s don't count as holes yet
  local after; after=$(db)
  say "during: $(latency "$T0" "$(now)")"
  say "after:  $after"
  local rows distinct missing0 missing1
  rows=$(field "$after" rows); distinct=$(field "$after" distinct)
  missing0=$(field "$BEFORE" missing); missing1=$(field "$after" missing)
  if [ -z "$rows" ] || [ -z "$missing0" ]; then
    say "ERROR could not read the database, so this test is not judged"
    FAILED=1
    return
  fi
  # A hole can be a trade that's only late: after a restart or a backlog some
  # partitions are still behind. Lost means still missing after 10 minutes,
  # the same rule as the dashboard's gaps panel.
  local late=$(( missing1 - missing0 )) waited=0
  while [ "$missing1" -gt "$missing0" ] && [ $waited -lt 600 ]; do
    [ $waited -eq 0 ] && say "  $late trades not stored yet; checking again every 30 s for up to 10 minutes"
    pause 30; waited=$(( waited + 30 ))
    after=$(db); m=$(field "$after" missing); [ -n "$m" ] && missing1=$m
  done
  rows=$(field "$after" rows); distinct=$(field "$after" distinct)
  if [ "$rows" != "$distinct" ]; then
    say "FAIL  duplicates=$(( rows - distinct ))"
    FAILED=1
  elif [ "$missing1" -gt "$missing0" ]; then
    say "FAIL  $(( missing1 - missing0 )) trades still missing after 10 minutes"
    FAILED=1
  elif [ $waited -gt 0 ]; then
    say "PASS  no duplicates; $late trades arrived late, all stored within $(( waited / 60 ))m $(( waited % 60 ))s"
  else
    say "PASS  no duplicates, no new missing trades"
  fi
}

t_consumer() {
  begin "consumer force-killed mid-batch"
  local p; p=$(kubectl -n trades get pod -l app.kubernetes.io/name=consumer -o name | head -1)
  run kubectl -n trades delete "$p" --grace-period=0 --force
  kubectl -n trades rollout status deploy/consumer --timeout=180s >/dev/null
  finish
}

t_producer() {
  begin "producer force-killed"
  local p; p=$(kubectl -n trades get pod -l app.kubernetes.io/name=producer -o name | head -1)
  run kubectl -n trades delete "$p" --grace-period=0 --force
  kubectl -n trades rollout status deploy/producer --timeout=180s >/dev/null
  finish
}

t_broker() {
  begin "Kafka broker force-killed (RF 3, min.insync.replicas 2)"
  run kubectl -n kafka delete pod broker-1 --grace-period=0 --force
  kubectl -n kafka wait --for=condition=Ready pod/broker-1 --timeout=300s >/dev/null
  say "broker-1 ready again at $(ts)"
  finish
}

t_drain() {
  begin "node drain (broker-0's node)"
  local n; n=$(kubectl -n kafka get pod broker-0 -o jsonpath='{.spec.nodeName}')
  say "on $n: $(kubectl get pods -A --field-selector spec.nodeName="$n" --no-headers | awk '$1 ~ /trades|kafka/ {printf "%s ", $2}')"
  run kubectl drain "$n" --ignore-daemonsets --delete-emptydir-data --timeout=600s
  kubectl -n kafka wait --for=condition=Ready pod/broker-0 --timeout=300s >/dev/null
  say "broker-0 ready again at $(ts) on $(kubectl -n kafka get pod broker-0 -o jsonpath='{.spec.nodeName}')"
  run kubectl uncordon "$n"
  finish
}

t_outbox() {
  begin "producers lose Kafka write permission for 2 minutes"
  local acl="--topic trades --operation Write --operation Describe --allow-principal User:producer"
  say "\$ kafka-acls.sh --remove $acl   # $(ts)"
  kafka kafka-acls.sh --remove --force $acl >/dev/null
  pause 120
  say "producer restarts while blocked: $(kubectl -n trades get pod -l app.kubernetes.io/name=producer -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}') (trades wait in the outbox)"
  say "\$ kafka-acls.sh --add $acl   # $(ts)"
  kafka kafka-acls.sh --add --force $acl >/dev/null
  finish
}

t_replay() {
  begin "full replay: consumer group rewound to offset 0"
  run kubectl -n trades annotate scaledobject consumer autoscaling.keda.sh/paused-replicas=0 --overwrite
  kubectl -n trades wait --for=delete pod -l app.kubernetes.io/name=consumer --timeout=180s >/dev/null 2>&1
  say "\$ kafka-consumer-groups.sh --reset-offsets --to-earliest --topic trades --execute   # $(ts)"
  group --topic trades --reset-offsets --to-earliest --execute >/dev/null
  say "messages to reprocess: $(lag)"
  run kubectl -n trades annotate scaledobject consumer autoscaling.keda.sh/paused-replicas-
  local start; start=$(date +%s)
  until [ "$(lag)" -lt 1000 ]; do sleep 10; done
  say "caught up in $(( $(date +%s) - start )) s"
  finish
}

t_keda() {
  begin "KEDA scale-out on Kafka lag"
  say "(Argo CD auto-sync paused for the test)"; argo_pause
  run kubectl -n trades annotate scaledobject consumer autoscaling.keda.sh/paused-replicas=0 --overwrite
  kubectl -n trades wait --for=delete pod -l app.kubernetes.io/name=consumer --timeout=180s >/dev/null 2>&1
  # One insert and one offset commit per message, so the backlog lasts long enough to watch.
  run kubectl -n trades set env deploy/consumer BATCH_SIZE=1
  # The last 10 minutes only: the whole topic grows with every run, and live
  # trades wait behind whatever is replayed.
  group --topic trades --reset-offsets --by-duration PT10M --execute >/dev/null
  say "backlog: $(lag) messages"
  run kubectl -n trades annotate scaledobject consumer autoscaling.keda.sh/paused-replicas-
  local start; start=$(date +%s)
  while :; do
    local l; l=$(lag)
    say "  +$(( $(date +%s) - start ))s  consumers ready/desired=$(consumers)  lag=$l"
    [ "$l" -lt 1000 ] && break
    [ $(( $(date +%s) - start )) -gt 1500 ] && { say "  still behind after 25 min"; break; }
    pause 15
  done
  say "caught up; scale-down after the 120 s stabilisation window:"
  for _ in $(seq 1 20); do
    local r; r=$(consumers); say "  $(ts) consumers=$r"
    [ "$r" = "3/3" ] && break; pause 20
  done
  say "(Argo CD auto-sync back on: it restores BATCH_SIZE)"; argo_resume
  # Wait for Argo to really restore it, for the restart, and for the consumers
  # to catch up: measuring during the restart counted late trades as missing.
  local deadline=$(( $(date +%s) + 300 ))
  until [ "$(kubectl -n trades get deploy consumer -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BATCH_SIZE")].value}')" != "1" ] \
        || [ "$(date +%s)" -gt $deadline ]; do sleep 5; done
  kubectl -n trades rollout status deploy/consumer --timeout=300s >/dev/null
  until [ "$(lag)" -lt 1000 ] || [ "$(date +%s)" -gt $deadline ]; do sleep 10; done
  say "consumers back to BATCH_SIZE=$(kubectl -n trades get deploy consumer -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BATCH_SIZE")].value}'), lag $(lag)"
  finish
}

t_security() {
  say; say "### security: who can reach Kafka (all four must be refused)"
  local img; img=$(kubectl -n trades get deploy/producer -o jsonpath='{.spec.template.spec.containers[0].image}')
  for ns in trades default; do
    kubectl -n $ns create configmap kafka-negative --from-file=neg.py=scripts/kafka-negative.py --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  attempt() { # namespace mode extra-volumes extra-mounts
    kubectl -n "$1" run "neg-$RANDOM" --rm -i --restart=Never --quiet --image="$img" --overrides="{\"spec\":{\"containers\":[{\"name\":\"t\",\"image\":\"$img\",\"command\":[\"python\",\"/t/neg.py\",\"$2\"],\"volumeMounts\":[{\"name\":\"t\",\"mountPath\":\"/t\"}$4]}],\"volumes\":[{\"name\":\"t\",\"configMap\":{\"name\":\"kafka-negative\"}}$3]}}" 2>&1 \
      | grep RESULT | head -1 | sed 's/^RESULT: /  /'
  }
  local out
  say "a) pod in namespace 'default' (NetworkPolicy):"; out=$(attempt default tcp "" ""); say "$out"
  echo "$out" | grep -q "NOT" && FAILED=1
  say "b) pod in 'trades', plaintext client:"; out=$(attempt trades plaintext "" ""); say "$out"
  echo "$out" | grep -q "NOT" && FAILED=1
  say "c) pod in 'trades', TLS without a client certificate:"
  out=$(attempt trades no-cert ',{"name":"ca","secret":{"secretName":"kafka-client-producer","items":[{"key":"ca.crt","path":"ca.crt"}]}}' ',{"name":"ca","mountPath":"/ca"}'); say "$out"
  echo "$out" | grep -q "NOT" && FAILED=1
  say "d) the producer's certificate trying to read:"
  out=$(attempt trades producer-reads ',{"name":"c","secret":{"secretName":"kafka-client-producer"}}' ',{"name":"c","mountPath":"/c"}'); say "$out"
  echo "$out" | grep -q "NOT" && FAILED=1
  for ns in trades default; do kubectl -n $ns delete configmap kafka-negative >/dev/null; done
}

ALL="consumer producer broker drain outbox replay keda security"
[ $# -eq 0 ] && { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ "$1" = "all" ] && set -- $ALL
for t in "$@"; do
  case " $ALL " in *" $t "*) ;; *) echo "unknown test: $t (one of: $ALL)" >&2; exit 2;; esac
done

say "# chaos: $* - $(date -u '+%Y-%m-%d %H:%M UTC')"
for t in "$@"; do "t_$t"; done

say; say "\$ make health   # $(ts)"
./scripts/health.sh
exit $FAILED
