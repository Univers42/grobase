#!/usr/bin/env bash
# newsletter-broadcast.sh — server-side ops: send a newsletter campaign to every
# CONFIRMED subscriber, via the orchestrator's internal admin endpoint.
#
# The campaign-send endpoint requires a gateway-injected service_role identity
# (X-Baas-User-Id + X-Baas-Role). Kong STRIPS those forgeable headers from any
# external request by design, so a campaign cannot be triggered from the public
# gateway or a browser. This is the intended INTERNAL path: hit the orchestrator
# directly on its loopback-published port (127.0.0.1:3026), set the identity
# ourselves, and let it fan out over Titan SMTP + record newsletter.send_log.
#
# Usage: SUBJECT="…" HTML="<p>…</p>" [TEXT="…"] bash scripts/ops/newsletter-broadcast.sh
#   (or: make newsletter-broadcast SUBJECT="…" HTML="…")
set -euo pipefail

SUBJECT="${SUBJECT:-}"
HTML="${HTML:-}"
TEXT="${TEXT:-}"

die() {
	printf 'newsletter-broadcast: %s\n' "$*" >&2
	exit 1
}

[ -n "$SUBJECT" ] || die "SUBJECT= is required (the campaign subject line)"
[ -n "$HTML" ] || die "HTML= is required (the campaign body, HTML)"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v docker >/dev/null 2>&1 || die "docker is required"

port="$(docker port mini-baas-orchestrator 3026/tcp 2>/dev/null | head -1 | sed 's/.*://')"
port="${port:-3026}"
url="http://127.0.0.1:${port}/admin/campaigns/send"

confirmed="$(docker exec mini-baas-postgres psql -U postgres -d postgres -tAc \
	"select count(*) from newsletter.subscriber where confirmed_at is not null and unsubscribed_at is null;" \
	2>/dev/null | tr -d '[:space:]' || true)"
printf 'Broadcasting "%s" to %s confirmed subscriber(s) → %s\n' "$SUBJECT" "${confirmed:-?}" "$url"

body="$(jq -nc --arg s "$SUBJECT" --arg h "$HTML" --arg t "$TEXT" '{subject:$s, html:$h, text:$t}')"
resp="$(printf '%s' "$body" | curl -s -X POST "$url" \
	-H "X-Baas-User-Id: ops-broadcast" \
	-H "X-Baas-Role: service_role" \
	-H "Content-Type: application/json" --data-binary @-)"

sent="$(printf '%s' "$resp" | jq -r '.data.sent // .sent // "?"' 2>/dev/null || echo '?')"
failed="$(printf '%s' "$resp" | jq -r '.data.failed // .failed // "?"' 2>/dev/null || echo '?')"
if [ "$sent" = "?" ]; then
	die "unexpected response: $resp"
fi
printf 'Done — sent=%s failed=%s (delivered via Titan SMTP; recorded in newsletter.send_log)\n' "$sent" "$failed"
[ "$failed" = "0" ] || printf 'WARNING: %s send(s) failed — check: docker logs mini-baas-orchestrator\n' "$failed" >&2
