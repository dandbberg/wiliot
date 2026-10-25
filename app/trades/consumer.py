"""Kafka -> PostgreSQL, effectively exactly once.

Delivery is at-least-once: a batch is committed to Postgres first and only then
are its Kafka offsets committed. A crash between the two replays the batch, and
the replay is a no-op because of the (symbol, trade_id) primary key.
"""

import signal
import time
from datetime import datetime, timezone

import psycopg
from confluent_kafka import Consumer, KafkaError, KafkaException

from . import config, db, health, kafka, log, metrics
from .model import Trade, parse_trade

BATCH_SIZE = config.env_int("BATCH_SIZE", 500)
# consume() waits this long to fill a batch, so it bounds added latency at low volume.
POLL_TIMEOUT_S = float(config.env("POLL_TIMEOUT_S", "0.25"))
REPORT_EVERY_S = 15

INSERT_SQL = """
INSERT INTO trades (symbol, trade_id, price, quantity, trade_time)
SELECT * FROM unnest(%s::text[], %s::bigint[], %s::numeric[], %s::numeric[], %s::timestamptz[])
ON CONFLICT (symbol, trade_id) DO NOTHING
RETURNING symbol, trade_time
"""

logger = log.setup("consumer")


class Stopping(Exception):
    pass


class Window:
    """Per-interval counters and end-to-end latency (trade_time -> committed in DB)."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.started = time.monotonic()
        self.consumed = self.inserted = self.malformed = 0
        self.latencies_ms: list[float] = []

    def observe(self, latencies_s: list[float]):
        self.inserted += len(latencies_s)
        self.latencies_ms.extend(s * 1000 for s in latencies_s)

    def summary(self) -> dict:
        lat = sorted(self.latencies_ms)

        def pct(p):
            return round(lat[min(len(lat) - 1, int(p * len(lat)))]) if lat else None

        return {
            "consumed": self.consumed,
            "inserted": self.inserted,
            # Includes copies collapsed within a batch, not just primary-key conflicts.
            "duplicates": self.consumed - self.malformed - self.inserted,
            "malformed": self.malformed,
            "latency_p50_ms": pct(0.50),
            "latency_p99_ms": pct(0.99),
            "latency_max_ms": round(lat[-1]) if lat else None,
        }


class Store:
    """Owns the DB connection and reconnects on failure."""

    def __init__(self):
        self.conn: psycopg.Connection | None = None

    def _connection(self) -> psycopg.Connection:
        if self.conn is None or self.conn.closed:
            self.conn = db.connect()
        return self.conn

    def insert(self, trades: list[Trade]) -> list[tuple[str, datetime]]:
        """Returns (symbol, trade_time) of the rows that were new; duplicates aren't returned."""
        conn = self._connection()
        with metrics.DB_INSERT_SECONDS.time(), conn.transaction(), conn.cursor() as cur:
            cur.execute(
                INSERT_SQL,
                (
                    [t.symbol for t in trades],
                    [t.trade_id for t in trades],
                    [t.price for t in trades],
                    [t.quantity for t in trades],
                    [t.trade_time for t in trades],
                ),
            )
            return cur.fetchall()

    def insert_until_done(self, trades: list[Trade], should_stop) -> list[tuple[str, datetime]]:
        """Retry forever: skipping a batch would lose trades, so we block instead.

        Offsets aren't committed while we wait, so lag grows and alarms fire.
        """
        delay = 0.5
        while True:
            try:
                return self.insert(trades)
            except psycopg.OperationalError as exc:
                metrics.DB_RETRIES.inc()
                logger.warning("database unavailable, retrying", extra=log.fields(error=str(exc), retry_in_s=delay))
                if self.conn is not None:
                    self.conn.close()
                if should_stop():
                    raise Stopping from exc
                time.sleep(delay)
                delay = min(delay * 2, 10)

    def close(self):
        if self.conn is not None:
            self.conn.close()


