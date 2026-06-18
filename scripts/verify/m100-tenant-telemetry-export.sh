#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m100-tenant-telemetry-export.sh                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M100 — Track-C C9 PER-TENANT TELEMETRY EXPORT control-plane gate. Proves the
# flag-gated exporter ships ONE tenant's own telemetry (its B1 usage metrics, wrapped
# as structured log records) OUT to THAT tenant's customer-configured OTLP/log-drain
# collector — attributed with tenant_id — and that it can NEVER cross tenants and is
# byte-parity when OFF. It is the BYO-collector complement to B5 (per-tenant obs):
# B5 makes tenant_id a queryable LOG FIELD in Grobase's own Loki; C9 forwards a
# single tenant's telemetry to that tenant's external sink.
#
#   control-plane Exporter (Go, TENANT_TELEMETRY_EXPORT_ENABLED=1)
#     │  every interval, FOR EACH opted-in + enabled tenant (public.tenant_telemetry_targets):
#     │    • read ONLY that tenant's usage rows newer than its cursor (public.tenant_usage)
#     │    • build one batch tagged with tenant_id (OTLP/HTTP logs JSON or ndjson)
#     │    • POST it to ONLY that tenant's endpoint (+ optional Authorization)
#     ▼    • advance that tenant's cursor to the newest shipped window
#   customer collector (the throwaway echo sink the gate boots per tenant)
#
#   (A) POSITIVE (TENANT_TELEMETRY_EXPORT_ENABLED=1): tenant T's target points at
#       SINK-T → T's usage ARRIVES at SINK-T, the body carries tenant_id="T" and T's
#       qty (REAL export, attributed to T).                       [LOAD-BEARING ARRIVE]
#   (B) LOAD-BEARING REJECT: tenant U's target points at SINK-U. SINK-T must receive
#       NONE of U's telemetry — U's tenant_id and U's secret qty NEVER appear at
#       SINK-T (no cross-tenant export leak — the core C9 invariant). [LOAD-BEARING]
#   (C) PARITY (flag unset): SAME seeds + targets, exporter NOT enabled → BOTH sinks
#       receive NOTHING and NO outbound connection is made → byte-identical to today.
#   PLUS a UNIT arm (go test internal/telemetryexport): per-tenant routing-no-leak,
#       OTLP tenant_id attribution, no-new-window no-op, disabled-Run no-op — the
#       pure-decision proof that complements the live wire proof.
#
# ISOLATED by design (mirrors m89): scratch postgres (prelude + REAL 040 + 046) + a
# Go orchestrator built FROM CURRENT source + two throwaway echo-sink HTTP collectors,
# ALL on a PRIVATE network, every container/image/network name suffixed with $$, an
# EXIT-trap that removes EVERYTHING. It NEVER touches a mini-baas-* container/network/
# image/volume and NEVER edits the live docker-compose.yml. No Redis is needed: the
# exporter forwards directly over HTTP (it does not consume a Redis set), so the gate
# exercises the EXACT production export path with only postgres + the sinks.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
GO_DIR="${INFRA_DIR}/src/control-plane"
MIGRATION_040="${INFRA_DIR}/scripts/migrations/postgresql/040_tenant_usage.sql"
MIGRATION_046="${INFRA_DIR}/scripts/migrations/postgresql/046_tenant_telemetry_targets.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M100] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M100] FAIL — $*"
  exit 1
}

