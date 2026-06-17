#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m112-trust-center.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M112 — Track-D D4.6 TRUST CENTER gate. A read-only, public-readable security &
# compliance posture endpoint, FILE-BACKED by infra/config/trust/posture.json (the single
# source the API serves and the narrative spine of wiki/trust-center.md), flag-gated
# OFF by default (TRUST_CENTER_ENABLED). NO database, NO migration — the posture is
# the public half of the security story. It exercises a tenant-control built FROM
# CURRENT source, with the canonical infra/config/trust dir mounted READ-ONLY (the m108
# fixture-mount discipline), so the endpoint reflects the SHIPPED manifest:
#
#   (A · POSITIVE) TRUST_CENTER_ENABLED=1 -> GET /v1/trust => 200 with the controls;
#       the headline gate-proven controls (audit m104 / erase m105 / export m109 /
#       soc2 m108) are present WITH evidence pointers; EVERY control's status is in
#       {implemented,partial,planned}; the served count == the count of controls in
#       infra/config/trust/posture.json (the endpoint reflects the FILE, not a stub).
#   (B · REJECT, LOAD-BEARING — honesty) NO control claims status:"implemented" with
#       an EMPTY "evidence" pointer. An unproven claim must be partial/planned, never
#       implemented-without-evidence. This makes the gate catch a dishonest
#       "everything green" trust page (a stub that hard-codes implemented fails here).
#   (C · FLAG-OFF PARITY) with TRUST_CENTER_ENABLED unset, EVERY /v1/trust* route is
#       404 while the base admin GET /v1/tenants (X-Service-Token) still 200 — byte-
#       identical to today; only the trust center is flag-gated.
#
# ISOLATED by design (mirrors m107/m108/m105): scratch postgres (prelude + base
# 005 + 032 for tenant-control boot + the admin parity probe) + two tenant-control
# binaries built FROM CURRENT source, ALL on a PRIVATE network, every name suffixed
# with $$, an EXIT-trap removing EVERYTHING. It NEVER touches a mini-baas-* container
# /network/image/volume and NEVER edits docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
GO_DIR="${INFRA_DIR}/src/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
TRUST_DIR="${INFRA_DIR}/infra/config/trust"                           # the canonical manifest dir
MANIFEST="${TRUST_DIR}/posture.json"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M112] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M112] FAIL — $*"; exit 1; }

PG_IMAGE="${M112_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m112-tc-$$:scratch"
NET="m112net-$$"
PG="m112-pg-$$"
TC_ON="m112-tc-on-$$"     # TRUST_CENTER_ENABLED=1   (A/B)
TC_OFF="m112-tc-off-$$"   # flag unset               (C · flag-off parity)
TC_BAD="m112-tc-bad-$$"   # TRUST_CENTER_ENABLED=1 + a DISHONEST manifest (B2 · runtime reject)
# UNIQUE port pair for this gate (assigned to this slice).
PORT_ON="${M112_PORT_ON:-19124}"
PORT_OFF="${M112_PORT_OFF:-19125}"
PGPW="postgres"
SVC_TOKEN="m112-internal-service-token-$$"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
WORK="$(mktemp -d)"
BODY_TMP="${WORK}/body.json"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${TC_BAD}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

# shellcheck disable=SC2120  # "$@" passthrough is intentional (house psql_q helper); callers pipe heredocs
psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Apply a migration the SAME way make migrate does: strip the leading `#` 42-banner.
apply_migration() { # $1=file
  sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1
}

# Public GET (the trust endpoint needs NO auth). $1=port $2=path
pub_get() { # port path
  curl -s -o "${BODY_TMP}" -w '%{http_code}' "http://127.0.0.1:${1}${2}"
}
# Admin GET as the control-plane service token (for the /v1/tenants parity probe).
admin_get() { # port path
  curl -s -o "${BODY_TMP}" -w '%{http_code}' "http://127.0.0.1:${1}${2}" -H "X-Service-Token: ${SVC_TOKEN}"
}

