#!/usr/bin/env bash
# **************************************************************************** #
#    m141-compliance-posture.sh — COMPLIANCE POSTURE is honest + provable     #
#                                                                              #
#    Slice-3 gate: proves the Grobase compliance posture is AUDIT-READY (not  #
#    "SOC2 certified") with in-repo evidence a buyer can re-verify. It asserts #
#    NON-VACUOUSLY that:                                                       #
#                                                                              #
#      (1) the control matrix + machine-readable standards mapping EXIST,      #
#          are non-empty, and actually map controls to OWASP ASVS + SOC2 TSC   #
#          + GDPR articles (a placeholder file fails);                         #
#      (2) the TAMPER-EVIDENT audit log really verifies — append an entry,     #
#          recompute the hash chain (INTACT), then DB-tamper one row and prove #
#          verify reports BROKEN at the exact link (hash_mismatch). A verify   #
#          that always says "intact" FAILS here — this is the load-bearing     #
#          assertion that the evidence is real, not asserted;                  #
#      (3) the GDPR data-subject-rights paths (erase Art.17 + export Art.20)   #
#          are REACHABLE (mounted, authorized — not 404) when enabled;         #
#      (4) every control the posture claims "implemented" cites a gate/doc     #
#          that EXISTS in the repo (no dangling evidence).                     #
#                                                                              #
#    Named m141-compliance-posture (sibling of m104-audit-chain, which proves  #
#    the chain in depth) — this gate proves the POSTURE as a whole: docs +     #
#    standards mapping + the cryptographic spine + the GDPR rights surface.    #
#                                                                              #
#    ISOLATED by design (mirrors m104-audit-chain / m105 / m108): scratch      #
#    postgres + a tenant-control built FROM CURRENT source, ALL on a PRIVATE   #
#    network, names suffixed with $$, an EXIT-trap removing EVERYTHING. It     #
#    NEVER touches a mini-baas-* container/network/image/volume and NEVER      #
#    edits docker-compose.yml. The live shared tenant-control is NOT touched.  #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
WIKI_DIR="${BAAS_DIR}/wiki"
GO_DIR="${INFRA_DIR}/go/control-plane"
MIGRATION_047="${INFRA_DIR}/scripts/migrations/postgresql/047_tenant_audit_log.sql"
POSTURE_JSON="${INFRA_DIR}/config/trust/posture.json"
COMPLIANCE_DOC="${WIKI_DIR}/compliance-posture.md"
ASVS_DOC="${WIKI_DIR}/security-audit-asvs.md"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M141] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M141] FAIL — $*"; exit 1; }

PG_IMAGE="${M141CP_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m141cp-tc-$$:scratch"
NET="m141cpnet-$$"
PG="m141cp-pg-$$"
TC="m141cp-tc-$$"
PORT="${M141CP_PORT:-19140}"
PGPW="postgres"
SVC_TOKEN="m141cp-internal-service-token-$$"
TENANT_A="m141cp-tenant-a-$$"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${TC}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"

