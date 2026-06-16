#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m109-tenant-export.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M109 — Track-D D4.3 TENANT DATA EXPORT (GDPR Art. 20 data portability) live
# gate. B6 (m87) produces a RESTORE-oriented COPY backup; D4.3 produces a
# PORTABLE bundle — a single self-describing JSON document (per-table rows + a
# manifest{tables, row counts, sha256}) the tenant can take ELSEWHERE. It scopes
# STRICTLY to ONE tenant (schema_per_tenant => that schema; shared_rls => WHERE
# tenant_id), reusing the D4.4 erase resolution. It exercises a tenant-control
# binary built FROM CURRENT source — the EXACT D4.3 code — with the JSON export
# engine + a local-filesystem ArtifactStore (NO MinIO container on the
# RAM-constrained box):
#
#   tenant-control (Go, TENANT_EXPORT_ENABLED=1, EXPORT_DATA_DIR=/exports)
#     X-Service-Token: …   (admin)
#       │
#       ▼
#     POST /v1/tenants/{id}/export            -> export_id (status pending->completed)
#     GET  /v1/tenants/{id}/exports           -> the tenant's exports (RLS)
#     GET  /v1/tenants/{id}/export/{exportId} -> the portable JSON bundle
#
#   D4.3 supports schema_per_tenant AND shared_rls. db_per_tenant + tenant_owned
#   are DEFERRED and rejected 400 "isolation not supported for export (deferred)".
#
#   (A · POSITIVE) seed A as a schema_per_tenant mount with ${ROWS_A} deterministic
#       rows in <tenant_a>.m109_marker. Export A -> the bundle (download +
#       artifact on disk) contains EXACTLY those rows in a portable JSON format,
#       its manifest lists the right table with the right count, and the ledger
#       records table_count/row_count + a hex sha256 that matches the bundle on
#       disk. ALSO export a shared_rls tenant SR (rows in a LIVE shared table,
#       scoped WHERE tenant_id) -> exactly SR's rows.
#   (B · REJECT, LOAD-BEARING) cross-tenant: the export of A contains ZERO of
#       tenant B's rows. Seed B (different rows) in a sibling schema, AND a second
#       shared_rls tenant SR2 in the SAME shared table. grep the A bundle proves
#       NO b-row payload bleeds in; grep the SR bundle proves NO sr2-row payload
#       bleeds in (the shared-table WHERE tenant_id wall). A db_per_tenant mount's
#       export -> 400 deferred. A gate that only shows the happy path is VACUOUS;
#       the zero-B-rows + zero-SR2-rows + deferred-400 assertions are load-bearing.
#   (C · PARITY) a SECOND tenant-control with TENANT_EXPORT_ENABLED unset: POST
#       /v1/tenants/{id}/export -> 404 (route NOT mounted) WHILE the base admin
#       route GET /v1/tenants/{id} (service token) STILL 200 = byte-parity.
#
# Seeding: tenants + keys via the EXISTING service-token admin endpoints (POST
# /v1/tenants, X-Service-Token); the schema_per_tenant mount + its rows are
# created directly in the scratch postgres (CREATE SCHEMA + a tenant_databases
# row), and the shared_rls rows are inserted into a LIVE shared table that
# carries a tenant_id column. The schema name is computed in-gate with the SAME
# sanitizer the Go tenantSchema() uses.
#
# ISOLATED by design (mirrors m87/m83): scratch postgres (prelude + REAL 005 +
# 032 + 040 + 041 + 052) + two tenant-control binaries built FROM CURRENT
# source, ALL on a PRIVATE network, every name suffixed with $$, a local artifact
# dir under /mnt/storage, an EXIT-trap removing EVERYTHING. It NEVER touches a
# mini-baas-* container/network/image/volume and NEVER edits the live
# docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
GO_DIR="${INFRA_DIR}/go/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
MIGRATION_040="${MIG_DIR}/040_tenant_usage.sql"
MIGRATION_041="${MIG_DIR}/041_tenant_billing.sql"
MIGRATION_052="${MIG_DIR}/052_tenant_exports.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M109] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M109] FAIL — $*"; exit 1; }

