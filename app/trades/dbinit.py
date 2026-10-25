"""One-off schema and role bootstrap, run as the RDS master user.

Owning the schema here keeps the consumer at SELECT/INSERT only: it can't alter
or drop the table it writes to. Every statement is idempotent so re-runs are safe.
"""

from psycopg import sql

from . import config, db, log

logger = log.setup("dbinit")

SCHEMA = """
CREATE TABLE IF NOT EXISTS trades (
    symbol      text           NOT NULL,
    trade_id    bigint         NOT NULL,
    -- Unconstrained numeric stores exactly what Binance sent (no rounding to a
    -- fixed scale), and the product of two exact values is itself exact.
    price       numeric     NOT NULL,
    quantity    numeric     NOT NULL,
    notional    numeric     GENERATED ALWAYS AS (price * quantity) STORED,
    trade_time  timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT now(),
    -- Binance trade ids are unique per symbol, not globally.
    PRIMARY KEY (symbol, trade_id)
);
CREATE INDEX IF NOT EXISTS trades_trade_time_idx ON trades (trade_time);
CREATE INDEX IF NOT EXISTS trades_ingested_at_idx ON trades (ingested_at);
"""


def main():
    app_user = config.env("DB_USER", "consumer")
    auth = config.env("DB_AUTH", "password")
    role = sql.Identifier(app_user)

    with db.connect(admin=True) as conn, conn.cursor() as cur:
        # Serialise concurrent runs (e.g. an upgrade racing a retry).
        cur.execute("SELECT pg_advisory_xact_lock(hashtext('trades-dbinit'))")
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (app_user,))
        if cur.fetchone() is None:
            cur.execute(sql.SQL("CREATE ROLE {} LOGIN").format(role))
            logger.info("created role", extra=log.fields(role=app_user))
        if auth == "iam":
            # rds_iam makes Postgres accept IAM auth tokens instead of a password.
            cur.execute(sql.SQL("GRANT rds_iam TO {}").format(role))
        else:
            cur.execute(
                sql.SQL("ALTER ROLE {} PASSWORD {}").format(role, sql.Literal(config.env("DB_PASSWORD")))
            )
        cur.execute(SCHEMA)
        cur.execute(sql.SQL("GRANT SELECT, INSERT ON trades TO {}").format(role))
    logger.info("schema ready", extra=log.fields(auth=auth, role=app_user))


if __name__ == "__main__":
    main()
