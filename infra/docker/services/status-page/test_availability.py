"""Concrete synthetic availability rules, with live local HTTP and durable reads."""
import json
import tempfile
import threading
import time
import unittest
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from availability import database, initialize, load_targets, probe, sample, snapshot
from server import StatusHandler


class ProbeHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/up")
            self.end_headers()
            return
        self.send_response(200 if self.path == "/up" else 503)
        self.end_headers()

    def log_message(self, *_args):
        return


class AvailabilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.db = str(Path(self.temporary.name) / "samples.sqlite")
        initialize(self.db)
        self.targets = [{"name": "API", "url": "http://localhost/up"}]
        self.now = int(time.time())

    def rows(self, *rows):
        with database(self.db) as connection:
            connection.executemany("INSERT INTO samples VALUES (?, ?, ?, ?)", rows)

    def read(self, now=None):
        return snapshot(self.db, self.targets, 300, 86400, self.now if now is None else now)

    def test_no_samples_is_unknown(self):
        self.assertEqual(self.read()["status"], "unknown")
        self.assertEqual(self.read()["components"][0]["sample_count"], 0)

    def test_recent_success_is_operational(self):
        self.rows(("API", self.now, 1, 12))
        self.assertEqual(self.read()["status"], "operational")

    def test_failed_probe_is_degraded_and_preserved(self):
        self.rows(("API", self.now - 60, 1, 12), ("API", self.now, 0, 5000))
        result = self.read()
        self.assertEqual(result["status"], "degraded")
        self.assertEqual(result["components"][0]["failed_checks"], [self.now])
        self.assertEqual(result["components"][0]["successful_samples"], 1)

    def test_stale_success_is_not_uptime(self):
        self.rows(("API", self.now - 301, 1, 2))
        self.assertEqual(self.read()["status"], "unknown")

    def test_expired_samples_do_not_count(self):
        self.rows(("API", self.now - 86401, 0, 2), ("API", self.now, 1, 2))
        self.assertEqual(self.read()["components"][0]["sample_count"], 1)

    def test_future_samples_are_unknown(self):
        self.rows(("API", self.now + 1, 1, 2))
        self.assertEqual(self.read()["status"], "unknown")

    def test_restart_reads_persistent_history(self):
        self.rows(("API", self.now, 0, 2))
        initialize(self.db)
        self.assertEqual(self.read()["status"], "degraded")

    def test_public_data_does_not_expose_urls(self):
        self.assertNotIn("http://", json.dumps(self.read()))

    def test_bad_target_config_is_refused(self):
        path = Path(self.temporary.name) / "targets.json"
        for targets in ([], [{"name": "API", "url": "file:///etc/passwd"}],
                        [{"name": "API", "url": "http://user:password@host/"}],
                        self.targets * 2, [{"name": "API", "url": "http://host", "expected_status": ["200"]}]):
            path.write_text(json.dumps(targets))
            with self.assertRaises(ValueError):
                load_targets(path)

    def test_real_http_probe_to_public_page(self):
        from urllib.request import urlopen
        peer = ThreadingHTTPServer(("127.0.0.1", 0), ProbeHandler)
        threading.Thread(target=peer.serve_forever, daemon=True).start()
        self.addCleanup(peer.server_close)
        self.addCleanup(peer.shutdown)
        target = {"name": "API", "url": f"http://127.0.0.1:{peer.server_port}/up"}
        self.assertEqual(probe(target, 1)[0], 1)
        redirect = {"name": "API", "url": f"http://127.0.0.1:{peer.server_port}/redirect"}
        self.assertEqual(probe(redirect, 1)[0], 0)
        sample(self.db, [target], 1, 86400)
        settings = {"db": self.db, "targets": [target], "stale": 300, "retention": 86400}
        public = ThreadingHTTPServer(("127.0.0.1", 0), partial(StatusHandler, settings=settings))
        threading.Thread(target=public.serve_forever, daemon=True).start()
        self.addCleanup(public.server_close)
        self.addCleanup(public.shutdown)
        base = f"http://127.0.0.1:{public.server_port}"
        with urlopen(base + "/status.json") as response:
            self.assertEqual(json.load(response)["status"], "operational")
        with urlopen(base + "/") as response:
            self.assertIn(b"Grobase status", response.read())
        target["url"] = f"http://127.0.0.1:{peer.server_port}/down"
        sample(self.db, [target], 1, 86400)
        self.assertEqual(snapshot(self.db, [target], 300, 86400)["status"], "degraded")


if __name__ == "__main__":
    unittest.main()
