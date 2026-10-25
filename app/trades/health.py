"""Tiny HTTP endpoint for Kubernetes probes and Prometheus.

The workload registers named checks; each returns (ok, detail). /healthz is 200
only when every check passes, so a wedged loop or a dead upstream gets the pod
restarted without anyone reading logs. /metrics serves the Prometheus registry.
"""

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable

from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

Check = Callable[[], tuple[bool, str]]


class Heartbeat:
    """Timestamp a loop touches on every iteration; stale means stuck."""

    def __init__(self, max_age_s: float):
        self.max_age_s = max_age_s
        self._last = time.monotonic()

    def beat(self) -> None:
        self._last = time.monotonic()

    def check(self) -> tuple[bool, str]:
        age = time.monotonic() - self._last
        return age < self.max_age_s, f"{age:.1f}s ago"


def serve(checks: dict[str, Check], port: int = 8080) -> None:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/metrics":
                body = generate_latest()
                self.send_response(200)
                self.send_header("Content-Type", CONTENT_TYPE_LATEST)
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path not in ("/healthz", "/readyz"):
                self.send_error(404)
                return
            results = {name: check() for name, check in checks.items()}
            ok = all(passed for passed, _ in results.values())
            body = json.dumps({n: {"ok": p, "detail": d} for n, (p, d) in results.items()}).encode()
            self.send_response(200 if ok else 503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):  # probes every few seconds would drown real logs
            pass

    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True, name="health").start()