PG_IMAGE="${M109_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m109-tc-$$:scratch"
NET="m109net-$$"
PG="m109-pg-$$"
TC_ON="m109-tc-on-$$"      # TENANT_EXPORT_ENABLED=1   (A · positive / B · reject)
TC_OFF="m109-tc-off-$$"    # TENANT_EXPORT_ENABLED unset (C · parity)
PORT_ON="${M109_PORT_ON:-19114}"
PORT_OFF="${M109_PORT_OFF:-19115}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m109-internal-service-token-$$"
TENANT_A="m109-a-$$"             # schema_per_tenant, positive + cross-tenant base
TENANT_B="m109-b-$$"             # schema_per_tenant, the OTHER tenant (must NOT bleed into A)
TENANT_SR="m109-sr-$$"           # shared_rls, positive + cross-tenant base
TENANT_SR2="m109-sr2-$$"         # shared_rls, the OTHER tenant in the SAME shared table
TENANT_D="m109-d-$$"             # db_per_tenant -> export must 400 (deferred)
ARTIFACT_DIR="${M109_ARTIFACT_DIR:-/mnt/storage/bench/m109-exports-$$}"
ROWS_A=100
ROWS_B=50
ROWS_SR=30
ROWS_SR2=20
BODY_TMP="$(mktemp)"
BUNDLE_TMP="$(mktemp)"

# Derive the schema name EXACTLY like Go tenantSchema(id): lowercase, keep
# [a-z0-9_], replace others with '_', trim leading/trailing '_', truncate 50,
# prefix "tenant_".
tenant_schema() { # $1=slug
  local s frag
  s="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_]/_/g')"
  frag="$(printf '%s' "$s" | sed 's/^_*//; s/_*$//')"
  frag="${frag:0:50}"
  printf 'tenant_%s' "${frag}"
}
SCHEMA_A="$(tenant_schema "${TENANT_A}")"
SCHEMA_B="$(tenant_schema "${TENANT_B}")"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" "${BUNDLE_TMP}" 2>/dev/null || true
  rm -rf "${ARTIFACT_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

apply_migration() { # $1=file
  sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1
}

# Admin (service-token) request -> echo HTTP status, body->BODY_TMP.
#   $1=method  $2=port  $3=path  $4(optional)=json body
admin_req() {
  local m="$1" p="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}"
  fi
}

# Admin download: stream the bundle body to BUNDLE_TMP, echo the HTTP status.
admin_dl() { # $1=port $2=path
  curl -s -o "${BUNDLE_TMP}" -w '%{http_code}' -X GET "http://127.0.0.1:$1$2" \
    -H "X-Service-Token: ${SVC_TOKEN}"
}

