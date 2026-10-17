#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m49-orchestrator-cutover.sh                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M49 — orchestrator cutover: the 5 Node-orchestrator routes serve THROUGH KONG
# from the consolidated Go binary (Track-2 A4). Where m48 hits the orchestrator
# directly, this proves the live front door: Kong → orchestrator, with the Node
# services stopped. A 502 here = Kong cannot reach the upstream (the URL swap is
# wrong or the orchestrator isn't serving that sub-service). The gate is the
# green light AFTER the kong.yml flip + ORCHESTRATOR_SERVICES=all + Node stop.
#
# Kong exposes only the public paths of the orchestrator's gdpr and newsletter
# sub-services (G2 TM3, m229); the admin handlers (sessions/gdpr/newsletter
# admin) trust X-Baas-Role, which Kong clears, so through Kong they must answer
# CLOSED (404/401/403). Their admin coverage is m48's, directly on :3026.
# Newsletter subscribe is probed with an invalid body (400 from the
# orchestrator: routed, nothing sent). A real subscribe sends a confirmation
# mail, so it is opt-in (M49_NEWSLETTER_E2E=1) and refused unless the stack's
# SMTP_HOST is mailpit (M49_ALLOW_REAL_SMTP=1 overrides, TM10). Email takes
# only the service key (acl baas-admin, m206) and is probed with an empty body,
# so emailsvc's own 400 proves the route and no mail can leave.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M49] $*"; }
pass() { green "[M49] PASS: $*"; }
fail() {
  red "[M49] FAIL: $*"
  exit 1
}
skip() {
  printf '\033[1;33m[M49] SKIP: %s\033[0m\n' "$*"
  exit 0
}

docker inspect -f '{{.State.Running}}' mini-baas-orchestrator 2>/dev/null | grep -q true ||
  skip "orchestrator not running (this gate is post-flip)"

KONG_PORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://')"
[ -n "${KONG_PORT}" ] || skip "kong host port not found"
KONG="http://127.0.0.1:${KONG_PORT}"
ANON="$(docker inspect mini-baas-kong --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^KONG_PUBLIC_API_KEY=//p' | head -1)"
[ -n "${ANON}" ] || skip "anon api key not found"
SERVICE="$(docker inspect mini-baas-kong --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^KONG_SERVICE_API_KEY=//p' | head -1)"
[ -n "${SERVICE}" ] || skip "service api key not found"

# code <method> <path> [data] → HTTP status through Kong with the anon key,
# or with ${KEY} when the caller sets it
code() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "${data}" ]; then
    curl -s -o /tmp/m49.json -w '%{http_code}' -X "${method}" "${KONG}${path}" \
      -H "apikey: ${KEY:-${ANON}}" -H 'Content-Type: application/json' -d "${data}"
  else
    curl -s -o /tmp/m49.json -w '%{http_code}' -X "${method}" "${KONG}${path}" -H "apikey: ${KEY:-${ANON}}"
  fi
}

# ── 1) newsletter — routed through Kong, no mail by default ──────────────────
# stack_smtp_host prints the SMTP_HOST the running orchestrator was started with.
stack_smtp_host() {
  docker inspect mini-baas-orchestrator --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^SMTP_HOST=//p' | head -1
}

# refuse_real_smtp fails when a real-send leg would mail outside mailpit.
refuse_real_smtp() {
  local host
  host="$(stack_smtp_host)"
  [ "${host}" = mailpit ] || [ "${M49_ALLOW_REAL_SMTP:-}" = 1 ] ||
    fail "refusing a real-send leg: the stack's SMTP_HOST is '${host:-unset}', not mailpit (M49_ALLOW_REAL_SMTP=1 to allow)"
}

step "newsletter /newsletter/v1/subscribe through Kong → orchestrator (invalid body, nothing sent)"
C="$(code POST /newsletter/v1/subscribe '{"email":"not-an-email"}')"
[ "${C}" = "400" ] && grep -q 'valid email' /tmp/m49.json ||
  fail "newsletter subscribe with an invalid body got ${C} (want the orchestrator's 400): $(head -c 160 /tmp/m49.json)"
