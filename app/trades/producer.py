"""Binance combined trade stream -> Kafka.

Runs as several independent replicas: Binance can't replay a WebSocket, so
another live connection covers whatever one misses while reconnecting. The
duplicates that creates are removed by the consumer's primary key.

A trade Kafka hasn't accepted is never dropped on a non-fatal error: it stays
in the Outbox and is retried (Kafka down, topic or ACLs not there yet, leader
changes). Retries may duplicate a trade; the primary key absorbs that too.
"""

import asyncio
import collections
import json
import os
import random
import signal
import time

from confluent_kafka import KafkaException, Producer
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from . import config, health, kafka, log, metrics
from .model import unwrap_combined

SYMBOLS = os.environ.get(
    "SYMBOLS",
    "btcusdt,ethusdt,solusdt,bnbusdt,xrpusdt,adausdt,dogeusdt,avaxusdt,linkusdt,maticusdt,polusdt",
).split(",")
WS_BASE = os.environ.get("BINANCE_WS", "wss://stream.binance.com:9443")
# Binance closes every connection at 24h; leave on our own terms before that.
MAX_CONNECTION_AGE_S = config.env_int("MAX_CONNECTION_AGE_S", 23 * 3600)
# BTC alone trades many times a second, so a minute of silence means a dead stream.
STALE_STREAM_S = config.env_int("STALE_STREAM_S", 60)
# How long trades wait in the local queue when Kafka is unreachable (broker
# restart, cluster replacement). The WebSocket can't replay, so this is what
# stands between a Kafka outage and lost trades.
DELIVERY_TIMEOUT_S = config.env_int("DELIVERY_TIMEOUT_S", 600)
# Trades held for retry, in memory. ~300 bytes each: 200k is ~60 MB, about an
# hour of current volume. Only beyond that is anything dropped (and counted).
MAX_PENDING = config.env_int("MAX_PENDING", 200_000)

logger = log.setup("producer")


class Stats:
    def __init__(self):
        self.received = 0
        self.delivered = 0
        self.failed = 0
        self.reconnects = 0
        self.last_delivery = time.monotonic()


def stream_url() -> str:
    streams = "/".join(f"{s.strip().lower()}@trade" for s in SYMBOLS if s.strip())
    return f"{WS_BASE}/stream?streams={streams}"


class Outbox:
    """Trades Kafka hasn't accepted yet.

    send() hands a trade to the Kafka client; if the client refuses it (local
    queue full, topic unknown, not authorized...) the trade is kept here.
    Delivery failures reported later come back here too. retry() re-sends.
    """

    def __init__(self, producer, topic: str, max_pending: int):
        self.producer = producer
        self.topic = topic
        self.max_pending = max_pending
        self.pending = collections.deque()
        self.dropped = 0

    def send(self, key: bytes | str, value: bytes | str) -> bool:
        try:
            self.producer.produce(self.topic, key=key, value=value)
            return True
        except BufferError:
            pass  # client's own queue is full: Kafka slow or unreachable
        except KafkaException as exc:
            if exc.args[0].fatal():
                raise
        self.keep(key, value)
        return False

    def keep(self, key, value) -> None:
        if len(self.pending) >= self.max_pending:
            self.pending.popleft()  # oldest first: only when the bound is hit
            self.dropped += 1
            metrics.KAFKA_DROPPED.inc()
        self.pending.append((key, value))
        metrics.KAFKA_PENDING.set(len(self.pending))

    def retry(self, limit: int = 2000) -> int:
        """Re-send up to `limit` kept trades; stop at the first refusal."""
        sent = 0
        while self.pending and sent < limit:
            key, value = self.pending.popleft()
            if not self.send(key, value):
                # send() put it back at the end; Kafka still isn't taking writes.
                break
            sent += 1
        metrics.KAFKA_PENDING.set(len(self.pending))
        return sent


def build_producer(stats: Stats) -> tuple[Producer, Outbox]:
    conf = kafka.base_config()
    outbox: Outbox | None = None

    def on_delivery(err, msg):
        if err is None:
            stats.delivered += 1
            stats.last_delivery = time.monotonic()
            metrics.KAFKA_DELIVERED.inc()
            return
        stats.failed += 1
        metrics.KAFKA_DELIVERY_FAILED.inc()
        if err.fatal():
            # Idempotent producer fatal errors need a new producer instance; let k8s restart us.
            logger.critical("fatal producer error, exiting", extra=log.fields(error=str(err)))
            os._exit(1)
        # Not accepted (timeout, not authorized yet, unknown topic...): keep it.
        outbox.keep(msg.key(), msg.value())
        if stats.failed % 1000 == 1:
            logger.warning("delivery failed, kept for retry", extra=log.fields(error=str(err), pending=len(outbox.pending)))

    conf.update(
        {
            # Idempotence + acks=all: broker retries can't create duplicates or
            # reorder within a partition, and nothing is acked before min ISR has it.
            "enable.idempotence": True,
            "acks": "all",
            "linger.ms": 20,
            "compression.type": "lz4",
            "delivery.timeout.ms": DELIVERY_TIMEOUT_S * 1000,
            "on_delivery": on_delivery,
        }
    )
    producer = Producer(conf)
    outbox = Outbox(producer, config.TOPIC, MAX_PENDING)
    return producer, outbox