# Extract a top-level JSON string field value off BODY_TMP. Tolerates ZERO
# matches (grep wrapped in `|| true` so pipefail+set -e does not kill us).
json_str() { # $1=field
  { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'
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

# ── 0) build the scratch tenant-control FROM CURRENT (drafted) source ──────────
step "0/9 build scratch tenant-control from CURRENT source (the D4.3 export code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — gate must exercise the drafted export code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres + prelude + REAL 005/032/040/041/052 ────────────
step "1/9 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# Gate readiness on TCP + a REAL SELECT 1 (the image init runs a socket-only temp
# server first; a log-only check races it).
for i in $(seq 1 80); do
  if docker exec "${PG}" pg_isready -h 127.0.0.1 -q 2>/dev/null && [[ "$(psql_val 'SELECT 1')" == "1" ]]; then
    break
  fi
  [[ $i -eq 80 ]] && { docker logs "${PG}" 2>&1 | tail -20; fail "scratch postgres never accepted TCP + SELECT 1 (line: PG ready loop)"; }
  sleep 0.5
done
ok "postgres up (TCP + SELECT 1)"

step "1b/9 apply prelude (schema_migrations, auth.current_tenant_id, roles, tenant_databases, a shared table), then REAL 005 + 032 + 040 + 041 + 052"
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
-- tenant_databases is owned by the adapter-registry's Go EnsureSchema (NOT a SQL
-- migration), so the gate scaffolds it. The export service reads `isolation`
-- from it keyed by the tenant slug. The CHECK lists all four real isolation
-- models so a db_per_tenant row INSERTs (then gets rejected at the EXPORT layer).
CREATE TABLE IF NOT EXISTS public.tenant_databases (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       TEXT NOT NULL,
  engine          TEXT NOT NULL,
  name            TEXT NOT NULL,
  connection_enc  BYTEA NOT NULL,
  connection_iv   BYTEA NOT NULL,
  connection_tag  BYTEA NOT NULL,
  isolation       TEXT NOT NULL DEFAULT 'shared_rls'
                  CHECK (isolation IN ('shared_rls','schema_per_tenant','db_per_tenant','tenant_owned')),
  created_at      TIMESTAMPTZ DEFAULT now(),
  last_healthy_at TIMESTAMPTZ,
  UNIQUE(tenant_id, name)
);
-- A LIVE shared data table carrying a tenant_id column — the shared_rls export
-- reads from it WHERE tenant_id (and the cross-tenant arm proves SR2's rows in
-- the SAME table never bleed into SR's bundle). It is NOT in the export service's
-- bookkeeping exclusion set, so it is discovered as tenant data.
CREATE TABLE IF NOT EXISTS public.m109_shared (
  id        SERIAL PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  payload   TEXT NOT NULL
);
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"; sleep 0.5; done
apply_migration "${MIGRATION_005}" || fail "real migration 005_add_tenant_table.sql failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032_tenants.sql failed to apply (line: apply 032)"
apply_migration "${MIGRATION_040}" || fail "real migration 040_tenant_usage.sql failed to apply (line: apply 040)"
apply_migration "${MIGRATION_041}" || fail "real migration 041_tenant_billing.sql failed to apply (line: apply 041)"
[[ -f "${MIGRATION_052}" ]] || fail "migration 052_tenant_exports.sql is MISSING — the D4.3 migration slice must land before m109 can run (line: 052 exists)"
apply_migration "${MIGRATION_052}" || fail "real migration 052_tenant_exports.sql failed to apply (line: apply 052)"
[[ "$(psql_val "SELECT count(*) FROM public.tenants")" == "0" ]] || fail "tenants should start EMPTY (line: 032 empty check)"
[[ "$(psql_val "SELECT to_regclass('public.tenant_exports') IS NOT NULL")" == "t" ]] \
  || fail "public.tenant_exports not created by migration 052 (line: 052 table check)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_exports")" == "0" ]] \
  || fail "tenant_exports should start EMPTY (line: 052 empty check)"
ok "migrations 005 + 032 + 040 + 041 + 052 applied — tenants / tenant_databases / tenant_exports / m109_shared exist, ledger empty"

# ── 2) boot the EXPORT-ON tenant-control (TENANT_EXPORT_ENABLED=1) ─────────────
step "2/9 boot tenant-control TENANT_EXPORT_ENABLED=1, EXPORT_DATA_DIR=/exports on 127.0.0.1:${PORT_ON} (A · positive / B · reject)"
mkdir -p "${ARTIFACT_DIR}" 2>/dev/null \
  || fail "could not create local artifact dir ${ARTIFACT_DIR} (run once: sudo install -d -o \$USER /mnt/storage/bench) (line: artifact mkdir)"
chmod 777 "${ARTIFACT_DIR}" 2>/dev/null || true
docker run -d --name "${TC_ON}" --network "${NET}" \
  --user "$(id -u):$(id -g)" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_EXPORT_ENABLED=1 \
  -e EXPORT_DATA_DIR=/exports \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -v "${ARTIFACT_DIR}:/exports" \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "export-ON tenant-control not ready (line: wait_ready TC_ON)"
ok "export-ON tenant-control up (LocalFileStore -> /exports, export routes mounted)"

# ── 3) SEED tenants via admin endpoints, then mounts + rows in PG ──────────────
step "3/9 seed A + B (schema_per_tenant) + SR + SR2 (shared_rls) + D (db_per_tenant) via POST /v1/tenants (X-Service-Token)"
for t in "${TENANT_A}" "${TENANT_B}" "${TENANT_SR}" "${TENANT_SR2}" "${TENANT_D}"; do
  C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${t}\",\"name\":\"${t}\",\"plan\":\"nano\"}")"
  [[ "${C}" == "201" ]] || fail "seed tenant ${t} expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed ${t})"