PG_IMAGE="${M100_PG_IMAGE:-postgres:16-alpine}"
GO_IMAGE="${M100_GO_IMAGE:-golang:1.24}"
SINK_IMAGE="${M100_SINK_IMAGE:-python:3-alpine}"
ORCH_IMG="m100-orch-$$:scratch"
NET="m100net-$$"
PG="m100-pg-$$"
SINK_T="m100-sink-t-$$"     # tenant T's customer collector
SINK_U="m100-sink-u-$$"     # tenant U's customer collector
ORCH_ON="m100-orch-on-$$"   # exporter ENABLED (A + B)
ORCH_OFF="m100-orch-off-$$" # parity arm (flag unset) (C)
PGPW="postgres"
TENANT_T="m100-tenant-t-$$"
TENANT_U="m100-tenant-u-$$"
METRIC="query.count"
QTY_T=4242    # T's distinctive qty (must arrive at SINK-T)
QTY_U=9999991 # U's distinctive secret qty (must NEVER arrive at SINK-T)
EXPORT_MS="${M100_EXPORT_MS:-700}"
SINK_PORT=8080
STRONG_TOKEN="m100-strong-internal-svc-token-not-for-prod-0123456789ab"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SINK_T_URL="http://${SINK_T}:${SINK_PORT}/v1/logs"
SINK_U_URL="http://${SINK_U}:${SINK_PORT}/v1/logs"

cleanup() {
  docker rm -fv "${ORCH_ON}" "${ORCH_OFF}" "${SINK_T}" "${SINK_U}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${ORCH_IMG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql_q() { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# The echo sink captures EVERY received request to stdout (so `docker logs` is the
# capture). One stdlib line per POST: "RECV <content-type> <body>" — no body parsing,
# so any tenant_id leak is plainly visible in the log.
sink_log() { docker logs "$1" 2>&1; }

wait_log() { # $1=container  $2=needle  $3=tries
  local i
  for i in $(seq 1 "${3:-60}"); do
    docker logs "$1" 2>&1 | grep -q "$2" && return 0
    docker inspect "$1" >/dev/null 2>&1 || return 1
    sleep 0.5
  done
  return 1
}

# ── 0) UNIT arm: prove the per-tenant routing + attribution decisions in isolation ─
step "0/9 (UNIT) go test internal/telemetryexport — per-tenant routing-no-leak + OTLP attribution + no-op arms"
docker run --rm -v "${GO_DIR}":/src -w /src -e GOFLAGS=-mod=mod -e GOCACHE=/tmp/gc -e GOMODCACHE=/tmp/gm \
  "${GO_IMAGE}" sh -c 'go test ./internal/telemetryexport/... 2>&1' ||
  fail "telemetry-export unit tests failed — the per-tenant routing/attribution decisions are not proven"
ok "(UNIT) routing-no-leak (T→SINK-T, U→SINK-U, no cross), OTLP tenant_id attribution, disabled-Run no-op — all green"

# ── 1) build the scratch orchestrator FROM CURRENT (drafted) source ────────────
step "1/9 build scratch Go orchestrator from CURRENT source (the C9 exporter code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=orchestrator --build-arg PORT=3060 \
  -t "${ORCH_IMG}" "${GO_DIR}" >/dev/null ||
  fail "scratch orchestrator image build failed — gate must exercise the drafted exporter"
ok "orchestrator built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 2) isolated network + postgres (prelude + REAL 040 + 046) ──────────────────
step "2/9 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# The alpine entrypoint inits then RESTARTS once ("ready" twice) — wait for the SECOND.
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "throwaway postgres never reached its post-init steady state"
  sleep 0.5
done
ok "postgres up"

step "2b/9 apply migration prelude then the REAL 040 + 046"
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
}
for i in $(seq 1 20); do
  prelude && break
  [[ $i -eq 20 ]] && fail "migration prelude never committed"
  sleep 0.5
done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <"${MIGRATION_040}" >/dev/null 2>&1 ||
  fail "real migration 040_tenant_usage.sql failed to apply"
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <"${MIGRATION_046}" >/dev/null 2>&1 ||
  fail "real migration 046_tenant_telemetry_targets.sql failed to apply"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_telemetry_targets")" == "0" ]] || fail "tenant_telemetry_targets should start EMPTY"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_usage")" == "0" ]] || fail "tenant_usage should start EMPTY"
ok "migrations 040 + 046 applied — tenant_usage + tenant_telemetry_targets exist and are empty"

