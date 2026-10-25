import json
import unittest

from prometheus_client import REGISTRY

from trades import metrics


def lag(partition):
    return REGISTRY.get_sample_value("trades_kafka_consumer_lag", {"partition": partition})


def stats(partitions):
    return json.dumps({"topics": {"trades": {"partitions": partitions}}})


class ConsumerStatsTest(unittest.TestCase):
    def test_exports_lag_for_owned_partitions_only(self):
        metrics.record_consumer_stats(
            stats(
                {
                    "0": {"fetch_state": "active", "consumer_lag": 7, "hi_offset": 100},
                    "1": {"fetch_state": "none", "consumer_lag": -1, "hi_offset": -1},  # not ours
                    "-1": {"fetch_state": "none", "consumer_lag": -1},  # librdkafka's internal UA partition
                }
            )
        )
        self.assertEqual(lag("0"), 7)
        self.assertIsNone(lag("1"))
        self.assertIsNone(lag("-1"))
        self.assertEqual(
            REGISTRY.get_sample_value("trades_kafka_partition_high_watermark", {"partition": "0"}), 100
        )

    def test_revoked_partition_stops_reporting(self):
        metrics.record_consumer_stats(stats({"3": {"fetch_state": "active", "consumer_lag": 5, "hi_offset": 9}}))
        metrics.record_consumer_stats(stats({"4": {"fetch_state": "active", "consumer_lag": 0, "hi_offset": 2}}))
        self.assertIsNone(lag("3"))
        self.assertEqual(lag("4"), 0)


if __name__ == "__main__":
    unittest.main()
