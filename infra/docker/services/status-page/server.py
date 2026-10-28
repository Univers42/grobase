"""Read-only status server and periodic probe, with no public write endpoint."""
import json
import os
import threading
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from availability import initialize, load_targets, sample, snapshot


def positive(name, default):
    """Reject settings that would disable freshness or create unbounded tight loops."""
    value = int(os.environ.get(name, default))
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


def collect(stop, settings):
    """Storage failures leave old samples stale; no synthetic successful samples."""
    while not stop.is_set():
        try:
            sample(settings["db"], settings["targets"], settings["timeout"], settings["retention"])
        except Exception:
            print("status sample could not be persisted", flush=True)
        stop.wait(settings["interval"])


class StatusHandler(BaseHTTPRequestHandler):
    """Serve only the public page, measured JSON and readiness; never target URLs."""

    def __init__(self, *args, settings, **kwargs):
        self.settings = settings
        super().__init__(*args, **kwargs)

    def do_GET(self):
        if self.path == "/":
            body = Path(__file__).with_name("status.html").read_bytes()
            return self.respond(200, "text/html; charset=utf-8", body)
        if self.path not in ("/status.json", "/health/ready"):
            return self.respond(404, "text/plain", b"Not found")
        try:
            data = snapshot(self.settings["db"], self.settings["targets"], self.settings["stale"], self.settings["retention"])
        except Exception:
            return self.respond(503, "application/json", b'{"status":"unknown"}')
        code = 503 if self.path == "/health/ready" and data["status"] != "operational" else 200
        self.respond(code, "application/json", json.dumps(data).encode())

    def respond(self, code, content_type, body):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-ancestors 'none'")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


def main():
    """An explicitly enabled, independently deployable operational service."""
    settings = {"db": "/data/availability.sqlite", "targets": load_targets("/config/targets.json"),
                "interval": positive("STATUS_INTERVAL_SECONDS", 60), "timeout": positive("STATUS_TIMEOUT_SECONDS", 5),
                "stale": positive("STATUS_STALE_SECONDS", 300), "retention": positive("STATUS_RETENTION_DAYS", 30) * 86400}
    if settings["stale"] < settings["interval"] + len(settings["targets"]) * settings["timeout"]:
        raise ValueError("stale threshold must exceed a full probe cycle")
    initialize(settings["db"])
    stop = threading.Event()
    thread = threading.Thread(target=collect, args=(stop, settings), daemon=True)
    thread.start()
    server = ThreadingHTTPServer(("0.0.0.0", 8080), partial(StatusHandler, settings=settings))
    try:
        server.serve_forever()
    finally:
        stop.set()
        server.server_close()
        thread.join(timeout=settings["timeout"] * len(settings["targets"]) + 1)


if __name__ == "__main__":
    main()