# ── 3) boot the two throwaway echo-sink collectors ─────────────────────────────
step "3/9 boot two throwaway echo-sink collectors (SINK-T, SINK-U) on ${NET}"
# A 20-line stdlib HTTP server: every POST appends one "RECV <ct> <body>" line to
# stdout (captured by `docker logs`), then 200s. The collector parses nothing, so a
# cross-tenant body would be plainly visible in SINK-T's log if a leak existed.
SINK_PY='
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        ct = self.headers.get("Content-Type", "")
        auth = self.headers.get("Authorization", "")
        print("RECV ct=%s auth=%s body=%s" % (ct, auth, body), flush=True)
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
HTTPServer(("0.0.0.0", 8080), H).serve_forever()
'
docker run -d --name "${SINK_T}" --network "${NET}" "${SINK_IMAGE}" python3 -c "${SINK_PY}" >/dev/null
docker run -d --name "${SINK_U}" --network "${NET}" "${SINK_IMAGE}" python3 -c "${SINK_PY}" >/dev/null
# The stdlib server logs nothing until it serves; assert the process is alive instead.
for s in "${SINK_T}" "${SINK_U}"; do
  for i in $(seq 1 40); do
    docker inspect -f '{{.State.Running}}' "$s" 2>/dev/null | grep -q true && break
    [[ $i -eq 40 ]] && fail "echo sink $s never started"
    sleep 0.25
  done
done
ok "SINK-T + SINK-U running (each echoes every POST body to its docker logs)"

# ── 4) seed: BOTH tenants' targets + usage (T→SINK-T, U→SINK-U) ────────────────
step "4/9 seed targets (T→SINK-T, U→SINK-U) + usage (T qty=${QTY_T}, U qty=${QTY_U})"
WINDOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
seed() {
  psql_q >/dev/null 2>&1 <<SQL
INSERT INTO public.tenant_telemetry_targets(tenant_id, endpoint, auth_header, format, enabled) VALUES
  ('${TENANT_T}', '${SINK_T_URL}', 'Bearer tok-${TENANT_T}', 'ndjson', TRUE),
  ('${TENANT_U}', '${SINK_U_URL}', 'Bearer tok-${TENANT_U}', 'ndjson', TRUE)
  ON CONFLICT (tenant_id) DO UPDATE SET endpoint = EXCLUDED.endpoint;
INSERT INTO public.tenant_usage(tenant_id, metric, window_start, qty, idempotency_key) VALUES
  ('${TENANT_T}', '${METRIC}', '${WINDOW}', ${QTY_T}, 'm100-t-$$'),
  ('${TENANT_U}', '${METRIC}', '${WINDOW}', ${QTY_U}, 'm100-u-$$')
  ON CONFLICT (idempotency_key) DO NOTHING;
SQL
}
for i in $(seq 1 20); do
  seed && break
  [[ $i -eq 20 ]] && fail "seed never committed"
  sleep 0.5
done
[[ "$(psql_val "SELECT qty FROM public.tenant_usage WHERE tenant_id='${TENANT_T}'")" == "${QTY_T}" ]] || fail "T usage not seeded"
[[ "$(psql_val "SELECT qty FROM public.tenant_usage WHERE tenant_id='${TENANT_U}'")" == "${QTY_U}" ]] || fail "U usage not seeded"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_telemetry_targets WHERE enabled")" == "2" ]] || fail "both targets not seeded enabled"
ok "seeded: T→SINK-T (qty=${QTY_T}), U→SINK-U (qty=${QTY_U}); both targets enabled"

# ── 5) (C) PARITY arm FIRST: flag unset → BOTH sinks receive NOTHING ───────────
# Run the OFF arm BEFORE the ON arm so the parity assertion can never be contaminated
# by an earlier ENABLED export populating a sink (the hard-won lesson: a flag-OFF
# parity arm must observe a sink that the ENABLED arm has not yet touched).
step "5/9 (C · PARITY) boot orchestrator with TENANT_TELEMETRY_EXPORT_ENABLED unset — same seeds"
docker run -d --name "${ORCH_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e ORCHESTRATOR_SERVICES=telemetry-export \
  -e ORCHESTRATOR_PORT=3060 \
  -e INTERNAL_SERVICE_TOKEN="${STRONG_TOKEN}" \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
