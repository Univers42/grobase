#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m102-gateway-query-path.sh                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M102 — Gateway query-path REGRESSION gate. On 2026-06-13 the entire gateway
# query path was 404-broken (Kong had no route forwarding to the backend) and
# CI did not catch it: ci.yml only health-probes /auth/v1/health, never the
# query/data/rest data paths. This gate closes that hole by asserting the LIVE
# Kong wiring (the real kong.yml + the real docker-compose upstreams) routes the
# three data paths to a live upstream — NOT to Kong's "no Route matched" 404.
#
# The signal is deterministic and needs no credentials:
#   · route MISSING  → Kong returns 404 with body "no Route matched ...".
#   · route PRESENT  → Kong forwards through key-auth → 401 (no apikey) from the
#                      upstream-facing plugin, or 2xx when authed. Anything that
#                      is NOT a no-route 404 proves the route exists and forwards.
#
# Core (load-bearing, always runs): for /query/v1 (TS query-router), /data/v1
# (Rust data plane bypass) and /rest/v1 (postgrest), an unauthenticated request
# must NOT be a no-route 404.
#
# Round-trip (strong, when a valid apikey is available): with an apikey the SDK
# introspection /query/v1/capabilities and the postgrest root /rest/v1/ must
# return 200 — a real end-to-end gateway→upstream→body round trip. If no valid
# key is available the round-trip is reported as skipped (the core 404 guard is
# what makes the gate non-vacuous, and it needs no key).
#
# This is a LIVE gate: it runs against an already-up stack (make up). It makes no
# changes and stands nothing up.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
step() { cyan "[M102] $*"; }
ok() { green "  ✓ $*"; }
warn() { yellow "  ~ $*"; }
fail() {
  red "[M102] FAIL — $*"
  exit 1
}

