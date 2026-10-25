"""Generates the Grafana dashboard JSON for the pipeline chart.

    python3 generate.py <out-dir>

Writes two variants:
  trades-pipeline.json         everything, incl. SQL panels (Grafana Postgres
                               data source) and postgres_exporter panels: minikube
  trades-pipeline-iam.json     without them, for AWS where the database accepts
                               IAM logins only and Grafana has no DB password
"""
import json
import sys

PROM = {"type": "prometheus", "uid": "prometheus"}
PG = {"type": "grafana-postgresql-datasource", "uid": "trades-db"}
panels = []
_id = [0]
y = [0]


def nid():
    _id[0] += 1
    return _id[0]


def row(title):
    panels.append({"type": "row", "title": title, "id": nid(), "collapsed": False,
                   "gridPos": {"x": 0, "y": y[0], "w": 24, "h": 1}, "panels": []})
    y[0] += 1


def prom(expr, legend="", instant=False):
    t = {"datasource": PROM, "expr": expr, "legendFormat": legend, "refId": chr(65 + len(_targets))}
    if instant:
        t.update(instant=True, range=False, format="table")
    _targets.append(t)
    return t


_targets = []


def targets(*exprs):
    global _targets
    _targets = []
    out = []
    for e in exprs:
        out.append(prom(*e) if isinstance(e, tuple) else prom(e))
    return out


def thresholds(*steps):
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in steps]}


def stat(title, expr, x, w, unit="none", steps=((None, "green"),), desc="", decimals=None):
    p = {"type": "stat", "title": title, "id": nid(), "description": desc, "datasource": PROM,
         "gridPos": {"x": x, "y": y[0], "w": w, "h": 4}, "targets": targets(expr),
         "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "graphMode": "area",
                     "textMode": "value"},
         "fieldConfig": {"defaults": {"unit": unit, "thresholds": thresholds(*steps)}, "overrides": []}}
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    panels.append(p)


def ts(title, exprs, x, w, h=8, unit="none", desc="", threshold=None, stack=False, overrides=()):
    defaults = {"unit": unit, "custom": {"fillOpacity": 10, "lineWidth": 1, "showPoints": "never"}}
    if stack:
        defaults["custom"]["stacking"] = {"mode": "normal"}
        defaults["custom"]["fillOpacity"] = 40
    if threshold is not None:
        defaults["thresholds"] = thresholds((None, "transparent"), (threshold, "red"))
        defaults["custom"]["thresholdsStyle"] = {"mode": "line+area"}
    panels.append({"type": "timeseries", "title": title, "id": nid(), "description": desc, "datasource": PROM,
                   "gridPos": {"x": x, "y": y[0], "w": w, "h": h}, "targets": targets(*exprs),
                   "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "max"]},
                               "tooltip": {"mode": "multi", "sort": "desc"}},
                   "fieldConfig": {"defaults": defaults, "overrides": list(overrides)}})


def sql_table(title, sql, x, w, h=8, desc="", overrides=()):
    panels.append({"type": "table", "title": title, "id": nid(), "description": desc, "datasource": PG,
                   "gridPos": {"x": x, "y": y[0], "w": w, "h": h},
                   "targets": [{"datasource": PG, "refId": "A", "format": "table", "rawQuery": True,
                                "editorMode": "code", "rawSql": sql}],
                   "fieldConfig": {"defaults": {}, "overrides": list(overrides)}, "options": {"showHeader": True}})


# ---------------------------------------------------------------- SLO
row("Freshness SLO — p99 trade time → stored in Postgres < 2s")
stat("p99 ingest latency (5m)", "trades:ingest_latency_seconds:p99_5m", 0, 5, "s",
     ((None, "green"), (1, "orange"), (2, "red")), "The SLO metric. Red means the 2s target is breached.", 2)
stat("Trades stored / s", "sum(rate(trades_inserted_total[1m]))", 5, 5, "reqps", ((None, "red"), (0.001, "green")), decimals=1)
stat("Producers connected", "sum(trades_ws_connected) or vector(0)", 10, 5, "none",
     ((None, "red"), (1, "orange"), (2, "yellow"), (3, "green")),
     "3 = all connected. 2 = still redundant. 1 = a reconnect now would lose trades. 0 = losing trades.")
stat("Consumers running", 'sum(kube_deployment_status_replicas_available{namespace="trades",deployment="consumer"}) or vector(0)',
     15, 5, "none", ((None, "red"), (1, "orange"), (3, "green")),
     "KEDA scales the consumers between 3 and 12 on Kafka lag. Above 3 = working off a backlog.")
stat("Pipeline alerts firing", 'count(ALERTS{pipeline="trades",alertstate="firing"}) or vector(0)', 20, 4, "none",
     ((None, "green"), (1, "red")), "Alerts from the trades-pipeline PrometheusRule.")
