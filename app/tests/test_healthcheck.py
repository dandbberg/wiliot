import io
import unittest
from contextlib import redirect_stdout
from unittest import mock

from trades import healthcheck


def run(alerts, p99):
    """main() with Prometheus answering the given alerts and p99 (None = no data)."""
    answers = {
        'ALERTS{pipeline="trades"}': [{"metric": a} for a in alerts],
        "trades:ingest_latency_seconds:p99_5m": [] if p99 is None else [{"value": [0, str(p99)]}],
    }
    out = io.StringIO()
    with mock.patch.object(healthcheck, "query", side_effect=answers.__getitem__), redirect_stdout(out):
        code = healthcheck.main()
    return code, out.getvalue()


SLO_PENDING = {"alertname": "TradesFreshnessSLOBreached", "alertstate": "pending", "severity": "critical"}
LAG_FIRING = {"alertname": "TradesConsumerLagHigh", "alertstate": "firing", "severity": "warning"}


class HealthcheckTest(unittest.TestCase):
    def test_within_slo_is_healthy(self):
        code, out = run([], 0.5)
        self.assertEqual(code, 0)
        self.assertIn("HEALTHY", out)

    def test_p99_above_slo_is_unhealthy_even_before_the_alert_fires(self):
        code, out = run([SLO_PENDING], 176.58)
        self.assertEqual(code, 1)
        self.assertIn("UNHEALTHY", out)
        self.assertIn("PENDING", out)

    def test_firing_alert_is_unhealthy(self):
        code, _ = run([LAG_FIRING], 0.5)
        self.assertEqual(code, 1)

    def test_no_data_is_unknown(self):
        code, out = run([], None)
        self.assertEqual(code, 2)
        self.assertIn("UNKNOWN", out)


if __name__ == "__main__":
    unittest.main()