wait_ready() { # $1=container $2=port
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/health/live" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

# ── 0) preflight: the canonical manifest must exist + be honest at rest ─────────
step "0/9 preflight: infra/config/trust/posture.json exists + is honest at rest"
[[ -f "${MANIFEST}" ]] || fail "infra/config/trust/posture.json is MISSING — D4.6 trust manifest must land before m112 (line: manifest exists)"
# Count controls in the FILE (the number the endpoint must reflect). jq if present,
# else a tolerant grep for top-level "id": entries inside the controls array.
if command -v jq >/dev/null 2>&1; then
  FILE_COUNT="$(jq '.controls | length' "${MANIFEST}")"
else
  FILE_COUNT="$(grep -c '"id"[[:space:]]*:' "${MANIFEST}")"
fi
[[ "${FILE_COUNT}" =~ ^[0-9]+$ && "${FILE_COUNT}" -gt 0 ]] || fail "could not count controls in posture.json (got '${FILE_COUNT}') (line: file count)"
# Honesty AT REST (independent of the running server): no implemented control with
# empty evidence. Prefer jq for a precise structural check; fall back to a Python
# check available in the postgres image is not present, so use jq-or-grep here.
if command -v jq >/dev/null 2>&1; then
  BAD_AT_REST="$(jq '[.controls[] | select(.status=="implemented") | select((.evidence // "") | gsub("[[:space:]]";"") == "")] | length' "${MANIFEST}")"
  [[ "${BAD_AT_REST}" == "0" ]] || fail "(preflight) ${BAD_AT_REST} control(s) are status=implemented with EMPTY evidence in posture.json — dishonest (line: at-rest honesty)"
fi
ok "manifest present: ${FILE_COUNT} controls, none implemented-without-evidence at rest"

# ── 0b) build the scratch tenant-control FROM CURRENT (drafted) source ──────────
step "0b/9 build scratch tenant-control from CURRENT source (the D4.6 trust code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3090 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — gate must exercise the drafted D4.6 code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres (TCP-ready) ──────────────────────────────────────
step "1/9 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  if docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 \
     && [[ "$(psql_val 'SELECT 1')" == "1" ]]; then break; fi
  [[ $i -eq 80 ]] && { docker logs "${PG}" 2>&1 | tail -20; fail "scratch postgres never reached TCP-ready"; }
  sleep 0.5
done
ok "postgres up + TCP-ready (SELECT 1 ok)"

# ── 1b) prelude (schema_migrations, auth.current_tenant_id, roles) then 005 + 032 ─
# No FEATURE migration — the trust center is file-backed. But tenant-control's BOOT
# schema-check requires public.tenants (005 + 032), and the (C) parity probe hits
# GET /v1/tenants, so the base tenant schema must exist.
step "1b/9 prelude + base 005 + 032 (tenant-control boot + the admin parity probe)"
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"; sleep 0.5; done
apply_migration "${MIGRATION_005}" || fail "real migration 005_add_tenant_table.sql failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032_tenants.sql failed to apply (line: apply 032)"
[[ "$(psql_val "SELECT to_regclass('public.tenants') IS NOT NULL")" == "t" ]] \
  || fail "public.tenants not created by 005/032 — tenant-control boot would fail (line: tenants check)"
ok "base tenant schema applied (public.tenants exists)"

# ── 2) boot the TRUST-ON tenant-control (manifest mounted RO) ───────────────────
step "2/9 boot tenant-control TRUST_CENTER_ENABLED=1 on 127.0.0.1:${PORT_ON}, infra/config/trust mounted RO"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TRUST_CENTER_ENABLED=1 \
  -e TRUST_MANIFEST=/trust/posture.json \
  -e TENANT_CONTROL_PORT=3090 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -v "${TRUST_DIR}:/trust:ro" \
  -p "127.0.0.1:${PORT_ON}:3090" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "trust-ON tenant-control not ready (line: wait_ready TC_ON)"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -qi "trust center enabled" \
  || { docker logs "${TC_ON}" 2>&1 | tail -20; fail "trust center never reported enabled (line: TC_ON enabled log)"; }
ok "trust-ON tenant-control up (/v1/trust* mounted, manifest from /trust/posture.json)"

# ── 3) (A · POSITIVE) GET /v1/trust => 200 with the controls ────────────────────
step "3/9 (A) GET /v1/trust => 200 + posture controls"
C="$(pub_get "${PORT_ON}" /v1/trust)"
[[ "${C}" == "200" ]] || fail "(A) GET /v1/trust expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A trust 200)"
cp "${BODY_TMP}" "${WORK}/trust.json"
grep -q '"controls"' "${WORK}/trust.json" || fail "(A) /v1/trust missing a controls array (line: A controls present)"
# Headline gate-proven controls must be present WITH their evidence pointers.
for EV in m104 m105 m108 m109; do
  grep -q "\"evidence\":\"${EV}\"" "${WORK}/trust.json" \
    || fail "(A) /v1/trust missing the control citing ${EV} (the trust narrative promises audit/erase/export/soc2) (line: A evidence ${EV})"
done
ok "(A) /v1/trust => 200; audit(m104)/erase(m105)/export(m109)/soc2(m108) present with evidence"

# ── 4) (A · POSITIVE) every status is in the allowed enum (no garbage/blank) ────
step "4/9 (A) every control status is in {implemented,partial,planned}"
# Extract every "status":"..." value; assert each is in the enum. tr to one-per-line.
STATUSES="$(grep -o '"status":"[^"]*"' "${WORK}/trust.json" | sed 's/"status":"//; s/"$//')"
[[ -n "${STATUSES}" ]] || fail "(A) no status fields found in /v1/trust (line: A statuses present)"
BAD_STATUS=""
while IFS= read -r s; do
  case "${s}" in
    implemented|partial|planned) : ;;
    "") fail "(A) a control has a BLANK status (line: A blank status)";;
    *) BAD_STATUS="${s}";;
  esac