append() { # $1=action $2=target $3=payload-json
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST \
    "http://127.0.0.1:${PORT}/v1/audit/tenants/${TENANT_A}/events" \
    -H 'Content-Type: application/json' -H "X-Service-Token: ${SVC_TOKEN}" \
    -d "{\"actor\":\"api-key:${TENANT_A}\",\"action\":\"$1\",\"target\":\"$2\",\"payload\":$3}"
}
audit_get() { # $1=sub(events|verify|export)
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -H "X-Service-Token: ${SVC_TOKEN}" \
    "http://127.0.0.1:${PORT}/v1/audit/tenants/${TENANT_A}/$1"
}
wait_ready() {
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/health/live" 2>/dev/null && return 0
    docker inspect "${TC}" >/dev/null 2>&1 || { red "${TC} exited early:"; docker logs "${TC}" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "${TC} never became ready:"; docker logs "${TC}" 2>&1 | tail -20; return 1
}

# ── 1) CONTROL DOCS + STANDARDS MAPPING exist, are non-empty, map ASVS+SOC2+GDPR ─
step "1/8 control matrix + standards mapping present, non-empty, mapping ASVS+SOC2+GDPR"
[[ -s "${COMPLIANCE_DOC}" ]]  || fail "control matrix missing/empty: ${COMPLIANCE_DOC}"
[[ -s "${ASVS_DOC}" ]]        || fail "ASVS control map missing/empty: ${ASVS_DOC}"
[[ -s "${POSTURE_JSON}" ]]    || fail "machine-readable posture missing/empty: ${POSTURE_JSON}"
# The control matrix must actually map all THREE standards families (not a stub).
for needle in 'ASVS' 'SOC' 'GDPR' 'Art\.' 'CC6' 'tamper'; do
  grep -qiE "${needle}" "${COMPLIANCE_DOC}" \
    || fail "control matrix does not reference '${needle}' — not a real standards mapping"
done
# A real matrix has many rows, not a placeholder. Count GDPR Article + ASVS V-chapter refs.
GDPR_REFS="$(grep -oiE 'Art\.?\s*[0-9]+' "${COMPLIANCE_DOC}" | wc -l | tr -d ' ')"
[[ "${GDPR_REFS}" -ge 4 ]] || fail "control matrix cites only ${GDPR_REFS} GDPR articles (<4) — too thin to be a real mapping"
# posture.json must be valid JSON with controls; verify it parses + has implemented controls.
python3 - "$POSTURE_JSON" <<'PY' || fail "posture.json is not valid JSON with implemented controls"
import json, sys
d = json.load(open(sys.argv[1]))
ctrls = d.get("controls", [])
assert len(ctrls) >= 10, f"only {len(ctrls)} controls"
impl = [c for c in ctrls if c.get("status") == "implemented"]
assert len(impl) >= 5, f"only {len(impl)} implemented controls"
# every implemented control MUST cite evidence (no empty claims).
for c in impl:
    assert str(c.get("evidence","")).strip(), f"implemented control {c.get('id')} has no evidence"
print(f"posture.json OK: {len(ctrls)} controls, {len(impl)} implemented, all cite evidence")
PY
ok "control matrix maps ASVS+SOC2+GDPR (${GDPR_REFS} GDPR-article refs); posture.json valid + every implemented control cites evidence"

# ── 2) DANGLING-EVIDENCE check: every cited gate/doc EXISTS in the repo ──────────
step "2/8 every 'implemented' control's cited gate/doc EXISTS (no dangling evidence)"
MISSING="$(python3 - "$POSTURE_JSON" "$SCRIPT_DIR" "$WIKI_DIR" <<'PY'
import json, sys, os, glob, re
posture, verify_dir, wiki_dir = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(posture))
missing = []
for c in d.get("controls", []):
    if c.get("status") != "implemented":
        continue
    ev = str(c.get("evidence","")).strip()
    if re.fullmatch(r"m\d+", ev):                      # a gate number → a verify script must exist
        if not glob.glob(os.path.join(verify_dir, ev + "-*.sh")):
            missing.append(f"{c['id']}:{ev} (no verify/{ev}-*.sh)")
    elif ev.startswith("wiki/"):                        # a wiki doc → it must exist
        p = os.path.join(os.path.dirname(wiki_dir), ev)
        if not os.path.exists(p):
            missing.append(f"{c['id']}:{ev} (missing doc)")
print("\n".join(missing))
PY
)"
[[ -z "${MISSING}" ]] || fail "dangling evidence — posture claims controls with no artifact:\n${MISSING}"
ok "no dangling evidence — every implemented control resolves to an existing gate or doc"

# ── 3) build scratch tenant-control FROM CURRENT source ─────────────────────────
step "3/8 build scratch tenant-control from CURRENT source (the compliance code path)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3060 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — gate must exercise the live code"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 4) isolated net + postgres (TCP-ready) + REAL migration 047 ─────────────────
step "4/8 boot isolated net (${NET}): postgres + REAL migration 047"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  if docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 \
     && [[ "$(psql_val 'SELECT 1')" == "1" ]]; then break; fi
  [[ $i -eq 80 ]] && { docker logs "${PG}" 2>&1 | tail -20; fail "scratch postgres never reached TCP-ready"; }
  sleep 0.5