y[0] += 4
ts("Ingest latency", [
    ('histogram_quantile(0.50, sum by (le) (rate(trades_ingest_latency_seconds_bucket[1m])))', "p50"),
    ('histogram_quantile(0.90, sum by (le) (rate(trades_ingest_latency_seconds_bucket[1m])))', "p90"),
    ('histogram_quantile(0.99, sum by (le) (rate(trades_ingest_latency_seconds_bucket[1m])))', "p99"),
], 0, 16, unit="s", threshold=2, desc="Binance trade time to committed row. Red band = above the 2s SLO.")
panels.append({"type": "table", "title": "Firing / pending alerts", "id": nid(), "datasource": PROM,
               "gridPos": {"x": 16, "y": y[0], "w": 8, "h": 8},
               "targets": targets(('ALERTS{pipeline="trades"}', "", True)),
               "transformations": [{"id": "organize", "options": {
                   "excludeByName": {"Time": True, "Value": True, "__name__": True, "pipeline": True},
                   "indexByName": {"alertname": 0, "alertstate": 1, "severity": 2}}}],
               "options": {"showHeader": True}, "fieldConfig": {"defaults": {"noValue": "No alerts"}, "overrides": []}})
y[0] += 8

# ---------------------------------------------------------------- Producer
row("Producer — Binance WebSocket → Kafka")
ts("Trades received / s by symbol (Binance)", [('max by (symbol) (rate(trades_ws_trades_total[1m]))', "{{symbol}}")],
   0, 12, unit="reqps", stack=True, desc="Max across producers: each replica receives every trade.")
ts("WebSocket connected by producer", [("trades_ws_connected", "{{pod}}")], 12, 6, desc="1 = connected.")
ts("Reconnects & Kafka delivery failures", [
    ("sum by (pod) (increase(trades_ws_reconnects_total[5m]))", "reconnects {{pod}}"),
    ("sum by (pod) (increase(trades_kafka_delivery_failed_total[5m]))", "delivery failed {{pod}}"),
], 18, 6, desc="Per 5 minutes.")
y[0] += 8

# ---------------------------------------------------------------- Kafka
row("Kafka — topic trades, group trades-consumer")
ts("Consumer lag by partition", [("sum by (partition) (trades_kafka_consumer_lag)", "p{{partition}}")], 0, 8,
   stack=True, desc="Messages not yet consumed. From librdkafka statistics in the consumer.")
ts("Messages produced / s by partition", [
    ("sum by (partition) (rate(trades_kafka_partition_high_watermark[1m]))", "p{{partition}}")], 8, 8,
   unit="reqps", stack=True, desc="Even bands = the symbol:trade_id key spreads load across partitions.")
ts("Consumed vs stored", [
    ("sum(rate(trades_consumed_total[1m]))", "consumed"),
    ("sum(rate(trades_inserted_total[1m]))", "stored (new)"),
    ("sum(rate(trades_duplicates_total[1m]))", "duplicates dropped"),
    ("sum(rate(trades_malformed_total[1m]))", "malformed"),
], 16, 8, unit="reqps", desc="consumed ≈ 3 × stored: each of the 3 producers delivers every trade, the primary key keeps one.")
y[0] += 8
HPA = 'horizontalpodautoscaler="keda-hpa-consumer"'
dashed = {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}}
ts("Pods: ready vs desired", [
    ('kube_deployment_status_replicas_available{namespace="trades",deployment="consumer"}', "consumers ready"),
    (f'kube_horizontalpodautoscaler_status_desired_replicas{{{HPA}}}', "consumers desired (KEDA)"),
    ('kube_deployment_status_replicas_available{namespace="trades",deployment="producer"}', "producers ready"),
    (f'kube_horizontalpodautoscaler_spec_min_replicas{{{HPA}}}', "min"),
    (f'kube_horizontalpodautoscaler_spec_max_replicas{{{HPA}}}', "max"),
], 0, 24, h=7, desc="KEDA sets 'desired' from the consumer lag above; 'ready' follows once the new pods start. "
                    "It scales down again 120 s after the lag is gone.",
   overrides=[{"matcher": {"id": "byName", "options": n}, "properties": [dashed, {"id": "color", "value": {"mode": "fixed", "fixedColor": "gray"}}]}
              for n in ("min", "max")])
y[0] += 7

# ---------------------------------------------------------------- Postgres
row("PostgreSQL")
sql_table("Latest trades", """
-- Cast to text so Grafana shows the stored values exactly instead of rounding them.
SELECT trade_id::text AS trade_id, symbol,
       price::text AS price, quantity::text AS quantity, notional::text AS notional,
       to_char(trade_time AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') || ' UTC' AS trade_time
FROM trades
ORDER BY trades.trade_time DESC  -- the column, not the text alias, so the index is used
LIMIT 50""".strip(), 0, 24, h=10,
          desc="The trades table (assignment step 2), newest first, values exactly as stored. notional = price x quantity, computed by Postgres (generated column).",
          overrides=[{"matcher": {"id": "byName", "options": c}, "properties": [{"id": "custom.width", "value": w}]}
                     for c, w in (("trade_id", 120), ("symbol", 100), ("price", 150), ("quantity", 130))])
