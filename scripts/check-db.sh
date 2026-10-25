#!/usr/bin/env bash
# Data checks against RDS, run from a throwaway psql pod (the DB is only
# reachable from inside the VPC):
#   rows vs distinct (symbol, trade_id)  -> must be equal (no duplicates)
#   missing trade ids                    -> holes in each symbol's id sequence,
#                                           ignoring the last 30s (still settling)
#
# Logs in as the read-only "grafana" user. Its password is read inside the pod
# from the grafana-trades-db Secret (synced from Secrets Manager by External
# Secrets); it never reaches this machine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DB_HOST=$(terraform -chdir="$ROOT/infra" output -raw db_host)

SQL="
WITH gaps AS (
  SELECT trade_id - lag(trade_id) OVER (PARTITION BY symbol ORDER BY trade_id) - 1 AS gap
  FROM trades WHERE trade_time < now() - interval '30 seconds')
SELECT 'rows='     || (SELECT count(*) FROM trades),
       'distinct=' || (SELECT count(DISTINCT (symbol, trade_id)) FROM trades),
       'missing='  || coalesce((SELECT sum(gap) FROM gaps WHERE gap > 0), 0),
       'newest_trade_age_s=' || (SELECT round(extract(epoch FROM now() - max(trade_time))::numeric, 1) FROM trades);"

OVERRIDES=$(python3 - "$DB_HOST" "$SQL" <<'EOF'
import json, sys
host, sql = sys.argv[1], sys.argv[2]
print(json.dumps({"spec": {"containers": [{
    "name": "psql",
    "image": "postgres:17",
    "command": ["psql", "-h", host, "-U", "grafana", "-d", "trades", "-tA", "-F", " ", "-c", sql],
    "env": [
        {"name": "PGSSLMODE", "value": "require"},
        {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {"name": "grafana-trades-db", "key": "password"}}},
    ],
}]}}))
EOF
)

kubectl -n monitoring run "check-db-$RANDOM" --rm -i --restart=Never --quiet --image=postgres:17 \
  --overrides="$OVERRIDES" 2>&1 | grep -v -e '^pod ' -e "couldn't attach" -e '^$'
