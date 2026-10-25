"""Binance combined trade stream -> Kafka.

Runs as two independent replicas: Binance can't replay a WebSocket, so a second
live connection covers whatever the first misses while reconnecting. The
duplicates that creates are removed by the consumer's primary key.
"""

import asyncio
import json
import os
import random
import signal
import time

from confluent_kafka import Producer
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


def build_producer(stats: Stats) -> Producer:
    conf = kafka.base_config()
    def on_delivery(err, _msg):
        if err is None:
            stats.delivered += 1
            stats.last_delivery = time.monotonic()
            metrics.KAFKA_DELIVERED.inc()
            return
        stats.failed += 1
        metrics.KAFKA_DELIVERY_FAILED.inc()
        logger.error("delivery failed", extra=log.fields(error=str(err)))
        if err.fatal():
            # Idempotent producer fatal errors need a new producer instance; let k8s restart us.
            logger.critical("fatal producer error, exiting")
            os._exit(1)

    conf.update(
        {
            # Idempotence + acks=all: broker retries can't create duplicates or
            # reorder within a partition, and nothing is acked before min ISR has it.
            "enable.idempotence": True,
            "acks": "all",
            "linger.ms": 20,
            "compression.type": "lz4",
            "delivery.timeout.ms": 120_000,
            "on_delivery": on_delivery,
        }
    )
    return Producer(conf)


def publish(producer: Producer, data: dict) -> None:
    value = json.dumps(data, separators=(",", ":"))
    while True:
        try:
            # Key = symbol:trade_id. Keying by symbol alone piled 9 symbols onto 6 of
            # 12 partitions with ETH hot on one; nothing downstream needs per-symbol
            # order (inserts are idempotent), so spread evenly instead. Both
            # producers' copies of a trade still share a key, hence a partition,
            # so the consumer collapses them within a batch.
            producer.produce(config.TOPIC, key=f"{data['s']}:{data['t']}", value=value)
            return
        except BufferError:
            # Local queue full (Kafka slow/unavailable): block briefly rather than drop.
            producer.poll(0.1)


async def stream(producer: Producer, stats: Stats, heartbeat: health.Heartbeat, stop: asyncio.Event):
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
                publish(producer, data)
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


async def pump(producer: Producer, stop: asyncio.Event):
    """Serve delivery callbacks; produce() alone never triggers them."""
    while not stop.is_set():
        producer.poll(0)
        metrics.KAFKA_QUEUE.set(len(producer))
        await asyncio.sleep(0.05)


async def report(stats: Stats, stop: asyncio.Event):
    while not stop.is_set():
        await asyncio.sleep(30)
        logger.info(
            "stats",
            extra=log.fields(
                received=stats.received,
                delivered=stats.delivered,
                failed=stats.failed,
                reconnects=stats.reconnects,
            ),
        )


async def main():
    stats = Stats()
    producer = build_producer(stats)
    ws_heartbeat = health.Heartbeat(max_age_s=STALE_STREAM_S * 2)

    def kafka_check():
        age = time.monotonic() - stats.last_delivery
        return age < 120, f"last delivery {age:.0f}s ago"

    health.serve({"websocket": ws_heartbeat.check, "kafka": kafka_check})

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    tasks = [
        asyncio.create_task(stream(producer, stats, ws_heartbeat, stop)),
        asyncio.create_task(pump(producer, stop)),
        asyncio.create_task(report(stats, stop)),
    ]
    await stop.wait()
    logger.info("shutting down")
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    remaining = producer.flush(10)
    logger.info("flushed", extra=log.fields(undelivered=remaining, delivered=stats.delivered))


if __name__ == "__main__":
    asyncio.run(main())
