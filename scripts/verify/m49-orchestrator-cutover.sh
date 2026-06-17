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
# Auth: the public newsletter subscribe is the end-to-end proof (Kong key-auth
# anon → orchestrator → 201 envelope). The other four are routing proofs — the
# orchestrator MUST respond (any non-502), confirming Kong now reaches it, not a
# dead Node container.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M49] $*"; }
pass()  { green "[M49] PASS: $*"; }
fail()  { red "[M49] FAIL: $*"; exit 1; }
skip()  { printf '\033[1;33m[M49] SKIP: %s\033[0m\n' "$*"; exit 0; }

docker inspect -f '{{.State.Running}}' mini-baas-orchestrator 2>/dev/null | grep -q true \
  || skip "orchestrator not running (this gate is post-flip)"

KONG_PORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://')"
[ -n "${KONG_PORT}" ] || skip "kong host port not found"
KONG="http://127.0.0.1:${KONG_PORT}"
ANON="$(docker inspect mini-baas-kong --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^KONG_PUBLIC_API_KEY=//p' | head -1)"
[ -n "${ANON}" ] || skip "anon api key not found"

# code <method> <path> [data] → HTTP status through Kong with the anon key
code() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "${data}" ]; then
    curl -s -o /tmp/m49.json -w '%{http_code}' -X "${method}" "${KONG}${path}" \
      -H "apikey: ${ANON}" -H 'Content-Type: application/json' -d "${data}"
  else
    curl -s -o /tmp/m49.json -w '%{http_code}' -X "${method}" "${KONG}${path}" -H "apikey: ${ANON}"
  fi
}

# ── 1) newsletter — end-to-end through Kong (public subscribe) ────────────────
step "newsletter /newsletter/v1/subscribe through Kong → orchestrator"
C="$(code POST /newsletter/v1/subscribe "{\"email\":\"m49-$(date +%s)@example.com\"}")"
[ "${C}" = "201" ] || fail "newsletter subscribe through Kong got ${C} (want 201): $(head -c 160 /tmp/m49.json)"
grep -q '"subscribed":true' /tmp/m49.json || fail "newsletter response not the orchestrator's: $(head -c 160 /tmp/m49.json)"
pass "newsletter served end-to-end by the orchestrator through Kong (201)"

# ── 2) the other four — Kong reaches the orchestrator (NOT 502) ───────────────
# These need user/service auth for a 2xx, but the cutover question is only
# "does Kong route to a LIVE upstream" — a 502/503 means the swap is broken.
reaches() { # $1 label  $2 method  $3 path  [$4 data]
  local label="$1" method="$2" path="$3" data="${4:-}"
  local c; c="$(code "${method}" "${path}" "${data}")"
  case "${c}" in
    502|503|504) fail "${label}: Kong got ${c} — upstream unreachable (URL swap wrong / sub-service not mounted)";;
    000)         fail "${label}: no response from Kong";;
    *)           pass "${label}: orchestrator reached through Kong (HTTP ${c}, not a gateway error)";;
  esac
}
step "session /sessions/v1/admin/stats routes to the orchestrator"
reaches "session" GET /sessions/v1/admin/stats
step "gdpr /gdpr/v1/consents routes to the orchestrator"
reaches "gdpr" GET /gdpr/v1/consents
step "log /logs/v1/ingest routes to the orchestrator"
reaches "log" POST /logs/v1/ingest '{"level":"info","message":"m49 probe"}'
step "email /email/v1/send routes to the orchestrator"
reaches "email" POST /email/v1/send '{"to":"x@example.com","subject":"m49","body":"probe"}'

# ── 3) the Node services are actually stopped (the -262 MiB is realized) ──────
step "Node orchestrators are stopped (cost win realized)"
up=0
for c in log-service email-service session-service newsletter-service gdpr-service outbox-relay; do
  docker inspect -f '{{.State.Running}}' "mini-baas-${c}" 2>/dev/null | grep -q true && { red "  still running: mini-baas-${c}"; up=$((up+1)); }
done
[ "${up}" = "0" ] || fail "${up} Node orchestrator(s) still running — the footprint win is not realized"
pass "all 6 Node orchestrators stopped — the orchestrator carries their traffic"

green "[M49] ALL GATES GREEN — Kong serves the 5 orchestrator routes from the Go binary; the Node six are retired from the running set"