def decode(messages, window: Window) -> tuple[list[Trade], int]:
    """Returns the de-duplicated trades and how many valid messages they came from."""
    batch: dict[tuple[str, int], Trade] = {}
    valid = 0
    for msg in messages:
        if msg.error():
            if msg.error().code() != KafkaError._PARTITION_EOF:
                logger.error("kafka message error", extra=log.fields(error=str(msg.error())))
            continue
        window.consumed += 1
        metrics.CONSUMED.inc()
        try:
            trade = parse_trade(msg.value())
        except ValueError as exc:
            # A malformed event can't be fixed by retrying; count it and move on
            # rather than block the partition forever.
            window.malformed += 1
            metrics.MALFORMED.inc()
            logger.error(
                "malformed message skipped",
                extra=log.fields(error=str(exc), partition=msg.partition(), offset=msg.offset()),
            )
            continue
        valid += 1
        batch[trade.key] = trade  # both producers deliver each trade: collapse in-batch duplicates
    return list(batch.values()), valid


def main():
    stopping = False

    def request_stop(*_):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    heartbeat = health.Heartbeat(max_age_s=60)
    health.serve({"loop": heartbeat.check})

    conf = kafka.base_config()
    conf.update(
        {
            "group.id": config.env("KAFKA_GROUP", "trades-consumer"),
            "enable.auto.commit": False,  # offsets move only after Postgres has the rows
            "auto.offset.reset": "earliest",
            # Incremental rebalancing: scaling out doesn't stop every consumer.
            "partition.assignment.strategy": "cooperative-sticky",
            # librdkafka reports per-partition lag every 5s; exported as trades_kafka_consumer_lag.
            "statistics.interval.ms": 5000,
            "stats_cb": metrics.record_consumer_stats,
        }
    )
    consumer = Consumer(conf)

    def on_assign(_c, partitions):
        logger.info("partitions assigned", extra=log.fields(partitions=[p.partition for p in partitions]))

    def on_revoke(_c, partitions):
        # Batches are committed before the next consume() call, which is where
        # this callback runs, so nothing processed is left uncommitted here.
        logger.info("partitions revoked", extra=log.fields(partitions=[p.partition for p in partitions]))

    consumer.subscribe([config.TOPIC], on_assign=on_assign, on_revoke=on_revoke)
    store = Store()
    window = Window()
    logger.info("started", extra=log.fields(topic=config.TOPIC, batch_size=BATCH_SIZE))

    try:
        while not stopping:
            messages = consumer.consume(num_messages=BATCH_SIZE, timeout=POLL_TIMEOUT_S)
            heartbeat.beat()
            trades, valid = decode(messages, window)
            if trades:
                inserted = store.insert_until_done(trades, lambda: stopping)
                committed_at = datetime.now(timezone.utc)
                # Latency is measured only for rows that became visible now: a
                # duplicate's later arrival doesn't make the stored row any staler.
                latencies = [(committed_at - trade_time).total_seconds() for _, trade_time in inserted]
                for (symbol, _), latency in zip(inserted, latencies):
                    metrics.INSERTED.labels(symbol=symbol).inc()
                    metrics.INGEST_LATENCY.observe(latency)
                metrics.DUPLICATES.inc(valid - len(inserted))
                metrics.BATCH_SIZE.observe(len(trades))
                window.observe(latencies)
            if messages:
                try:
                    consumer.commit(asynchronous=False)
                except KafkaException as exc:
                    # Typically a rebalance mid-commit; the rows are already safe in
                    # Postgres, so the worst case is a harmless replay.
                    logger.warning("offset commit failed", extra=log.fields(error=str(exc)))
            if time.monotonic() - window.started >= REPORT_EVERY_S:
                logger.info("stats", extra=log.fields(**window.summary()))
                window.reset()
    except Stopping:
        logger.info("stopped while database was unavailable; batch will be replayed")
    finally:
        logger.info("shutting down")
        consumer.close()  # leaves the group promptly so partitions move without waiting for a timeout
        store.close()


if __name__ == "__main__":
    main()
