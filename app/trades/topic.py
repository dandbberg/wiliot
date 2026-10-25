"""Create the trades topic if it doesn't exist. Idempotent; runs before the workloads."""

from confluent_kafka import KafkaError, KafkaException
from confluent_kafka.admin import AdminClient, NewTopic

from . import config, kafka, log

logger = log.setup("topic")


def main():
    admin = AdminClient(kafka.base_config())
    topic = NewTopic(
        config.TOPIC,
        num_partitions=config.env_int("TOPIC_PARTITIONS", 12),
        replication_factor=config.env_int("TOPIC_REPLICATION", 3),
        config={
            "min.insync.replicas": config.env("TOPIC_MIN_ISR", "2"),
            "retention.ms": str(config.env_int("TOPIC_RETENTION_HOURS", 72) * 3600 * 1000),
        },
    )
    future = admin.create_topics([topic], request_timeout=30)[config.TOPIC]
    try:
        future.result()
        logger.info("topic created", extra=log.fields(topic=config.TOPIC))
    except KafkaException as exc:
        if exc.args[0].code() != KafkaError.TOPIC_ALREADY_EXISTS:
            raise
        logger.info("topic already exists", extra=log.fields(topic=config.TOPIC))


if __name__ == "__main__":
    main()
