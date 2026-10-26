"""One-command pipeline health, from inside the cluster:

    kubectl -n trades exec deploy/consumer -- python -m trades.healthcheck

UNHEALTHY when the freshness SLO is breached right now (p99 over the last 5
minutes above 2 s) or any pipeline alert is firing (the PrometheusRule in the
chart: nothing ingested, producers down, lag, DB unavailable...).
Exit 0 = HEALTHY, 1 = UNHEALTHY, 2 = UNKNOWN (no data or Prometheus unreachable):
silence is not reported as success.
"""

import json
import os
import sys
import urllib.parse
import urllib.request

SLO_SECONDS = 2.0  # p99, trade time -> stored in Postgres, over 5 minutes

PROMETHEUS = os.environ.get(
    "PROMETHEUS_URL", "http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
)


def query(expr: str) -> list:
    url = f"{PROMETHEUS}/api/v1/query?{urllib.parse.urlencode({'query': expr})}"
    with urllib.request.urlopen(url, timeout=5) as resp:
        return json.load(resp)["data"]["result"]


def main() -> int:
    try:
        alerts = [r["metric"] for r in query('ALERTS{pipeline="trades"}')]
        p99 = query("trades:ingest_latency_seconds:p99_5m")
    except OSError as exc:
        print(f"UNKNOWN    Prometheus unreachable at {PROMETHEUS}: {exc}")
        return 2

    firing = [a for a in alerts if a["alertstate"] == "firing"]
    # Alerts wait out their "for:" window before firing (that's about paging).
    # The SLO itself is judged on its own 5-minute p99, so no extra wait here.
    for alert in sorted(alerts, key=lambda a: a["alertstate"]):
        print(f"{alert['alertstate'].upper():10} {alert.get('severity', ''):8} {alert['alertname']}")
    latency = f"{float(p99[0]['value'][1]):.2f}s" if p99 else "no data"
    slo_breached = bool(p99) and float(p99[0]["value"][1]) > SLO_SECONDS
    if firing or slo_breached:
        status, code = "UNHEALTHY", 1
    elif not p99:
        status, code = "UNKNOWN", 2  # nothing stored recently, or rules not loaded yet
    else:
        status, code = "HEALTHY", 0
    print(f"{status:10} p99 ingest latency (5m) = {latency}, SLO = {SLO_SECONDS:g}s")
    return code


if __name__ == "__main__":
    sys.exit(main())