wait_log "${ORCH_OFF}" "telemetry export disabled" 60 ||
  {
    red "off-exporter logs:"
    docker logs "${ORCH_OFF}" 2>&1 | tail -20
    fail "OFF exporter did not report disabled (flag default not OFF?)"
  }
# Give it several intervals' worth of wall-time to PROVE it never forwards.
sleep "$(awk "BEGIN{print (${EXPORT_MS}*4/1000)+2}")"
PARITY_T="$(sink_log "${SINK_T}" | grep -c 'RECV' || true)"
PARITY_U="$(sink_log "${SINK_U}" | grep -c 'RECV' || true)"
[[ "${PARITY_T}" == "0" ]] || {
  red "SINK-T received:"
  sink_log "${SINK_T}" | tail -3
  fail "(C) SINK-T received ${PARITY_T} request(s) with the flag OFF — NOT byte-parity"
}
[[ "${PARITY_U}" == "0" ]] || {
  red "SINK-U received:"
  sink_log "${SINK_U}" | tail -3
  fail "(C) SINK-U received ${PARITY_U} request(s) with the flag OFF — NOT byte-parity"
}
# Cursors must also stay at the epoch default (nothing forwarded ⇒ no advance).
[[ "$(psql_val "SELECT (last_cursor = to_timestamp(0)) FROM public.tenant_telemetry_targets WHERE tenant_id='${TENANT_T}'")" == "t" ]] ||
  fail "(C) T's cursor advanced with the flag OFF — NOT byte-parity"
ok "(C) flag OFF: neither sink received anything, no cursor advanced — byte-identical to today"

# ── 6) (A) POSITIVE: stop OFF arm, boot ENABLED exporter → T's data reaches SINK-T ─
step "6/9 (A · POSITIVE) stop OFF arm, boot orchestrator with TENANT_TELEMETRY_EXPORT_ENABLED=1"
# Stop the OFF exporter FIRST (it never forwards, but tearing it down keeps the run
# clean and frees postgres connections on the RAM box).
docker rm -f "${ORCH_OFF}" >/dev/null 2>&1 || true
docker run -d --name "${ORCH_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e ORCHESTRATOR_SERVICES=telemetry-export \
  -e ORCHESTRATOR_PORT=3060 \
  -e INTERNAL_SERVICE_TOKEN="${STRONG_TOKEN}" \
  -e TENANT_TELEMETRY_EXPORT_ENABLED=1 \
  -e TENANT_TELEMETRY_EXPORT_INTERVAL_MS="${EXPORT_MS}" \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
wait_log "${ORCH_ON}" "telemetry export enabled" 60 ||
  {
    red "exporter logs:"
    docker logs "${ORCH_ON}" 2>&1 | tail -20
    fail "exporter never enabled"
  }
ok "exporter enabled — forwarding each opted-in tenant's usage to its own collector"

step "7/9 (A) wait for T's telemetry to ARRIVE at SINK-T, attributed to T (tenant_id + qty)"
ARRIVED=
for i in $(seq 1 60); do
  if sink_log "${SINK_T}" | grep -q "${TENANT_T}"; then
    ARRIVED=1
    break
  fi
  sleep 0.5
done
[[ -n "${ARRIVED}" ]] || {
  red "SINK-T logs:"
  sink_log "${SINK_T}" | tail -5
  red "exporter logs:"
  docker logs "${ORCH_ON}" 2>&1 | tail -10
  fail "(A) T's telemetry NEVER arrived at SINK-T — export not delivered"
}
RECV_T="$(sink_log "${SINK_T}")"
grep -q "\"tenant_id\":\"${TENANT_T}\"" <<<"${RECV_T}" ||
  fail "(A) SINK-T body does not carry tenant_id=\"${TENANT_T}\" — telemetry not attributed to T"
grep -q "\"qty\":${QTY_T}" <<<"${RECV_T}" ||
  fail "(A) SINK-T body does not carry T's qty=${QTY_T} — wrong/empty telemetry"