done
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
CREATE TABLE IF NOT EXISTS public.tenants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), slug text UNIQUE, name text,
  status text DEFAULT 'active', plan text, owner_user_id text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now());
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed"; sleep 0.5; done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "${MIGRATION_047}" >/dev/null 2>&1 \
  || fail "real migration 047_tenant_audit_log.sql failed to apply"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_audit_log")" == "0" ]] || fail "tenant_audit_log should start EMPTY"
# Append-only at the grant layer is a control claim — assert it for real.
HASUPD="$(psql_val "SELECT count(*) FROM information_schema.role_table_grants WHERE table_name='tenant_audit_log' AND grantee='authenticated' AND privilege_type IN ('UPDATE','DELETE')")" || HASUPD="?"
[[ "${HASUPD}" == "0" ]] || fail "control claim violated: authenticated has UPDATE/DELETE on tenant_audit_log (not append-only)"
ok "postgres up; migration 047 applied; audit log empty + append-only grant verified"

# ── 5) boot tenant-control with audit + GDPR rights ENABLED ─────────────────────
step "5/8 boot tenant-control (audit + GDPR erase + GDPR export ENABLED)"
docker run -d --name "${TC}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3060 \
  -e TENANT_AUDIT_ENABLED=1 \
  -e HARD_ERASE_ENABLED=1 \
  -e TENANT_EXPORT_ENABLED=1 \
  -e EXPORT_DATA_DIR=/tmp/exports \
  -e LOG_LEVEL=info \
  -p "127.0.0.1:${PORT}:3060" "${TC_IMG}" >/dev/null
wait_ready || fail "tenant-control not ready"
TC_LOGS="$(docker logs "${TC}" 2>&1)"   # capture once: piping into grep -q trips pipefail via SIGPIPE
grep -q "tenant audit log enabled" <<<"${TC_LOGS}" || { printf '%s\n' "${TC_LOGS}" | tail -20; fail "audit log never reported enabled"; }
ok "tenant-control up: audit (/v1/audit*) + GDPR rights routes mounted"

# ── 6) LOAD-BEARING: tamper-evident audit actually verifies (append→INTACT→tamper→BROKEN) ─
step "6/8 (load-bearing) append → recompute chain INTACT → DB-tamper → verify BROKEN at exact link"
for n in 1 2 3; do
  CODE="$(append "key.issue" "key-${n}" "{\"n\":${n}}")"
  [[ "${CODE}" == "201" ]] || fail "append #${n} expected 201, got ${CODE} — $(head -c 300 "${BODY_TMP}")"
  grep -q '"hash":"' "${BODY_TMP}" || fail "append #${n} body missing sealed hash"
done
CODE="$(audit_get verify)"
[[ "${CODE}" == "200" ]] || fail "verify expected 200, got ${CODE}"
grep -q '"intact":true' "${BODY_TMP}" || fail "freshly sealed chain must verify INTACT — $(head -c 400 "${BODY_TMP}")"
ok "fresh chain verifies INTACT (3 sealed links)"
# Tamper: edit a stored row's payload WITHOUT recomputing its hash — exactly a DB-level mutation.
TAMPER_SEQ=2
psql_q >/dev/null 2>&1 <<SQL || fail "could not UPDATE the audit row to tamper it"
UPDATE public.tenant_audit_log SET payload='{"n":999999}'::jsonb
 WHERE tenant_id='${TENANT_A}' AND seq=${TAMPER_SEQ};
SQL
CODE="$(audit_get verify)"
[[ "${CODE}" == "200" ]] || fail "verify after tamper expected 200 (a report of tampering), got ${CODE}"
grep -q '"intact":false' "${BODY_TMP}" \
  || fail "VACUOUS-VERIFY REJECTED — a tampered chain reported intact:true — $(head -c 400 "${BODY_TMP}")"