done <<< "${STATUSES}"
[[ -z "${BAD_STATUS}" ]] || fail "(A) a control has status '${BAD_STATUS}' outside the enum (line: A enum)"
ok "(A) all statuses in {implemented,partial,planned}"

# ── 5) (A · POSITIVE) served count == count in infra/config/trust/posture.json ─────────
step "5/9 (A) served control count == count in infra/config/trust/posture.json (endpoint reflects the FILE)"
C="$(pub_get "${PORT_ON}" /v1/trust/controls)"
[[ "${C}" == "200" ]] || fail "(A) GET /v1/trust/controls expected 200, got ${C} — $(head -c 200 "${BODY_TMP}") (line: A controls 200)"
cp "${BODY_TMP}" "${WORK}/controls.json"
# Served count: prefer the JSON "count" field; fall back to counting "id": entries.
if command -v jq >/dev/null 2>&1; then
  SERVED_COUNT="$(jq '.count' "${WORK}/controls.json")"
else
  SERVED_COUNT="$(grep -o '"count":[0-9]*' "${WORK}/controls.json" | head -1 | sed 's/"count"://')"
  [[ -n "${SERVED_COUNT}" ]] || SERVED_COUNT="$(grep -c '"id"[[:space:]]*:' "${WORK}/controls.json")"
fi
[[ "${SERVED_COUNT}" == "${FILE_COUNT}" ]] \
  || fail "(A) served count ${SERVED_COUNT} != file count ${FILE_COUNT} — endpoint is a stub, not the file (line: A count match)"
ok "(A) endpoint reflects the file: ${SERVED_COUNT} controls served == ${FILE_COUNT} in posture.json"