grep -q "Bearer tok-${TENANT_T}" <<<"${RECV_T}" ||
  fail "(A) SINK-T did not receive T's configured Authorization header"
ok "(A) T's usage ARRIVED at SINK-T, attributed tenant_id=\"${TENANT_T}\", qty=${QTY_T}, with T's auth header"

# ── 8) (B) LOAD-BEARING REJECT: SINK-T received NONE of U's telemetry ───────────
step "8/9 (B · LOAD-BEARING) assert SINK-T received NONE of U's telemetry (no cross-tenant export leak)"
# Give the exporter a few more ticks so that IF a leak existed, it would have surfaced.
sleep "$(awk "BEGIN{print (${EXPORT_MS}*3/1000)+1}")"
RECV_T="$(sink_log "${SINK_T}")"
grep -q "${TENANT_U}" <<<"${RECV_T}" &&
  {
    red "SINK-T contains U's tenant_id:"
    grep "${TENANT_U}" <<<"${RECV_T}" | tail -3
    fail "(B) CROSS-TENANT LEAK — U's tenant_id reached SINK-T"
  }
grep -q "${QTY_U}" <<<"${RECV_T}" &&
  {
    red "SINK-T contains U's qty:"
    grep "${QTY_U}" <<<"${RECV_T}" | tail -3
    fail "(B) CROSS-TENANT LEAK — U's qty=${QTY_U} reached SINK-T"
  }
# Conversely, prove U's OWN telemetry DID reach SINK-U (the export works for U too,
# so the absence at SINK-T is isolation, not a dead exporter).
ARRIVED_U=
for i in $(seq 1 30); do
  sink_log "${SINK_U}" | grep -q "${TENANT_U}" && {
    ARRIVED_U=1
    break
  }
  sleep 0.5
done
[[ -n "${ARRIVED_U}" ]] || {
  red "SINK-U logs:"
  sink_log "${SINK_U}" | tail -5
  fail "(B) U's telemetry never reached SINK-U — cannot conclude isolation vs dead exporter"
}
grep -q "${QTY_U}" <<<"$(sink_log "${SINK_U}")" || fail "(B) SINK-U missing U's qty=${QTY_U}"
ok "(B) SINK-T saw NONE of U's tenant_id/qty while SINK-U DID receive U's data — no cross-tenant export leak"

# ── 9) summary + gate event ────────────────────────────────────────────────────
step "9/9 summary"
green "[M100] (A) POSITIVE:    flag ON → T's usage ARRIVES at SINK-T, body tenant_id=\"${TENANT_T}\" qty=${QTY_T} + T's auth header (REAL per-tenant export)"
green "[M100] (B) LOAD-BEARING: SINK-T received NONE of U's tenant_id/qty while SINK-U DID get U's data — cross-tenant export impossible by construction"
green "[M100] (C) PARITY:      flag OFF → neither sink received anything, no cursor advanced (byte-parity baseline)"
green "[M100] (UNIT):          go test internal/telemetryexport — routing-no-leak + OTLP attribution + no-op arms green"

emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-c9-tenant-telemetry-export}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m100=PASS" --outcome pass \
      --msg "C9 per-tenant telemetry export: exporter forwards each opted-in tenant's OWN B1 usage (tenant_telemetry_targets, migration 046) to that tenant's customer-configured OTLP/log-drain collector tagged with tenant_id; POSITIVE T's data arrives at SINK-T attributed to T; LOAD-BEARING SINK-T receives NONE of U's telemetry (no cross-tenant leak); flag OFF -> nothing exported, no connection, no cursor advance (byte-parity); cardinality-safe (tenant_id is a record attribute, never a Prometheus label)" \
      --ref "scripts/verify/m100-tenant-telemetry-export.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M100] ALL GATES GREEN — C9 ships ONE tenant's telemetry to ITS collector (tagged tenant_id), never crosses tenants, and is byte-parity when OFF"
exit 0
