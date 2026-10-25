"""librdkafka client settings. KAFKA_AUTH=none locally, msk-iam on AWS."""

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
    if auth == "msk-iam":
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
