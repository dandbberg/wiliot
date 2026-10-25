import json
import unittest
from datetime import datetime, timezone
from decimal import Decimal

from trades.model import parse_trade, unwrap_combined

SAMPLE = {
    "e": "trade",
    "E": 1792576123962,
    "s": "ETHUSDT",
    "t": 4456165857,
    "p": "2458.32000000",
    "q": "0.00900000",
    "T": 1792576123962,
    "m": False,
}


def raw(**overrides):
    return json.dumps({**SAMPLE, **overrides})


class ParseTradeTest(unittest.TestCase):
    def test_sample_from_assignment(self):
        trade = parse_trade(raw())
        self.assertEqual(trade.symbol, "ETHUSDT")
        self.assertEqual(trade.trade_id, 4456165857)
        self.assertEqual(trade.price, Decimal("2458.32"))
        self.assertEqual(trade.quantity, Decimal("0.009"))
        self.assertEqual(trade.price * trade.quantity, Decimal("22.12488"))

    def test_milliseconds_are_exact(self):
        trade = parse_trade(raw(T=1792576123962))
        self.assertEqual(trade.trade_time.microsecond, 962_000)
        self.assertEqual(trade.trade_time.tzinfo, timezone.utc)
        self.assertEqual(trade.trade_time, datetime(2026, 10, 21, 9, 48, 43, 962_000, tzinfo=timezone.utc))

    def test_decimal_has_no_float_drift(self):
        trade = parse_trade(raw(p="0.10000000", q="0.20000000"))
        self.assertEqual(trade.price * trade.quantity, Decimal("0.02"))

    def test_rejects_malformed(self):
        cases = {
            "not json": "{",
            "wrong event": raw(e="aggTrade"),
            "missing price": json.dumps({k: v for k, v in SAMPLE.items() if k != "p"}),
            "float price": raw(p=2458.32),
            "nan price": raw(p="NaN"),
            "zero qty": raw(q="0"),
            "negative qty": raw(q="-1"),
            "string id": raw(t="123"),
            "bool id": raw(t=True),
            "empty symbol": raw(s=""),
        }
        for name, payload in cases.items():
            with self.subTest(name), self.assertRaises(ValueError):
                parse_trade(payload)

    def test_key_is_symbol_and_id(self):
        # Same id on two symbols must not collide.
        self.assertNotEqual(parse_trade(raw(s="BTCUSDT")).key, parse_trade(raw(s="ETHUSDT")).key)


class UnwrapTest(unittest.TestCase):
    def test_combined_frame(self):
        frame = json.dumps({"stream": "ethusdt@trade", "data": SAMPLE})
        self.assertEqual(unwrap_combined(frame), SAMPLE)

    def test_non_data_frame(self):
        self.assertIsNone(unwrap_combined(json.dumps({"result": None, "id": 1})))


if __name__ == "__main__":
    unittest.main()
