#!/usr/bin/env bash
# ============================================================
# m156 — GoTrue password-reset is not a user-enumeration oracle
#
# Before: /auth/v1/recover 500'd for a real user (SMTP send to the missing
# mailpit:1025 failed) but 200'd for an unknown one — a status differential
# that enumerates registered emails. Fix: bundle the mailpit SMTP sink
# (orchestrators/compose/base/auth-api.yml) so recovery mail "sends" and
# /recover returns 200 regardless of whether the email exists.
#
# This gate asserts the two responses are IDENTICAL (no oracle). Requires the
# stack up with the mailpit service (`docker compose up -d mailpit`).
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANON="$(grep -E '^ANON_KEY=' "$ROOT/.env" | cut -d= -f2)"
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000)"
GW="http://localhost:${KPORT:-8000}"
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

rec() { # email -> http status of /recover
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$GW/auth/v1/recover" \
    -H "apikey: $ANON" -H 'Content-Type: application/json' -d "{\"email\":\"$1\"}"
}

printf '\n\033[1mm156 — GoTrue /recover anti-enumeration\033[0m  (%s)\n' "$GW"

docker ps --format '{{.Names}}' | grep -q '^mini-baas-mailpit$' \
  || fail "mini-baas-mailpit not running — the SMTP sink is the fix (docker compose up -d mailpit)"
ok "mailpit SMTP sink is up"

EXIST="sophie.laurent@savanna-zoo.com"   # a known seeded user
BOGUS="enum-probe-$(date +%s 2>/dev/null || echo x)@nowhere.invalid"
# The invariant is "same response whether or not the email exists, and never the
# old 500". 200 is the healthy value; a transient shared 429 (rate-limit, which
# is per-IP and email-agnostic) still satisfies anti-enumeration. The bug was a
# 500-for-existing / 200-for-unknown split — that exact split must be gone.
C_EXIST=$(rec "$EXIST")
C_BOGUS=$(rec "$BOGUS")
[ "$C_EXIST" != "500" ] || fail "recover(existing) still 500 — SMTP send failing (mailpit unreachable?)"
[ "$C_EXIST" = "$C_BOGUS" ] || fail "ENUMERATION: existing=$C_EXIST vs bogus=$C_BOGUS differ (oracle)"
if [ "$C_EXIST" = "200" ]; then
  ok "recover(existing)=200 == recover(bogus)=200 — mail sent, no oracle"
else
  ok "recover(existing)=$C_EXIST == recover(bogus)=$C_BOGUS (email-agnostic) — no 500 oracle"
fi

printf '\n\033[1;32mm156 PASS — /recover gives an identical response for known and unknown emails\033[0m\n'