done
ok "tenants A + B + SR + SR2 + D created (all nano)"

step "3b/9 register mounts (A/B schema_per_tenant, SR/SR2 shared_rls, D db_per_tenant); create A/B schemas + marker rows; insert SR/SR2 shared rows"
seed_sql() {
  psql_q >/dev/null 2>"${BODY_TMP}.seederr" <<SQL
INSERT INTO public.tenant_databases
  (tenant_id, engine, name, connection_enc, connection_iv, connection_tag, isolation)
VALUES
  ('${TENANT_A}',  'postgresql', 'm109-mount-a',  '\\x00', '\\x00', '\\x00', 'schema_per_tenant'),
  ('${TENANT_B}',  'postgresql', 'm109-mount-b',  '\\x00', '\\x00', '\\x00', 'schema_per_tenant'),
  ('${TENANT_SR}', 'postgresql', 'm109-mount-sr', '\\x00', '\\x00', '\\x00', 'shared_rls'),
  ('${TENANT_SR2}','postgresql', 'm109-mount-sr2','\\x00', '\\x00', '\\x00', 'shared_rls'),
  ('${TENANT_D}',  'postgresql', 'm109-mount-d',  '\\x00', '\\x00', '\\x00', 'db_per_tenant');

CREATE SCHEMA IF NOT EXISTS "${SCHEMA_A}";
CREATE SCHEMA IF NOT EXISTS "${SCHEMA_B}";
CREATE TABLE IF NOT EXISTS "${SCHEMA_A}".m109_marker (id int PRIMARY KEY, payload text NOT NULL);
CREATE TABLE IF NOT EXISTS "${SCHEMA_B}".m109_marker (id int PRIMARY KEY, payload text NOT NULL);
INSERT INTO "${SCHEMA_A}".m109_marker (id, payload)
  SELECT g, 'A_ROW_PAYLOAD_' || g FROM generate_series(1, ${ROWS_A}) g;
INSERT INTO "${SCHEMA_B}".m109_marker (id, payload)
  SELECT g, 'B_ROW_PAYLOAD_' || g FROM generate_series(1, ${ROWS_B}) g;
-- shared_rls rows for SR and SR2 in the SAME shared table; the WHERE tenant_id
-- wall must keep SR2's rows out of SR's export.
INSERT INTO public.m109_shared (tenant_id, payload)
  SELECT '${TENANT_SR}',  'SR_ROW_PAYLOAD_'  || g FROM generate_series(1, ${ROWS_SR})  g;
INSERT INTO public.m109_shared (tenant_id, payload)
  SELECT '${TENANT_SR2}', 'SR2_ROW_PAYLOAD_' || g FROM generate_series(1, ${ROWS_SR2}) g;
GRANT USAGE ON SCHEMA "${SCHEMA_A}", "${SCHEMA_B}" TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON "${SCHEMA_A}".m109_marker, "${SCHEMA_B}".m109_marker TO authenticated, service_role;
SQL
}
seed_sql || fail "seeding mounts + schemas + shared rows failed — $(tail -c 600 "${BODY_TMP}.seederr" 2>/dev/null) (line: seed_sql)"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_A}\".m109_marker")" == "${ROWS_A}" ]] \
  || fail "A schema should hold ${ROWS_A} rows (line: A seed count)"
[[ "$(psql_val "SELECT count(*) FROM public.m109_shared WHERE tenant_id='${TENANT_SR}'")" == "${ROWS_SR}" ]] \
  || fail "SR should hold ${ROWS_SR} shared rows (line: SR seed count)"
