# One image, several entrypoints (producer, consumer, dbinit, topic): they share
# the Kafka/DB/health code, and one image means one build and one tag to track.
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

# CA bundle for sslmode=verify-full against RDS. The directory is created first:
# ADD --chmod would otherwise create it as 644 (no x bit), and the non-root app
# user couldn't enter it.
RUN mkdir -m 755 -p /etc/ssl/rds
ADD --chmod=644 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /etc/ssl/rds/global-bundle.pem

COPY trades/ trades/

RUN useradd --uid 10001 --no-create-home app
USER 10001
# Fail the build, not the deploy, if the app user can't read the CA bundle.
RUN test -r /etc/ssl/rds/global-bundle.pem

EXPOSE 8080
ENTRYPOINT ["python", "-m"]
CMD ["trades.consumer"]