y[0] += 10
ts("Insert transaction duration", [
    ("histogram_quantile(0.50, sum by (le) (rate(trades_db_insert_seconds_bucket[1m])))", "p50"),
    ("histogram_quantile(0.99, sum by (le) (rate(trades_db_insert_seconds_bucket[1m])))", "p99"),
], 0, 8, unit="s")
ts("Database activity", [
    ('sum(rate(pg_stat_database_tup_inserted{datname="trades"}[1m]))', "rows inserted/s"),
    ('sum(rate(pg_stat_database_xact_commit{datname="trades"}[1m]))', "commits/s"),
    ('sum(pg_stat_database_numbackends{datname="trades"})', "connections"),
], 8, 8, desc="From postgres_exporter.")
ts("Insert retries (DB unavailable)", [("sum by (pod) (increase(trades_db_retries_total[5m]))", "{{pod}}")], 16, 8,
   desc="Non-zero = consumers are blocked retrying; lag grows, nothing is skipped.")
y[0] += 8
sql_table("Per symbol (from Postgres)", """
SELECT symbol,
       count(*) FILTER (WHERE ingested_at > now() - interval '5 minutes') AS "stored 5m",
       round(extract(epoch FROM now() - max(trade_time))::numeric, 1)   AS "last trade age s",
       round((percentile_cont(0.99) WITHIN GROUP (ORDER BY extract(epoch FROM ingested_at - trade_time))
              FILTER (WHERE ingested_at > now() - interval '5 minutes') * 1000)::numeric) AS "p99 ms 5m"
FROM trades
WHERE trade_time > now() - interval '1 hour'
GROUP BY symbol ORDER BY symbol""".strip(), 0, 12,
          desc="Straight from the table: what a user of the data sees. Quiet symbols can legitimately be seconds old.")
sql_table("Gaps in trade ids, last 24h (missing trades)", """
WITH ordered AS (
  SELECT symbol, trade_id, trade_time,
         lag(trade_id)   OVER w AS prev_id,
         lag(trade_time) OVER w AS prev_time
  FROM trades WHERE trade_time > now() - interval '24 hours'
                 -- skip the live edge: ids land out of order across partitions for a moment
                 AND trade_time < now() - interval '30 seconds'
  WINDOW w AS (PARTITION BY symbol ORDER BY trade_id))
SELECT date_trunc('second', min(prev_time)) AS "gap from",
       date_trunc('second', max(trade_time)) AS "gap to",
       count(DISTINCT symbol)                AS symbols,
       sum(trade_id - prev_id - 1)           AS "missing trades"
FROM ordered WHERE trade_id - prev_id > 1
GROUP BY date_trunc('minute', prev_time) ORDER BY 1 DESC""".strip(), 12, 12,
          desc="Binance trade ids are sequential per symbol, so a hole is a trade we never stored. Trades newer than 30s are excluded: across 12 partitions ids briefly land out of order. Empty = complete.")
y[0] += 8

# ---------------------------------------------------------------- Kubernetes
row("Kubernetes — namespace trades")
ts("Container restarts (1h)", [
    ('sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="trades"}[1h]))', "{{pod}}")], 0, 8)
ts("CPU", [('sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="trades",container!=""}[2m]))', "{{pod}}")],
   8, 8, unit="cores")
ts("Memory (working set)", [
    ('sum by (pod) (container_memory_working_set_bytes{namespace="trades",container!=""})', "{{pod}}")], 16, 8, unit="bytes")
y[0] += 8

dashboard = {
    "uid": "trades-pipeline",
    "title": "Trades pipeline",
    "tags": ["trades"],
    "timezone": "browser",
    "refresh": "10s",
    "time": {"from": "now-30m", "to": "now"},
    "schemaVersion": 39,
    "editable": True,
    "panels": panels,
}


def needs_db_password(panel):
    if panel.get("datasource", {}).get("uid") == PG["uid"]:
        return True  # SQL panel via Grafana's Postgres data source
    return any("pg_stat" in t.get("expr", "") for t in panel.get("targets", []))  # postgres_exporter


out = sys.argv[1]
variants = {
    "trades-pipeline.json": panels,
    "trades-pipeline-iam.json": [p for p in panels if not needs_db_password(p)],
}
for name, selected in variants.items():
    json.dump({**dashboard, "panels": selected}, open(f"{out}/{name}", "w"), indent=2)
    print(f"{len(selected)} panels -> {out}/{name}")