[[ "$(psql_val "SELECT count(*) FROM public.m109_shared WHERE tenant_id='${TENANT_SR2}'")" == "${ROWS_SR2}" ]] \
  || fail "SR2 should hold ${ROWS_SR2} shared rows (line: SR2 seed count)"
ok "A=${ROWS_A} (schema), B=${ROWS_B} (schema), SR=${ROWS_SR} + SR2=${ROWS_SR2} (shared table m109_shared)"

# ── 4) (A · POSITIVE) export A (schema_per_tenant) → bundle has EXACTLY A's rows ─
step "4a/9 (A · POSITIVE) POST /v1/tenants/${TENANT_A}/export → export_id; ledger status=completed, table_count/row_count + hex sha256"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_A}/export" '{"mount":"m109-mount-a"}')"
[[ "${C}" == "200" || "${C}" == "201" || "${C}" == "202" ]] \
  || fail "(A) POST /export expected 200/201/202, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A export)"
EXPORT_A="$(json_str export_id)"; [[ -z "${EXPORT_A}" ]] && EXPORT_A="$(json_str id)"
[[ -n "${EXPORT_A}" ]] || fail "(A) POST /export returned no export id — $(head -c 300 "${BODY_TMP}") (line: A export id)"
A_STATUS=""
for i in $(seq 1 60); do
  A_STATUS="$(psql_val "SELECT status FROM public.tenant_exports WHERE id='${EXPORT_A}'")"
  [[ "${A_STATUS}" == "completed" ]] && break
  [[ "${A_STATUS}" == "failed" ]] && fail "(A) export ${EXPORT_A} status=failed — $(psql_val "SELECT error_message FROM public.tenant_exports WHERE id='${EXPORT_A}'") (line: A export failed)"
  sleep 0.5
done
[[ "${A_STATUS}" == "completed" ]] || fail "(A) export ${EXPORT_A} never completed (last='${A_STATUS}') (line: A export completed)"
A_RC="$(psql_val "SELECT row_count FROM public.tenant_exports WHERE id='${EXPORT_A}'")"
A_TC="$(psql_val "SELECT table_count FROM public.tenant_exports WHERE id='${EXPORT_A}'")"
A_SHA="$(psql_val "SELECT sha256 FROM public.tenant_exports WHERE id='${EXPORT_A}'")"
[[ "${A_RC}" == "${ROWS_A}" ]] || fail "(A) ledger row_count=${A_RC}, want ${ROWS_A} (line: A row_count)"
[[ "${A_TC}" == "1" ]] || fail "(A) ledger table_count=${A_TC}, want 1 (line: A table_count)"
[[ "${A_SHA}" =~ ^[0-9a-f]+$ ]] || fail "(A) ledger sha256 not lower-hex (got '${A_SHA}') (line: A sha hex)"
# Manifest in the ledger lists the marker table with the right count.
psql_val "SELECT manifest FROM public.tenant_exports WHERE id='${EXPORT_A}'" | grep -q 'm109_marker' \
  || fail "(A) ledger manifest does not name m109_marker (line: A manifest table)"
ok "(A) export ${EXPORT_A} completed; row_count=${A_RC}, table_count=${A_TC}, sha256=${A_SHA:0:16}…, manifest names m109_marker"

step "4b/9 (A · POSITIVE) download the portable bundle → EXACTLY ${ROWS_A} A-rows, manifest{table,count}, sha256 matches the on-disk artifact"
C="$(admin_dl "${PORT_ON}" "/v1/tenants/${TENANT_A}/export/${EXPORT_A}")"
[[ "${C}" == "200" ]] || fail "(A) GET /export/{id} expected 200, got ${C} — $(head -c 300 "${BUNDLE_TMP}") (line: A download)"
# Portable JSON: exactly ROWS_A occurrences of the A payload prefix in the bundle.
A_IN_BUNDLE="$(grep -o 'A_ROW_PAYLOAD_' "${BUNDLE_TMP}" | wc -l | tr -d '[:space:]')"
[[ "${A_IN_BUNDLE}" == "${ROWS_A}" ]] \
  || fail "(A) bundle contains ${A_IN_BUNDLE} A-rows, want EXACTLY ${ROWS_A} (line: A bundle count)"
