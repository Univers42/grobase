#!/usr/bin/env python3
"""Tiny OIDC issuer for the m41 gate (stdlib only).

Implements just enough of OpenID Connect to prove binocle-one's generic
authorization-code+PKCE flow end-to-end: the discovery document, /authorize
(302 back with a code; `login_hint` selects the mock user), /token (verifies
the S256 PKCE challenge — a wrong verifier is rejected), and /userinfo.
"""
import base64
import hashlib
import json
import os
import secrets
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

ISSUER = os.environ.get("ISSUER", "http://127.0.0.1:9460").rstrip("/")
PORT = int(os.environ.get("PORT", "9460"))
CODES = {}
TOKENS = {}


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        qs = dict(urllib.parse.parse_qsl(url.query))
        if url.path == "/.well-known/openid-configuration":
            return self._json(
                {
                    "issuer": ISSUER,
                    "authorization_endpoint": f"{ISSUER}/authorize",
                    "token_endpoint": f"{ISSUER}/token",
                    "userinfo_endpoint": f"{ISSUER}/userinfo",
                }
            )
        if url.path == "/authorize":
            email = qs.get("login_hint", "carol@idp.dev")
            code = secrets.token_hex(12)
            CODES[code] = {
                "sub": "mock-" + email.split("@")[0],
                "email": email,
                "challenge": qs.get("code_challenge", ""),
            }
            state = urllib.parse.quote(qs.get("state", ""))
            self.send_response(302)
            self.send_header("Location", f"{qs['redirect_uri']}?code={code}&state={state}")
            self.end_headers()
            return
        if url.path == "/userinfo":
            token = self.headers.get("Authorization", "").removeprefix("Bearer ")
            rec = TOKENS.get(token)
            if not rec:
                return self._json({"error": "invalid_token"}, 401)
            return self._json(
                {"sub": rec["sub"], "email": rec["email"], "email_verified": True}
            )
        return self._json({"error": "not_found"}, 404)

    def do_POST(self):
        if urllib.parse.urlparse(self.path).path != "/token":
            return self._json({"error": "not_found"}, 404)
        length = int(self.headers.get("Content-Length", "0"))
        form = dict(urllib.parse.parse_qsl(self.rfile.read(length).decode()))
        rec = CODES.pop(form.get("code", ""), None)
        if not rec:
            return self._json({"error": "invalid_grant"}, 400)
        expected = b64url(hashlib.sha256(form.get("code_verifier", "").encode()).digest())
        if rec["challenge"] and expected != rec["challenge"]:
            return self._json(
                {"error": "invalid_grant", "error_description": "pkce mismatch"}, 400
            )
        token = secrets.token_hex(12)
        TOKENS[token] = rec
        return self._json({"access_token": token, "token_type": "Bearer"})


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
