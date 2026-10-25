# Connection attempts that must be refused; run by scripts/chaos.sh security.
import sys, socket
from confluent_kafka import Consumer, KafkaException
from confluent_kafka.admin import AdminClient
B = "kafka.kafka.svc.cluster.local:9092"
mode = sys.argv[1]
if mode == "tcp":
    s = socket.socket(); s.settimeout(5)
    try: s.connect(("kafka.kafka.svc.cluster.local", 9092)); print("RESULT: TCP connected (NOT blocked)")
    except OSError as e: print("RESULT: blocked before TLS:", type(e).__name__, e)
    sys.exit()
base = {"bootstrap.servers": B, "socket.timeout.ms": 6000, "log_level": 0}
if mode == "plaintext":
    conf = base
elif mode == "no-cert":
    conf = {**base, "security.protocol": "SSL", "ssl.ca.location": "/ca/ca.crt"}
elif mode == "producer-reads":
    conf = {**base, "security.protocol": "SSL", "ssl.ca.location": "/c/ca.crt", "ssl.certificate.location": "/c/tls.crt", "ssl.key.location": "/c/tls.key"}
if mode == "producer-reads":
    c = Consumer({**conf, "group.id": "trades-consumer", "auto.offset.reset": "earliest"})
    c.subscribe(["trades"])
    for _ in range(10):
        m = c.poll(2)
        if m is None: continue
        if m.error(): print("RESULT: refused:", m.error().name(), "-", m.error().str()[:90]); break
        print("RESULT: READ A MESSAGE (NOT refused)"); break
    else: print("RESULT: no data and no error")
    sys.exit()
try:
    md = AdminClient(conf).list_topics(timeout=8)
    print("RESULT: connected, topics:", list(md.topics)[:3], "(NOT refused)")
except KafkaException as e:
    print("RESULT: refused:", e.args[0].name(), "-", e.args[0].str()[:90])
