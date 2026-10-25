#!/usr/bin/env bash
# Data checks against RDS, run from a throwaway psql pod (the DB is only
# reachable from inside the VPC):
#   rows vs distinct (symbol, trade_id)  -> must be equal (no duplicates)
#   missing trade ids                    -> holes in each symbol's id sequence,
#                                           ignoring the last 30s (still settling)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AWS_REGION="${AWS_REGION:-ca-central-1}"

DB_HOST=$(terraform -chdir="$ROOT/infra" output -raw db_host)
SECRET=$(terraform -chdir="$ROOT/infra" output -raw db_master_secret_arn)
PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET" --query SecretString --output text \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')

kubectl -n trades run "check-db-$RANDOM" --rm -i --restart=Never --quiet --image=postgres:17 \
  --env=PGPASSWORD="$PGPASSWORD" --env=PGSSLMODE=require -- \
  psql -h "$DB_HOST" -U trades_admin -d trades -tA -F ' ' -c "
WITH gaps AS (
  SELECT trade_id - lag(trade_id) OVER (PARTITION BY symbol ORDER BY trade_id) - 1 AS gap
  FROM trades WHERE trade_time < now() - interval '30 seconds')
SELECT 'rows='     || (SELECT count(*) FROM trades),
       'distinct=' || (SELECT count(DISTINCT (symbol, trade_id)) FROM trades),
       'missing='  || coalesce((SELECT sum(gap) FROM gaps WHERE gap > 0), 0),
       'newest_trade_age_s=' || (SELECT round(extract(epoch FROM now() - max(trade_time))::numeric, 1) FROM trades);" \
  2>&1 | grep -v -e '^pod ' -e "couldn't attach" -e '^$'
