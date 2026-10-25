"""PostgreSQL connections. DB_AUTH=password locally, iam on RDS (no stored password)."""

import json

import psycopg

from . import config

RDS_CA_BUNDLE = "/etc/ssl/rds/global-bundle.pem"


def _iam_token(host: str, port: int, user: str) -> str:
    import boto3

    # SigV4-signed, valid 15 minutes; only checked when a connection opens.
    return boto3.client("rds", region_name=config.REGION).generate_db_auth_token(
        DBHostname=host, Port=port, DBUsername=user, Region=config.REGION
    )


def _admin_secret() -> tuple[str, str]:
    """Master credentials that RDS keeps in Secrets Manager; read only by db-init."""
    import boto3

    arn = config.env("DB_ADMIN_SECRET_ARN")
    secret = boto3.client("secretsmanager", region_name=config.REGION).get_secret_value(SecretId=arn)
    parsed = json.loads(secret["SecretString"])
    return parsed["username"], parsed["password"]


def connect(admin: bool = False) -> psycopg.Connection:
    host = config.env("DB_HOST")
    port = config.env_int("DB_PORT", 5432)
    params = {
        "host": host,
        "port": port,
        "dbname": config.env("DB_NAME", "trades"),
        "connect_timeout": 5,
        "application_name": config.env("HOSTNAME", "trades"),
    }
    auth = config.env("DB_AUTH", "password")
    if auth == "iam":
        # verify-full: the token is a bearer credential, so make sure we hand it to RDS.
        params.update(sslmode="verify-full", sslrootcert=RDS_CA_BUNDLE)
        if admin:
            params["user"], params["password"] = _admin_secret()
        else:
            params["user"] = config.env("DB_USER", "consumer")
            params["password"] = _iam_token(host, port, params["user"])
    elif auth == "password":
        prefix = "DB_ADMIN_" if admin else "DB_"
        params["user"] = config.env(prefix + "USER")
        params["password"] = config.env(prefix + "PASSWORD")
        params["sslmode"] = config.env("DB_SSLMODE", "prefer")
    else:
        raise RuntimeError(f"unknown DB_AUTH {auth!r}")
    return psycopg.connect(**params)