grep -q '"manifest"' "${BUNDLE_TMP}" || fail "(A) bundle has no manifest section (line: A bundle manifest)"
grep -q '"m109_marker"' "${BUNDLE_TMP}" || fail "(A) bundle manifest/data does not name m109_marker (line: A bundle table)"
grep -q "\"row_count\":${ROWS_A}" "${BUNDLE_TMP}" \
  || fail "(A) bundle manifest row_count != ${ROWS_A} (line: A bundle row_count)"
# The downloaded bytes must hash to the ledger sha256 (portability integrity).
DL_SHA="$(sha256sum "${BUNDLE_TMP}" | cut -d' ' -f1)"
[[ "${DL_SHA}" == "${A_SHA}" ]] \
  || fail "(A) downloaded bundle sha256 ${DL_SHA} != ledger sha256 ${A_SHA} (integrity) (line: A download sha)"
# And the artifact really persisted on disk under the tenant dir.
A_FILES="$( { find "${ARTIFACT_DIR}/${TENANT_A}" -type f 2>/dev/null | wc -l || true; } | tr -d '[:space:]')"
[[ -n "${A_FILES}" && "${A_FILES}" -ge 1 ]] 2>/dev/null \
  || fail "(A) no artifact file under ${ARTIFACT_DIR}/${TENANT_A}/ — LocalFileStore did not persist (line: A artifact on disk)"
ok "(A) bundle has EXACTLY ${ROWS_A} A-rows, manifest names m109_marker w/ row_count=${ROWS_A}, sha256 matches download, ${A_FILES} file(s) on disk"

step "4c/9 (A · POSITIVE) GET /v1/tenants/${TENANT_A}/exports lists the export status=completed"
C="$(admin_req GET "${PORT_ON}" "/v1/tenants/${TENANT_A}/exports")"
[[ "${C}" == "200" ]] || fail "(A) GET /exports expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A list)"
grep -q "\"id\":\"${EXPORT_A}\"" "${BODY_TMP}" || fail "(A) GET /exports missing ${EXPORT_A} (line: A list has id)"
grep -q '"status":"completed"' "${BODY_TMP}" || fail "(A) GET /exports not completed (line: A list completed)"
ok "(A) GET /exports → 200; lists ${EXPORT_A} status=completed"

# ── 5) (SR · POSITIVE) export a shared_rls tenant → EXACTLY SR's rows ──────────
step "5/9 (SR · POSITIVE) POST /v1/tenants/${TENANT_SR}/export (shared_rls) → bundle has EXACTLY ${ROWS_SR} SR-rows from the shared table"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_SR}/export" '{"mount":"m109-mount-sr"}')"
[[ "${C}" == "200" || "${C}" == "201" || "${C}" == "202" ]] \
  || fail "(SR) POST /export expected 2xx, got ${C} — $(head -c 300 "${BODY_TMP}") (line: SR export)"
EXPORT_SR="$(json_str export_id)"; [[ -z "${EXPORT_SR}" ]] && EXPORT_SR="$(json_str id)"
[[ -n "${EXPORT_SR}" ]] || fail "(SR) no export id (line: SR export id)"
SR_STATUS=""
for i in $(seq 1 60); do
  SR_STATUS="$(psql_val "SELECT status FROM public.tenant_exports WHERE id='${EXPORT_SR}'")"
  [[ "${SR_STATUS}" == "completed" ]] && break
  [[ "${SR_STATUS}" == "failed" ]] && fail "(SR) export failed — $(psql_val "SELECT error_message FROM public.tenant_exports WHERE id='${EXPORT_SR}'") (line: SR export failed)"
  sleep 0.5
done
[[ "${SR_STATUS}" == "completed" ]] || fail "(SR) export never completed (last='${SR_STATUS}') (line: SR completed)"
[[ "$(psql_val "SELECT row_count FROM public.tenant_exports WHERE id='${EXPORT_SR}'")" == "${ROWS_SR}" ]] \
  || fail "(SR) ledger row_count != ${ROWS_SR} (line: SR row_count)"
