"""librdkafka client settings, by KAFKA_AUTH:

  none     plaintext (minikube)
  mtls     TLS with a client certificate (EKS); the certificate's CN is the
           Kafka principal the broker's ACLs are written for
  msk-iam  SASL/OAUTHBEARER with IAM (MSK; not used here, kept for reference)
"""

import os
import socket

from . import config


def _oauth_cb(_oauth_config: str):
    # Imported lazily so local runs don't need AWS credentials at import time.
    from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

    token, expiry_ms = MSKAuthTokenProvider.generate_auth_token(config.REGION)
    return token, expiry_ms / 1000


def base_config() -> dict:
    conf = {
        "bootstrap.servers": config.env("KAFKA_BOOTSTRAP"),
        "client.id": socket.gethostname(),
    }
    auth = config.env("KAFKA_AUTH", "none")
    if auth == "mtls":
        # cert-manager Secret mounted as files: ca.crt, tls.crt, tls.key.
        tls_dir = config.env("KAFKA_TLS_DIR", "/etc/kafka-tls")
        conf.update(
            {
                "security.protocol": "SSL",
                "ssl.ca.location": os.path.join(tls_dir, "ca.crt"),
                "ssl.certificate.location": os.path.join(tls_dir, "tls.crt"),
                "ssl.key.location": os.path.join(tls_dir, "tls.key"),
                # Verify the broker's certificate matches its DNS name.
                "ssl.endpoint.identification.algorithm": "https",
            }
        )
    elif auth == "msk-iam":
        conf.update(
            {
                "security.protocol": "SASL_SSL",
                "sasl.mechanisms": "OAUTHBEARER",
                "oauth_cb": _oauth_cb,
            }
        )
    elif auth != "none":
        raise RuntimeError(f"unknown KAFKA_AUTH {auth!r}")
    return conf
