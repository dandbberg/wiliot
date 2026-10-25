"""Binance trade event -> database row. Pure functions, no I/O."""

import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation

_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


@dataclass(frozen=True)
class Trade:
    symbol: str
    trade_id: int
    price: Decimal
    quantity: Decimal
    trade_time: datetime

    @property
    def key(self) -> tuple[str, int]:
        return self.symbol, self.trade_id


def _positive_decimal(raw: object, field: str) -> Decimal:
    # Binance sends prices/quantities as strings precisely so they survive
    # without float rounding; reject anything that isn't one.
    if not isinstance(raw, str):
        raise ValueError(f"{field} must be a string, got {type(raw).__name__}")
    try:
        value = Decimal(raw)
    except InvalidOperation as exc:
        raise ValueError(f"{field} is not a decimal: {raw!r}") from exc
    if not value.is_finite() or value <= 0:
        raise ValueError(f"{field} must be positive and finite: {raw!r}")
    return value


def ms_to_datetime(ms: int) -> datetime:
    # Integer arithmetic: float division would blur the milliseconds.
    return _EPOCH + timedelta(milliseconds=ms)


def parse_trade(raw: bytes | str) -> Trade:
    """Parse one trade event as published to Kafka. Raises ValueError if malformed."""
    try:
        event = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON: {exc}") from exc
    if not isinstance(event, dict) or event.get("e") != "trade":
        raise ValueError("not a trade event")
    try:
        symbol, trade_id, trade_ms = event["s"], event["t"], event["T"]
        price_raw, qty_raw = event["p"], event["q"]
    except KeyError as exc:
        raise ValueError(f"missing field {exc}") from exc
    if not isinstance(symbol, str) or not symbol:
        raise ValueError("symbol must be a non-empty string")
    if not isinstance(trade_id, int) or isinstance(trade_id, bool) or trade_id < 0:
        raise ValueError(f"trade id must be a non-negative integer: {trade_id!r}")
    if not isinstance(trade_ms, int) or isinstance(trade_ms, bool):
        raise ValueError(f"trade time must be integer milliseconds: {trade_ms!r}")
    return Trade(
        symbol=symbol,
        trade_id=trade_id,
        price=_positive_decimal(price_raw, "price"),
        quantity=_positive_decimal(qty_raw, "quantity"),
        trade_time=ms_to_datetime(trade_ms),
    )


def unwrap_combined(raw: str | bytes) -> dict | None:
    """Combined-stream frames look like {"stream": "...", "data": {...}}; return data."""
    frame = json.loads(raw)
    data = frame.get("data") if isinstance(frame, dict) else None
    return data if isinstance(data, dict) else None
