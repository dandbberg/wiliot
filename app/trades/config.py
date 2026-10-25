"""Environment-driven settings shared by every entrypoint."""

import os


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None:
        raise RuntimeError(f"missing required environment variable {name}")
    return value


def env_int(name: str, default: int) -> int:
    return int(os.environ.get(name, default))


REGION = env("AWS_REGION", "ca-central-1")
TOPIC = env("KAFKA_TOPIC", "trades")
