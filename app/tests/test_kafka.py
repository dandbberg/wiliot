import os
import unittest
from unittest import mock

from trades import kafka


class KafkaConfigTest(unittest.TestCase):
    def config(self, **env):
        with mock.patch.dict(os.environ, {"KAFKA_BOOTSTRAP": "kafka:9092", **env}, clear=False):
            return kafka.base_config()

    def test_plaintext_by_default(self):
        conf = self.config()
        self.assertNotIn("security.protocol", conf)

    def test_mtls_uses_mounted_certificate(self):
        conf = self.config(KAFKA_AUTH="mtls", KAFKA_TLS_DIR="/certs")
        self.assertEqual(conf["security.protocol"], "SSL")
        self.assertEqual(conf["ssl.ca.location"], "/certs/ca.crt")
        self.assertEqual(conf["ssl.certificate.location"], "/certs/tls.crt")
        self.assertEqual(conf["ssl.key.location"], "/certs/tls.key")
        self.assertEqual(conf["ssl.endpoint.identification.algorithm"], "https")

    def test_unknown_mode_is_rejected(self):
        with self.assertRaises(RuntimeError):
            self.config(KAFKA_AUTH="plain-ish")


if __name__ == "__main__":
    unittest.main()
