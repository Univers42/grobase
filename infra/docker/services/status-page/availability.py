"""Durable synthetic samples; gaps remain unknown rather than becoming uptime."""
import json
import sqlite3
import time
from contextlib import contextmanager
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


@contextmanager
def database(path):
    """Commit transactions and close handles on both success and failure."""
    connection = sqlite3.connect(path)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


class NoRedirect(HTTPRedirectHandler):
    """Only probe the configured address, never an upstream redirect destination."""

    def redirect_request(self, *_args, **_kwargs):
        return None


def load_targets(path):
    """Validate operator-owned URLs without publishing addresses or credentials."""
    with open(path, encoding="utf-8") as source:
        targets = json.load(source)
    if not isinstance(targets, list) or not 1 <= len(targets) <= 32:
        raise ValueError("configure between 1 and 32 targets")
    names = set()
    for target in targets:
        if not isinstance(target, dict):
            raise ValueError("each target must be an object")
        name = target.get("name")
        url = urlsplit(target.get("url", ""))
        codes = target.get("expected_status", [200])
        if not isinstance(name, str) or not 1 <= len(name) <= 80 or name in names:
            raise ValueError("target names must be unique and non-empty")
        if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password:
            raise ValueError("targets require HTTP(S) URLs without credentials")
        if not isinstance(codes, list) or not codes or any(type(code) is not int or not 100 <= code <= 599 for code in codes):
            raise ValueError("expected_status must contain explicit HTTP status codes")
        names.add(name)
    return targets


def initialize(path):
    """SQLite lives on the probe's persistent volume, not the database host."""
    with database(path) as connection:
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("CREATE TABLE IF NOT EXISTS samples (name TEXT, at INTEGER, ok INTEGER, latency INTEGER)")
        connection.execute("CREATE INDEX IF NOT EXISTS samples_name_at ON samples(name, at)")


def probe(target, timeout):
    """An exact expected HTTP response is available; network failures are down."""
    started = time.monotonic()
    try:
        request = Request(target["url"], headers={"User-Agent": "Grobase-status/1"})
        with build_opener(NoRedirect()).open(request, timeout=timeout) as response:
            ok = response.status in target.get("expected_status", [200])
    except Exception:
        ok = False
    return int(ok), round((time.monotonic() - started) * 1000)


def sample(path, targets, timeout, retention, now=None):
    """Commit a full cycle atomically, then prune expired measurements."""
    rows = []
    for target in targets:
        ok, latency = probe(target, timeout)
        rows.append((target["name"], int(time.time()) if now is None else now, ok, latency))
    with database(path) as connection:
        connection.executemany("INSERT INTO samples VALUES (?, ?, ?, ?)", rows)
        connection.execute("DELETE FROM samples WHERE at < ?", (int(time.time()) - retention,))


def component(connection, name, now, stale, window):
    """Expose sampled availability and recent failed probes, not an SLA percentage."""
    rows = connection.execute("SELECT at, ok, latency FROM samples WHERE name=? AND at>=? ORDER BY at DESC", (name, now - window)).fetchall()
    latest = rows[0] if rows else None
    current = "unknown" if latest is None or not 0 <= now - latest[0] <= stale else ("operational" if latest[1] else "down")
    return {"name": name, "status": current, "last_checked": latest[0] if latest else None,
            "latency_ms": latest[2] if latest else None, "sample_count": len(rows),
            "successful_samples": sum(row[1] for row in rows),
            "failed_checks": [row[0] for row in rows if not row[1]][:50]}


def snapshot(path, targets, stale, window, now=None):
    """Read persisted measurements; unavailable storage must fail rather than look healthy."""
    now = int(time.time()) if now is None else now
    with database(path) as connection:
        components = [component(connection, target["name"], now, stale, window) for target in targets]
    statuses = [item["status"] for item in components]
    overall = "degraded" if "down" in statuses else ("unknown" if "unknown" in statuses else "operational")
    return {"status": overall, "generated_at": now, "window_seconds": window, "components": components}