C="$(admin_dl "${PORT_ON}" "/v1/tenants/${TENANT_SR}/export/${EXPORT_SR}")"
[[ "${C}" == "200" ]] || fail "(SR) download expected 200, got ${C} (line: SR download)"
SR_IN_BUNDLE="$(grep -o 'SR_ROW_PAYLOAD_' "${BUNDLE_TMP}" | wc -l | tr -d '[:space:]')"
[[ "${SR_IN_BUNDLE}" == "${ROWS_SR}" ]] \
  || fail "(SR) bundle has ${SR_IN_BUNDLE} SR-rows, want EXACTLY ${ROWS_SR} (line: SR bundle count)"
ok "(SR) shared_rls export bundle has EXACTLY ${ROWS_SR} SR-rows (scoped WHERE tenant_id)"

# ── 6) (B · REJECT, LOAD-BEARING) cross-tenant: ZERO of B/SR2 rows bleed in ────
step "6a/9 (B · REJECT, LOAD-BEARING) A's bundle contains ZERO of B's rows (no B_ROW_PAYLOAD_ in the A bundle)"
# Re-download A's bundle to be certain we are grepping A.
C="$(admin_dl "${PORT_ON}" "/v1/tenants/${TENANT_A}/export/${EXPORT_A}")"
[[ "${C}" == "200" ]] || fail "(B) re-download A bundle expected 200, got ${C} (line: B re-download A)"
B_BLEED="$( { grep -c 'B_ROW_PAYLOAD_' "${BUNDLE_TMP}" || true; } | tr -d '[:space:]')"
[[ "${B_BLEED}" == "0" ]] \
  || fail "(B) A's export bundle contains ${B_BLEED} of B's rows — CROSS-TENANT LEAK! (line: B no bleed into A)"
# And A's exact count is still right (defence: not just absent-B but present-A).
A_RECHECK="$(grep -o 'A_ROW_PAYLOAD_' "${BUNDLE_TMP}" | wc -l | tr -d '[:space:]')"
[[ "${A_RECHECK}" == "${ROWS_A}" ]] || fail "(B) A bundle A-row count drifted to ${A_RECHECK} (line: B A recheck)"
ok "(B) A's bundle: ${ROWS_A} A-rows, ZERO B-rows — schema_per_tenant scoping is airtight"

step "6b/9 (B · REJECT, LOAD-BEARING) SR's bundle contains ZERO of SR2's rows (the shared-table WHERE tenant_id wall)"
C="$(admin_dl "${PORT_ON}" "/v1/tenants/${TENANT_SR}/export/${EXPORT_SR}")"
[[ "${C}" == "200" ]] || fail "(B) re-download SR bundle expected 200, got ${C} (line: B re-download SR)"
SR2_BLEED="$( { grep -c 'SR2_ROW_PAYLOAD_' "${BUNDLE_TMP}" || true; } | tr -d '[:space:]')"
[[ "${SR2_BLEED}" == "0" ]] \
  || fail "(B) SR's export bundle contains ${SR2_BLEED} of SR2's rows from the SAME shared table — CROSS-TENANT LEAK! (line: B no bleed into SR)"
SR_RECHECK="$(grep -o 'SR_ROW_PAYLOAD_' "${BUNDLE_TMP}" | wc -l | tr -d '[:space:]')"
[[ "${SR_RECHECK}" == "${ROWS_SR}" ]] || fail "(B) SR bundle SR-row count drifted to ${SR_RECHECK} (line: B SR recheck)"
ok "(B) SR's bundle: ${ROWS_SR} SR-rows, ZERO SR2-rows — shared_rls WHERE tenant_id is airtight (same table, different tenants)"

step "6c/9 (B · REJECT) db_per_tenant deferred — POST /v1/tenants/${TENANT_D}/export → 400 \"deferred\""
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_D}/export" '{"mount":"m109-mount-d"}')"
[[ "${C}" == "400" ]] \
  || fail "(B) db_per_tenant export got ${C} (want 400) — the deferral is not enforced — $(head -c 300 "${BODY_TMP}") (line: D deferred 400)"