pass "newsletter routed through Kong to the orchestrator (400 on an invalid body, no mail)"
if [ "${M49_NEWSLETTER_E2E:-}" = 1 ]; then
  step "newsletter subscribe end-to-end (M49_NEWSLETTER_E2E=1, sends the confirmation mail)"
  refuse_real_smtp
  C="$(code POST /newsletter/v1/subscribe "{\"email\":\"m49-$(date +%s)@example.com\"}")"
  [ "${C}" = "201" ] && grep -q '"subscribed":true' /tmp/m49.json ||
    fail "newsletter subscribe through Kong got ${C} (want 201): $(head -c 160 /tmp/m49.json)"
  pass "newsletter served end-to-end by the orchestrator through Kong (201)"
fi

# ── 2) the rest — Kong reaches the orchestrator (NOT 502), admin stays closed ─
# The cutover question is only "does Kong route to a LIVE upstream" — a
# 502/503 means the swap is broken.
reaches() { # $1 label  $2 method  $3 path  [$4 data]
  local label="$1" method="$2" path="$3" data="${4:-}"
  local c
  c="$(code "${method}" "${path}" "${data}")"
  case "${c}" in
  502 | 503 | 504) fail "${label}: Kong got ${c} — upstream unreachable (URL swap wrong / sub-service not mounted)" ;;
  000) fail "${label}: no response from Kong" ;;
  *) pass "${label}: orchestrator reached through Kong (HTTP ${c}, not a gateway error)" ;;
  esac
}
# closed <label> <method> <path> asserts the anon key gets 404, 401 or 403.
closed() {
  local c
  c="$(code "$2" "$3")"
  case "${c}" in
  404 | 401 | 403) pass "$1: closed through Kong (HTTP ${c})" ;;
  *) fail "$1: want a closed answer (404/401/403) through Kong, got ${c}: $(head -c 160 /tmp/m49.json)" ;;
  esac
}
step "session /sessions/v1/admin/stats stays closed through Kong (X-Baas-Role is cleared)"
closed "session admin" GET /sessions/v1/admin/stats
step "gdpr /gdpr/v1/consents routes to the orchestrator (a user path: 401 without a verified JWT)"
reaches "gdpr" GET /gdpr/v1/consents
step "gdpr and newsletter admin paths are not routed through Kong"
closed "gdpr admin" GET /gdpr/v1/deletion-requests/admin
closed "newsletter admin" GET /newsletter/v1/admin/stats
closed "newsletter campaign send" POST /newsletter/v1/admin/campaigns/send
closed "gdpr cross-service send" POST /gdpr/v1/send
step "log /logs/v1/ingest routes to the orchestrator"
reaches "log" POST /logs/v1/ingest '{"level":"info","message":"m49 probe"}'
step "email /email/v1/send routes to the orchestrator (service key, empty body)"
C="$(KEY="${SERVICE}" code POST /email/v1/send '{}')"
[ "${C}" = "400" ] && grep -q 'to must be a valid email' /tmp/m49.json ||
  fail "email: want emailsvc's 400 for an empty body, got ${C}: $(head -c 160 /tmp/m49.json)"
pass "email: orchestrator's emailsvc answered through Kong (400 on an empty body, nothing sent)"

# ── 3) the Node services are actually stopped (the -262 MiB is realized) ──────
step "Node orchestrators are stopped (cost win realized)"
up=0
for c in log-service email-service session-service newsletter-service gdpr-service outbox-relay; do
  docker inspect -f '{{.State.Running}}' "mini-baas-${c}" 2>/dev/null | grep -q true && {
    red "  still running: mini-baas-${c}"
    up=$((up + 1))
  }
done
[ "${up}" = "0" ] || fail "${up} Node orchestrator(s) still running — the footprint win is not realized"
pass "all 6 Node orchestrators stopped — the orchestrator carries their traffic"

green "[M49] ALL GATES GREEN — Kong serves the 5 orchestrator routes from the Go binary; the Node six are retired from the running set"
