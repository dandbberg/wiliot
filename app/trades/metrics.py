"""Prometheus metrics, served at /metrics by the health server.

Names are prefixed trades_ so dashboards and alert rules can select them cleanly.
"""

import json

from prometheus_client import Counter, Gauge, Histogram

# --- producer ---------------------------------------------------------------
WS_CONNECTED = Gauge("trades_ws_connected", "1 while the Binance WebSocket is connected")
WS_RECONNECTS = Counter("trades_ws_reconnects_total", "WebSocket reconnects (drops, timeouts, 24h rotation)")
WS_TRADES = Counter("trades_ws_trades_total", "Trade events received from Binance", ["symbol"])
WS_LAST_MESSAGE = Gauge("trades_ws_last_message_timestamp_seconds", "Unix time of the last WebSocket message")
KAFKA_DELIVERED = Counter("trades_kafka_delivered_total", "Messages acknowledged by Kafka")
KAFKA_DELIVERY_FAILED = Counter("trades_kafka_delivery_failed_total", "Messages Kafka failed to accept")
KAFKA_QUEUE = Gauge("trades_kafka_producer_queue_messages", "Messages waiting in the local producer queue")
KAFKA_PENDING = Gauge("trades_kafka_retry_pending", "Trades Kafka refused, held for retry")
KAFKA_DROPPED = Counter("trades_kafka_dropped_total", "Trades dropped because the retry queue was full")

# --- consumer ---------------------------------------------------------------
CONSUMED = Counter("trades_consumed_total", "Kafka messages consumed")
INSERTED = Counter("trades_inserted_total", "Trades newly written to Postgres", ["symbol"])
DUPLICATES = Counter("trades_duplicates_total", "Consumed messages that were already stored (or duplicated in-batch)")
MALFORMED = Counter("trades_malformed_total", "Messages skipped because they could not be parsed")
DB_RETRIES = Counter("trades_db_retries_total", "Insert attempts that failed because Postgres was unavailable")
# The freshness SLO: p99 of this must stay under 2s. Buckets cluster around it.
INGEST_LATENCY = Histogram(
    "trades_ingest_latency_seconds",
    "Trade time (Binance) to committed in Postgres",
    # Fine above the SLO too, so the p99 reported during an incident is close to
    # the real one (a 60 -> 300 s jump once overstated 122 s as 282 s).
    buckets=(0.05, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600),
)
DB_INSERT_SECONDS = Histogram(
    "trades_db_insert_seconds",
    "Duration of one batch insert transaction",
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5),
)
BATCH_SIZE = Histogram("trades_batch_trades", "Trades per insert batch", buckets=(1, 5, 10, 25, 50, 100, 250, 500))
CONSUMER_LAG = Gauge("trades_kafka_consumer_lag", "Messages behind the partition high watermark", ["partition"])
PARTITION_HIGH_WATERMARK = Gauge(
    "trades_kafka_partition_high_watermark", "Latest offset of each assigned partition", ["partition"]
)


def record_consumer_stats(stats_json: str) -> None:
    """librdkafka statistics callback: export lag for the partitions this consumer owns.

    Lag comes from the client rather than a separate kafka-exporter so it works
    unchanged against MSK with IAM auth.
    """
    stats = json.loads(stats_json)
    # Reset first so partitions moved to another consumer stop being reported here.
    CONSUMER_LAG.clear()
    PARTITION_HIGH_WATERMARK.clear()
    for topic in stats.get("topics", {}).values():
        for pid, part in topic.get("partitions", {}).items():
            if pid == "-1" or part.get("fetch_state") in (None, "none", "stopped"):
                continue
            if part.get("consumer_lag", -1) >= 0:
                CONSUMER_LAG.labels(partition=pid).set(part["consumer_lag"])
            if part.get("hi_offset", -1) >= 0:
                PARTITION_HIGH_WATERMARK.labels(partition=pid).set(part["hi_offset"])