def publish(outbox: Outbox, data: dict) -> None:
    value = json.dumps(data, separators=(",", ":"))
    # Key = symbol:trade_id. Keying by symbol alone piled 9 symbols onto 6 of
    # 12 partitions with ETH hot on one; nothing downstream needs per-symbol
    # order (inserts are idempotent), so spread evenly instead. All producers'
    # copies of a trade share a key, hence a partition, so the consumer
    # collapses them within a batch.
    outbox.send(f"{data['s']}:{data['t']}", value)


async def stream(outbox: Outbox, stats: Stats, heartbeat: health.Heartbeat, stop: asyncio.Event):
    url = stream_url()
    # `async for` reconnects automatically with exponential backoff on network errors.
    async for ws in connect(url, open_timeout=10, ping_interval=20, ping_timeout=20, max_size=2**20):
        connected_at = time.monotonic()
        metrics.WS_CONNECTED.set(1)
        logger.info("connected", extra=log.fields(streams=len(SYMBOLS)))
        try:
            while not stop.is_set():
                if time.monotonic() - connected_at > MAX_CONNECTION_AGE_S:
                    logger.info("rotating connection before Binance's 24h cutoff")
                    break
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=STALE_STREAM_S)
                except TimeoutError:
                    logger.warning("no messages, reconnecting", extra=log.fields(timeout_s=STALE_STREAM_S))
                    break
                heartbeat.beat()
                metrics.WS_LAST_MESSAGE.set_to_current_time()
                data = unwrap_combined(raw)
                if data is None or data.get("e") != "trade" or "s" not in data or "t" not in data:
                    continue
                stats.received += 1
                metrics.WS_TRADES.labels(symbol=data["s"]).inc()
                publish(outbox, data)
        except ConnectionClosed as exc:
            logger.warning("connection closed", extra=log.fields(code=exc.rcvd.code if exc.rcvd else None))
        finally:
            metrics.WS_CONNECTED.set(0)
            await ws.close()
        if stop.is_set():
            return
        stats.reconnects += 1
        metrics.WS_RECONNECTS.inc()
        await asyncio.sleep(random.uniform(0.5, 2.0))  # jitter so replicas don't reconnect in lockstep


async def pump(producer: Producer, outbox: Outbox, stop: asyncio.Event):
    """Serve delivery callbacks (produce() alone never triggers them), and
    re-send kept trades about once a second."""
    last_retry = 0.0
    while not stop.is_set():
        producer.poll(0)
        metrics.KAFKA_QUEUE.set(len(producer))
        if outbox.pending and time.monotonic() - last_retry >= 1.0:
            last_retry = time.monotonic()
            outbox.retry()
        await asyncio.sleep(0.05)


async def report(stats: Stats, outbox: Outbox, stop: asyncio.Event):
    while not stop.is_set():
        await asyncio.sleep(30)
        logger.info(
            "stats",
            extra=log.fields(
                received=stats.received,
                delivered=stats.delivered,
                failed=stats.failed,
                pending=len(outbox.pending),
                dropped=outbox.dropped,
                reconnects=stats.reconnects,
            ),
        )


async def main():
    stats = Stats()
    producer, outbox = build_producer(stats)
    ws_heartbeat = health.Heartbeat(max_age_s=STALE_STREAM_S * 2)

    def kafka_check():
        age = time.monotonic() - stats.last_delivery
        # Unhealthy only once queued trades would be expiring anyway: restarting
        # earlier would throw away the buffer that is riding out the outage.
        return age < DELIVERY_TIMEOUT_S, f"last delivery {age:.0f}s ago"

    health.serve({"websocket": ws_heartbeat.check, "kafka": kafka_check})

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    tasks = [
        asyncio.create_task(stream(outbox, stats, ws_heartbeat, stop)),
        asyncio.create_task(pump(producer, outbox, stop)),
        asyncio.create_task(report(stats, outbox, stop)),
    ]

    # A task that dies on its own would leave the process alive but silent
    # (e.g. no longer reading the WebSocket). Exit at once instead, loudly.
    def died(task: asyncio.Task):
        if not task.cancelled() and task.exception() is not None:
            logger.critical("task failed, exiting", exc_info=task.exception())
            os._exit(1)

    for task in tasks:
        task.add_done_callback(died)
    await stop.wait()
    logger.info("shutting down")
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    outbox.retry(limit=len(outbox.pending))  # last chance for kept trades
    remaining = producer.flush(10)
    logger.info(
        "flushed",
        extra=log.fields(undelivered=remaining, still_pending=len(outbox.pending), delivered=stats.delivered),
    )


if __name__ == "__main__":
    asyncio.run(main())