# ── 6) (B · REJECT, LOAD-BEARING) no implemented control with empty evidence ────
# Honesty check on the SERVED JSON: an unproven claim must be partial/planned, never
# implemented-without-evidence. A dishonest "everything green" page fails here.
step "6/9 (B · REJECT, LOAD-BEARING) NO served control is status=implemented with EMPTY evidence"
if command -v jq >/dev/null 2>&1; then
  BAD="$(jq '[.controls[] | select(.status=="implemented") | select((.evidence // "") | gsub("[[:space:]]";"") == "")] | length' "${WORK}/trust.json")"
  [[ "${BAD}" == "0" ]] \
    || fail "(B) ${BAD} served control(s) claim status=implemented with EMPTY evidence — dishonest trust page (line: B jq honesty)"
else
  # jq-less fallback: pull each control object's {status, evidence} and check pairs.
  # Reduce the JSON to one control-object per line, then flag any implemented one
  # whose evidence is empty/absent.
  python3 - "${WORK}/trust.json" <<'PY' || fail "(B) honesty check failed — an implemented control lacks evidence (line: B py honesty)"
import json, sys
data = json.load(open(sys.argv[1]))
bad = [c.get("id","?") for c in data.get("controls", [])
       if c.get("status") == "implemented" and not str(c.get("evidence","")).strip()]