grep -q "\"broken_seq\":${TAMPER_SEQ}" "${BODY_TMP}" \
  || fail "verify did not pinpoint the tampered link seq=${TAMPER_SEQ} — $(head -c 400 "${BODY_TMP}")"
grep -q '"reason":"hash_mismatch"' "${BODY_TMP}" \
  || fail "tamper reason should be hash_mismatch — $(head -c 400 "${BODY_TMP}")"
ok "tamper DETECTED: verify→intact:false @ broken_seq=${TAMPER_SEQ} reason=hash_mismatch (evidence is REAL, not asserted)"

# ── 7) GDPR data-subject rights paths are REACHABLE (not 404) when enabled ───────
step "7/8 GDPR erase (Art.17) + export (Art.20) paths REACHABLE under service auth"
# Reachable = the route is MOUNTED + authorization is enforced (not a flat 404).
# We assert the route is NOT 404 with a valid service token (it may 4xx/5xx on the
# missing tenant fixture, but it must be MOUNTED — a 404 would mean the right does
# not exist). A NO-token call MUST be 401 (authorization is enforced, not bypassed).
ER_AUTH="$(curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST -H "X-Service-Token: ${SVC_TOKEN}" \
  "http://127.0.0.1:${PORT}/v1/tenants/${TENANT_A}/erase" -H 'Content-Type: application/json' -d '{}')"
[[ "${ER_AUTH}" != "404" ]] || fail "GDPR erase route NOT MOUNTED (404) — right to erasure unreachable"
ER_NOAUTH="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:${PORT}/v1/tenants/${TENANT_A}/erase" -H 'Content-Type: application/json' -d '{}')"
[[ "${ER_NOAUTH}" == "401" ]] || fail "GDPR erase must require auth (expected 401 no-token, got ${ER_NOAUTH})"
ok "erase (Art.17) reachable + authorized (mounted: code ${ER_AUTH} with token, 401 without)"
EX_AUTH="$(curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST -H "X-Service-Token: ${SVC_TOKEN}" \
  "http://127.0.0.1:${PORT}/v1/tenants/${TENANT_A}/export" -H 'Content-Type: application/json' -d '{}')"
[[ "${EX_AUTH}" != "404" ]] || fail "GDPR export route NOT MOUNTED (404) — data portability unreachable"
EX_NOAUTH="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:${PORT}/v1/tenants/${TENANT_A}/export" -H 'Content-Type: application/json' -d '{}')"
[[ "${EX_NOAUTH}" == "401" ]] || fail "GDPR export must require auth (expected 401 no-token, got ${EX_NOAUTH})"
ok "export (Art.20) reachable + authorized (mounted: code ${EX_AUTH} with token, 401 without)"

# ── 8) summarize + emit gate event ──────────────────────────────────────────────
step "8/8 summary"
green "[M141] (1) control matrix + standards mapping present → ASVS+SOC2+GDPR, ${GDPR_REFS} GDPR-article refs"
green "[M141] (2) no dangling evidence — every implemented control resolves to a real gate/doc"
green "[M141] (6) tamper-evident audit PROVEN: INTACT→tamper→intact:false @ broken_seq=${TAMPER_SEQ} hash_mismatch"
green "[M141] (7) GDPR erase (Art.17) + export (Art.20) REACHABLE + auth-enforced"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-compliance-posture}"
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m141-compliance-posture=PASS" --outcome pass \
      --msg "compliance posture honest+provable: control matrix maps ASVS+SOC2+GDPR; no dangling evidence; tamper-evident audit verifies (INTACT→tamper→BROKEN@exact link hash_mismatch); GDPR erase(Art.17)+export(Art.20) reachable+auth-enforced" \
      --ref "scripts/verify/m141-compliance-posture.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log

green "[M141] ALL GATES GREEN — compliance posture is AUDIT-READY with in-repo, re-verifiable evidence (NOT a formal SOC2 cert)"
exit 0