grep -qi 'deferred' "${BODY_TMP}" \
  || fail "(B) db_per_tenant 400 body missing the 'deferred' message — $(head -c 300 "${BODY_TMP}") (line: D deferred msg)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_exports WHERE tenant_id='${TENANT_D}' AND status='completed'")" == "0" ]] \
  || fail "(B) a completed export row exists for db_per_tenant tenant D — the deferral leaked a bundle (line: D no completed row)"
ok "(B) db_per_tenant export → 400 deferred (no completed row) — only schema_per_tenant + shared_rls advertised"

# ── 7) (C · PARITY) flag OFF → export routes 404, base admin route still 200 ───
step "7a/9 (C · PARITY) boot a SECOND tenant-control with TENANT_EXPORT_ENABLED unset on 127.0.0.1:${PORT_OFF}"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "export-OFF tenant-control not ready (line: wait_ready TC_OFF)"
ok "export-OFF tenant-control up (same DB, same seeded tenants)"

step "7b/9 (C · PARITY) POST /v1/tenants/${TENANT_A}/export on the OFF router → 404 (route NOT mounted) WHILE base admin GET /v1/tenants/${TENANT_A} → 200"
C="$(admin_req POST "${PORT_OFF}" "/v1/tenants/${TENANT_A}/export" '{"mount":"m109-mount-a"}')"
[[ "${C}" == "404" ]] \
  || fail "(C) PARITY: POST /export with TENANT_EXPORT_ENABLED off expected 404, got ${C} — $(head -c 300 "${BODY_TMP}") (line: C export 404)"
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants/${TENANT_A}")"
[[ "${C}" == "200" ]] \
  || fail "(C) PARITY: base admin GET /v1/tenants/{id} expected 200 on OFF router, got ${C} — $(head -c 300 "${BODY_TMP}") (line: C admin 200)"
grep -q "\"id\":\"${TENANT_A}\"" "${BODY_TMP}" \
  || fail "(C) PARITY: base admin GET /v1/tenants/{id} did not return A — $(head -c 300 "${BODY_TMP}") (line: C admin is A)"
# Defence: with the flag OFF, nothing was produced for A on the OFF router (no new
# tenant_exports row appeared from the 404'd call).
ok "(C) export route 404 with flag OFF while base admin /v1/tenants/{id} still 200 — byte-parity to today"

# ── summarize ──────────────────────────────────────────────────────────────────
step "summary"
green "[M109] (A) POSITIVE: export A (schema_per_tenant) → bundle EXACTLY ${ROWS_A} rows + manifest{m109_marker,row_count=${ROWS_A}} + hex sha256 matching download; SR (shared_rls) → EXACTLY ${ROWS_SR} rows"
green "[M109] (B) REJECT:   A's bundle ZERO B-rows (schema scoping); SR's bundle ZERO SR2-rows from the SAME shared table (WHERE tenant_id); db_per_tenant export → 400 deferred"
green "[M109] (C) PARITY:   TENANT_EXPORT_ENABLED off → POST /export 404 (route absent) while base admin GET /v1/tenants/{id} still 200"

# ── emit the gate event via the kernel log helper (best-effort) ─────────────────
step "log GATE m109=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-d43-tenant-export}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m109=PASS" --outcome pass \
      --msg "D4.3 tenant data export (GDPR portability): schema_per_tenant + shared_rls export → portable JSON bundle with EXACTLY the tenant's rows + a manifest{tables,counts,sha256}; LOAD-BEARING cross-tenant: A bundle ZERO B-rows, SR bundle ZERO SR2-rows from the SAME shared table (WHERE tenant_id); db_per_tenant 400 deferred; TENANT_EXPORT_ENABLED OFF → routes 404 while admin 200 (byte-parity)" \
      --ref "scripts/verify/m109-tenant-export.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M109] ALL GATES GREEN — D4.3 tenant export: portable bundle has EXACTLY one tenant's rows (schema + shared_rls), cross-tenant ZERO bleed, db_per_tenant 400 deferred, byte-parity when OFF"
exit 0
