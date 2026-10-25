import unittest

from confluent_kafka import KafkaError, KafkaException

from trades.producer import Outbox


class FakeProducer:
    """Accepts produce() calls only while `accepting` is True."""

    def __init__(self, error=None):
        self.accepting = False
        self.error = error or KafkaException(KafkaError(KafkaError.TOPIC_AUTHORIZATION_FAILED))
        self.sent = []

    def produce(self, topic, key, value):
        if not self.accepting:
            raise self.error
        self.sent.append(key)


class OutboxTest(unittest.TestCase):
    def test_refused_trades_are_kept_then_resent(self):
        p = FakeProducer()
        box = Outbox(p, "trades", max_pending=100)
        for i in range(5):
            self.assertFalse(box.send(f"BTCUSDT:{i}", "{}"))
        self.assertEqual(len(box.pending), 5)
        p.accepting = True  # e.g. ACLs and topic now exist
        self.assertEqual(box.retry(), 5)
        self.assertEqual(p.sent, [f"BTCUSDT:{i}" for i in range(5)])
        self.assertEqual(len(box.pending), 0)

    def test_full_local_queue_is_not_a_loss(self):
        p = FakeProducer(error=BufferError())
        box = Outbox(p, "trades", max_pending=100)
        box.send("ETHUSDT:1", "{}")
        self.assertEqual(len(box.pending), 1)

    def test_retry_stops_at_first_refusal(self):
        p = FakeProducer()
        box = Outbox(p, "trades", max_pending=100)
        box.send("a", "{}")
        box.send("b", "{}")
        self.assertEqual(box.retry(), 0)
        self.assertEqual(len(box.pending), 2)  # nothing lost, order kept

    def test_drops_only_beyond_the_bound(self):
        p = FakeProducer()
        box = Outbox(p, "trades", max_pending=3)
        for i in range(5):
            box.send(str(i), "{}")
        self.assertEqual(box.dropped, 2)
        self.assertEqual([k for k, _ in box.pending], ["2", "3", "4"])

    def test_fatal_errors_are_raised(self):
        p = FakeProducer(error=KafkaException(KafkaError(KafkaError._FENCED, fatal=True)))
        box = Outbox(p, "trades", max_pending=100)
        with self.assertRaises(KafkaException):
            box.send("x", "{}")


if __name__ == "__main__":
    unittest.main()
