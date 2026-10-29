# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    http-conformance-upstream.py                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/30 02:30:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 03:20:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
"""REST upstream the http engine's conformance run talks to (m27, G3).

Speaks the wire format the Rust http adapter emits (data-plane-pool/src/http):
GET/POST /<res>, GET/PATCH/PUT/DELETE /<res>/<id>, rows partitioned by the
X-Owner-Id header the adapter derives from the verified identity. A missing id
answers 404, as a real REST API does.

Caveat: a list filter is honoured only as equality — a plain value or the
adapter's JSON-encoded {"$eq": v}; any other operator answers 400. `sort` is
ignored (the battery gives passthrough engines no sort check). In-memory,
single-threaded: state dies with the container, which is the point.
"""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qsl, unquote, urlsplit

ROWS = {}  # (owner, resource) -> {id: row}
CONTROL_PARAMS = {"limit", "offset", "sort"}


def equality_value(raw):
    try:
        parsed = json.loads(raw)
    except ValueError:
        return raw
    if isinstance(parsed, dict):
        if set(parsed) != {"$eq"}:
            raise ValueError(f"unsupported filter operator {sorted(parsed)}")
        return parsed["$eq"]
    return parsed


def matches(row, filters):
    return all(str(row.get(k)) == str(v) for k, v in filters.items())


class Upstream(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, body=None):
        payload = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        # A REST upstream echoes the row it stored; the reader is the Rust http
        # adapter, never a browser.
        self.wfile.write(payload)  # NOSONAR(S5131) JSON to the adapter only, grobase#67

    def target(self):
        url = urlsplit(self.path)
        parts = [unquote(p) for p in url.path.strip("/").split("/") if p]
        owner = self.headers.get("X-Owner-Id", "")
        table = ROWS.setdefault((owner, parts[0] if parts else ""), {})
        return table, (parts[1] if len(parts) > 1 else None), url.query

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        table, key, query = self.target()
        if key is not None:
            return self.reply(200, table[key]) if key in table else self.reply(404, {"error": "not found"})
        params = dict(parse_qsl(query))
        try:
            filters = {k: equality_value(v) for k, v in params.items() if k not in CONTROL_PARAMS}
        except ValueError as err:
            return self.reply(400, {"error": str(err)})
        rows = [r for r in table.values() if matches(r, filters)]
        offset = int(params.get("offset", 0))
        limit = int(params.get("limit", len(rows)))
        self.reply(200, rows[offset:offset + limit])

    def do_POST(self):
        table, _, _ = self.target()
        row = self.body()
        key = str(row.get("id"))
        if key in table:
            return self.reply(409, {"error": "duplicate id"})
        table[key] = row
        self.reply(201, row)

    def do_PATCH(self):
        table, key, _ = self.target()
        if key not in table:
            return self.reply(404, {"error": "not found"})
        table[key].update(self.body())
        self.reply(200, table[key])

    def do_PUT(self):
        table, key, _ = self.target()
        table[key] = {**self.body(), "id": key}
        self.reply(200, table[key])

    def do_DELETE(self):
        table, key, _ = self.target()
        if table.pop(key, None) is None:
            return self.reply(404, {"error": "not found"})
        self.reply(204)


if __name__ == "__main__":
    # Plain HTTP: the http adapter trusts only system roots (TLS: grobase#67).
    HTTPServer(("0.0.0.0", 8080), Upstream).serve_forever()  # NOSONAR(S5332)