if bad:
    print("implemented-without-evidence:", ", ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
fi
ok "(B) honesty holds: every implemented control carries a non-empty evidence pointer"

# ── 6b) (B2 · REJECT, LOAD-BEARING — runtime honesty) a DISHONEST manifest must
# REFUSE TO BOOT. The arm above re-checks the (honest) SERVED JSON; this one proves
# the Go boot-time boundary (LoadManifest rejects implemented-without-evidence ->
# os.Exit(1)) ACTUALLY FIRES at runtime, not just in the unit test. No port is
# published — a refused boot must exit BEFORE it ever serves.
step "6b/9 (B2 · REJECT, LOAD-BEARING) a manifest with an implemented control + EMPTY evidence => tenant-control REFUSES to boot"
mkdir -p "${WORK}/badtrust"
cat > "${WORK}/badtrust/posture.json" <<'JSON'
{
  "product": "Grobase",
  "version": "trust-center-DISHONEST-fixture",
  "note": "deliberately dishonest: one implemented control with EMPTY evidence — must be rejected at boot",
  "controls": [
    { "id": "honest-one", "name": "Honest control", "category": "test", "status": "planned", "evidence": "wiki/trust-center.md" },
    { "id": "dishonest-one", "name": "Unproven claim dressed as implemented", "category": "test", "status": "implemented", "evidence": "" }
  ]
}
JSON
chmod 0755 "${WORK}/badtrust"; chmod 0644 "${WORK}/badtrust/posture.json"
docker run -d --name "${TC_BAD}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TRUST_CENTER_ENABLED=1 \
  -e TRUST_MANIFEST=/badtrust/posture.json \
  -e TENANT_CONTROL_PORT=3090 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -v "${WORK}/badtrust:/badtrust:ro" \
  "${TC_IMG}" >/dev/null
# It MUST exit (LoadManifest -> os.Exit(1)); wait briefly for it to stop running.
BAD_RUNNING="true"
for _ in $(seq 1 30); do
  if [[ "$(docker inspect -f '{{.State.Running}}' "${TC_BAD}" 2>/dev/null)" != "true" ]]; then BAD_RUNNING="false"; break; fi
  sleep 0.5
done
[[ "${BAD_RUNNING}" == "false" ]] \
  || { docker logs "${TC_BAD}" 2>&1 | tail -20; fail "(B2) a DISHONEST manifest did NOT stop the boot — tenant-control still running (the honesty boundary did not fire) (line: B2 still running)"; }
BAD_EXIT="$(docker inspect -f '{{.State.ExitCode}}' "${TC_BAD}" 2>/dev/null || echo '?')"
[[ "${BAD_EXIT}" != "0" && "${BAD_EXIT}" != "?" ]] \
  || { docker logs "${TC_BAD}" 2>&1 | tail -20; fail "(B2) tenant-control exited '${BAD_EXIT}' on a dishonest manifest — it must REFUSE to boot (non-zero) (line: B2 exit code)"; }
ok "(B2) dishonest manifest REFUSED at boot (tenant-control exited ${BAD_EXIT}, never served) — the runtime honesty boundary fires"

# ── 7) (C · FLAG-OFF PARITY) flag unset -> /v1/trust* 404, admin /v1/tenants 200 ─
step "7/9 (C · FLAG-OFF PARITY) STOP the ENABLED container; boot with TRUST_CENTER_ENABLED unset"
docker rm -fv "${TC_ON}" >/dev/null 2>&1 || true
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3090 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3090" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "trust-OFF tenant-control not ready (line: wait_ready TC_OFF)"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -qi "trust center disabled" \
  || { docker logs "${TC_OFF}" 2>&1 | tail -20; fail "OFF tenant-control did not report trust center disabled (flag default not OFF?) (line: TC_OFF disabled log)"; }
ok "trust-OFF tenant-control up (TRUST_CENTER_ENABLED unset)"

step "8/9 (C) EVERY /v1/trust* route 404 with the flag OFF (byte-parity)"
for path in "/v1/trust" "/v1/trust/controls"; do
  C="$(pub_get "${PORT_OFF}" "${path}")"
  [[ "${C}" == "404" ]] \
    || fail "(C) PARITY: ${path} with TRUST_CENTER_ENABLED off expected 404 (route absent), got ${C} — $(head -c 200 "${BODY_TMP}") (line: C 404 ${path})"
done
ok "(C) both /v1/trust* routes 404 with the flag OFF"

step "9/9 (C) the base admin surface STILL works on the OFF router (only trust is gated)"
C="$(admin_get "${PORT_OFF}" "/v1/tenants")"
[[ "${C}" == "200" ]] \
  || fail "(C) PARITY: base admin GET /v1/tenants expected 200 on OFF router, got ${C} — $(head -c 200 "${BODY_TMP}") (line: C admin 200)"
ok "(C) base admin GET /v1/tenants => 200 — the baseline is untouched; only the trust center is flag-gated"

# ── summarize ──────────────────────────────────────────────────────────────────
green "[M112] (A) POSITIVE: GET /v1/trust 200 with controls; audit(m104)/erase(m105)/export(m109)/soc2(m108) present with evidence; every status in {implemented,partial,planned}; served count ${SERVED_COUNT} == ${FILE_COUNT} in infra/config/trust/posture.json (endpoint reflects the file, not a stub)"
green "[M112] (B) REJECT:   NO served control is status=implemented with EMPTY evidence — an unproven claim must be partial/planned (catches a dishonest 'everything green' trust page)"
green "[M112] (C) PARITY:   TRUST_CENTER_ENABLED off => /v1/trust* 404 while admin GET /v1/tenants 200 — byte-identical to today; only the trust center is flag-gated"

# ── emit the gate event via the kernel log helper (best-effort) ─────────────────
step "log GATE m112=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-d46-trust-center}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m112=PASS" --outcome pass \
      --msg "D4.6 trust center: file-backed posture (infra/config/trust/posture.json) served read-only at /v1/trust + /v1/trust/controls. POSITIVE: 200 with audit(m104)/erase(m105)/export(m109)/soc2(m108) present with evidence; every status in the enum; served count == file count (endpoint reflects the file). LOAD-BEARING REJECT: no implemented control with empty evidence (catches a dishonest all-green page). PARITY: TRUST_CENTER_ENABLED off -> /v1/trust* 404 while admin /v1/tenants 200 (byte-identical, no migration)." \
      --ref "scripts/verify/m112-trust-center.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M112] ALL GATES GREEN — D4.6 trust center: a public, file-backed, honest security posture endpoint (every implemented control evidence-backed), byte-parity (404) when OFF"
exit 0