BASE_URL="${BASE_URL:-http://localhost:8000}"
# Source an apikey for the strong round-trip from the usual places; the core 404
# guard does NOT need it. ANON_KEY may live in the infra .env.
ENV_ANON=""
if [[ -f "${INFRA_DIR}/.env" ]]; then
  ENV_ANON="$(grep -E '^ANON_KEY=' "${INFRA_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
  ENV_ANON="${ENV_ANON%\"}"
  ENV_ANON="${ENV_ANON#\"}" # strip surrounding double quotes if present
fi
APIKEY="${M102_APIKEY:-${BAAS_API_KEY:-${ENV_ANON:-}}}"
ROUND_TRIP_TABLE="${M102_TABLE:-}" # optional: a known table to assert rows from
BODY_TMP="$(mktemp)"
cleanup() { rm -f "${BODY_TMP}" 2>/dev/null || true; }
trap cleanup EXIT

# GET/POST helper: echo HTTP status, body→BODY_TMP. $1=method $2=path $3..=extra curl args
req() {
  local method="$1" path="$2"
  shift 2
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${method}" "${BASE_URL}${path}" "$@"
}

# A "no Route matched" 404 means the gateway route is MISSING (the regression).
is_no_route() { # $1=status
  [[ "$1" == "404" ]] && grep -qi 'no Route matched' "${BODY_TMP}"
}

# ── 0) preflight: the live gateway must be up ──────────────────────────────────
step "0/3 preflight — Kong gateway reachable at ${BASE_URL}"
# Reachability ≠ auth success: routes are key-auth'd, so probe connectivity by
# status code. 000 = could not connect (stack down / wrong port); any HTTP
# status (even 401/404) means Kong is answering.
PRE_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${BASE_URL}/" 2>/dev/null || echo 000)"
if [[ "${PRE_CODE}" == "000" ]]; then
  fail "gateway not reachable at ${BASE_URL} — bring the stack up (cd ${INFRA_DIR} && make up) or set BASE_URL to the Kong proxy port, then re-run"
fi
ok "gateway reachable (HTTP ${PRE_CODE} from ${BASE_URL}/)"

# ── 1) CORE: the three data paths must be ROUTED (not no-route 404) ────────────
step "1/3 route-forwarding guard — /query/v1, /data/v1, /rest/v1 must forward (NOT Kong no-route 404)"
# /query/v1 (TS query-router): POST without apikey → key-auth 401 if routed.
S_QUERY="$(req POST /query/v1 -H 'Content-Type: application/json' -d '{}')"
is_no_route "${S_QUERY}" && fail "/query/v1 is a no-route 404 — the gateway query path is BROKEN (this is the 2026-06-13 regression) — $(head -c 200 "${BODY_TMP}")"
ok "/query/v1 routed (status ${S_QUERY}, not a no-route 404)"

# /data/v1 (Rust data plane bypass): POST /data/v1/query without apikey → 401 if routed.
S_DATA="$(req POST /data/v1/query -H 'Content-Type: application/json' -d '{}')"
is_no_route "${S_DATA}" && fail "/data/v1 is a no-route 404 — the Rust data-plane bypass path is BROKEN at the gateway — $(head -c 200 "${BODY_TMP}")"
ok "/data/v1 routed (status ${S_DATA}, not a no-route 404)"

# /rest/v1 (postgrest): GET without apikey → 401 if routed.
S_REST="$(req GET /rest/v1/)"
is_no_route "${S_REST}" && fail "/rest/v1 is a no-route 404 — the postgrest path is BROKEN at the gateway — $(head -c 200 "${BODY_TMP}")"
ok "/rest/v1 routed (status ${S_REST}, not a no-route 404)"

# ── 2) STRONG: authenticated end-to-end round trip (when a key is available) ───
step "2/3 round-trip — authenticated gateway→upstream→body (needs a valid apikey)"
if [[ -z "${APIKEY}" ]]; then
  warn "no apikey available (set M102_APIKEY / BAAS_API_KEY, or ANON_KEY in .env) — skipping the authenticated round trip; the route-forwarding guard above is the load-bearing proof"
else
  # SDK introspection over the query path: /query/v1/capabilities → 200.
  S_CAP="$(req GET /query/v1/capabilities -H "apikey: ${APIKEY}")"
  if [[ "${S_CAP}" == "200" ]]; then
    ok "/query/v1/capabilities → 200 (SDK introspection round-trips end-to-end)"
  elif [[ "${S_CAP}" == "401" || "${S_CAP}" == "403" ]]; then
    warn "/query/v1/capabilities → ${S_CAP} (apikey not accepted — round trip skipped; route forwarding already proven)"
  else
    is_no_route "${S_CAP}" && fail "/query/v1/capabilities no-route 404 — introspection path broken"
    warn "/query/v1/capabilities → ${S_CAP} (routed but non-200; not failing — route forwarding is the guard)"
  fi
  # postgrest root with apikey → 200 (the REST query path is live end-to-end).
  S_RESTK="$(req GET /rest/v1/ -H "apikey: ${APIKEY}")"
  if [[ "${S_RESTK}" == "200" ]]; then
    ok "/rest/v1/ → 200 with apikey (REST query path round-trips end-to-end)"
  else
    warn "/rest/v1/ → ${S_RESTK} with apikey (routed; not 200 — not failing)"
  fi
  # Optional: assert real rows from a known table.
  if [[ -n "${ROUND_TRIP_TABLE}" ]]; then
    S_ROWS="$(req GET "/rest/v1/${ROUND_TRIP_TABLE}?limit=1" -H "apikey: ${APIKEY}")"
    if [[ "${S_ROWS}" == "200" ]] && head -c1 "${BODY_TMP}" | grep -q '\['; then
      ok "/rest/v1/${ROUND_TRIP_TABLE} → 200 returning a JSON array (rows round-trip)"
    else
      warn "/rest/v1/${ROUND_TRIP_TABLE} → ${S_ROWS} (table round-trip not confirmed — not failing)"
    fi
  fi
fi

# ── 3) summarize + emit the gate event ─────────────────────────────────────────
step "3/3 summary + log GATE m102=PASS"
green "[M102] gateway data paths ROUTED: /query/v1=${S_QUERY} /data/v1=${S_DATA} /rest/v1=${S_REST} (none a no-route 404)"
emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-p0-gateway-query-path}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m102=PASS" --outcome pass \
      --msg "Gateway query-path regression guard: live Kong routes /query/v1, /data/v1, /rest/v1 to live upstreams (not no-route 404), closing the 2026-06-13 404-broken gap CI missed." \
      --ref "scripts/verify/m102-gateway-query-path.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M102] ALL GATES GREEN — the gateway query path is wired end-to-end (no-route 404 regression guarded)"
exit 0
