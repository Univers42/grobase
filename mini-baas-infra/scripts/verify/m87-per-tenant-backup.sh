#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m87-per-tenant-backup.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M87 — Track-B per-tenant backup/restore (B6) live gate. Today backup is
# WHOLE-CLUSTER only (the pg-backup service pg_dumps the cluster -> MinIO;
# restore-drill = gate m47). B6 makes ONE tenant's data independently backup-
# able + restorable, scoped so a restore of A provably can NEVER touch B. It
# exercises a tenant-control binary built FROM CURRENT source — the EXACT B6
# code — with the Go-native COPY extraction engine + a local-filesystem
# ArtifactStore (NO MinIO container on the RAM-constrained box):
#
#   tenant-control (Go, TENANT_BACKUP_ENABLED=1, BACKUP_DATA_DIR=/artifacts)
#     X-Service-Token: …   (admin)
#       │
#       ▼
#     POST /v1/tenants/{id}/backup            -> backup_id (status pending->completed)
#     GET  /v1/tenants/{id}/backups           -> the caller-tenant's backups (RLS)
#     POST /v1/tenants/{id}/restore/{backupId}-> restore into THAT tenant only
#
#   MVP supports ONLY schema_per_tenant. db_per_tenant (DSN resolver + gate arm
#   pending, B6b), shared_rls + tenant_owned are DEFERRED and rejected 400
#   "isolation not supported for backup/restore (deferred)".
#
#   (A · POSITIVE) seed A as a schema_per_tenant mount with 100 deterministic
#       rows in <tenant_a>.m87_marker. Backup A
#       -> assert the artifact exists under BACKUP_DATA_DIR/A/, size_bytes>0,
#       sha256 is hex, GET /backups lists it status=completed. MUTATE A (DELETE
#       all marker rows -> count 0). Restore A -> A's rows return EXACTLY
#       (count==100 AND md5(string_agg) == baseline checksum).
#   (B · REJECT, LOAD-BEARING) B (50 rows in <tenant_b>.m87_marker) must be
#       byte-UNTOUCHED through A's whole backup/mutate/restore cycle (count +
#       md5 == B baseline). B can NOT restore A's backup: POST
#       /v1/tenants/B/restore/{A_backup_id} -> 403/404 (backup.tenant_id != B).
#       A shared_rls AND a db_per_tenant mount's backup -> 400 deferred. ATOMICITY:
#       a forced mid-restore COPY failure rolls the WHOLE restore back (the first
#       table is NOT left wiped/partial). A gate that only shows the happy path is
#       VACUOUS; the B-untouched + cross-tenant-403 + deferred-400 + atomic-rollback
#       assertions are the load-bearing proof.
#   (C · PARITY) a SECOND tenant-control with TENANT_BACKUP_ENABLED unset: POST
#       /v1/tenants/{id}/backup -> 404 (route NOT mounted) WHILE the base admin
#       route GET /v1/tenants/{id} (service token) STILL 200 = byte-parity.
#
# Seeding: tenants + keys via the EXISTING service-token admin endpoints (POST
# /v1/tenants, X-Service-Token); the schema_per_tenant mount + its rows are
# created directly in the scratch postgres (CREATE SCHEMA + a tenant_databases
# row with isolation='schema_per_tenant'), exactly the namespace the backup
# service derives from tenantSchema(slug). The schema name is computed in-gate
# with the SAME sanitizer the Go tenantSchema() uses (lowercase, [a-z0-9_],
# others->'_', trim '_', truncate 50, prefix tenant_).
#
# ISOLATED by design (mirrors m83/m80): scratch postgres (prelude + REAL 005 +
# 032 + 040 + 041 + 042) + two tenant-control binaries built FROM CURRENT
# source, ALL on a PRIVATE network, every name suffixed with $$, a local
# artifact dir under /mnt/storage, an EXIT-trap removing EVERYTHING. It NEVER
# touches a mini-baas-* container/network/image/volume and NEVER edits the live
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
MIGRATION_042="${MIG_DIR}/042_tenant_backups.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M87] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M87] FAIL — $*"; exit 1; }

PG_IMAGE="${M87_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m87-tc-$$:scratch"
NET="m87net-$$"
PG="m87-pg-$$"
TC_ON="m87-tc-on-$$"      # TENANT_BACKUP_ENABLED=1  (A · positive / B · reject)
TC_OFF="m87-tc-off-$$"    # TENANT_BACKUP_ENABLED unset (C · parity)
PORT_ON="${M87_PORT_ON:-18988}"
PORT_OFF="${M87_PORT_OFF:-18989}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m87-internal-service-token-$$"
TENANT_A="m87-a-$$"
TENANT_B="m87-b-$$"
TENANT_S="m87-s-$$"               # shared_rls mount -> backup must 400 (deferred)
TENANT_D="m87-d-$$"               # db_per_tenant mount -> backup must 400 (deferred, B6b)
TENANT_T="m87-t-$$"               # atomicity tenant: 2-table schema, forced COPY failure
# Per-run artifact dir on the big disk (kernel: Docker work on /mnt/storage),
# under the user-owned bench base so the gate can mkdir it without sudo (the
# /mnt/storage root is root-owned). Overridable via M87_ARTIFACT_DIR.
ARTIFACT_DIR="${M87_ARTIFACT_DIR:-/mnt/storage/bench/m87-artifacts-$$}"
ROWS_A=100
ROWS_B=50
ROWS_T=5
BODY_TMP="$(mktemp)"

# Derive the schema name EXACTLY like Go tenantSchema(id): lowercase, keep
# [a-z0-9_], replace others with '_', trim leading/trailing '_', truncate 50,
# prefix "tenant_". The $$-suffixed slugs are already lowercase + only contain
# [a-z0-9-], so '-' -> '_' is the only substitution.
tenant_schema() { # $1=slug
  local s frag
  s="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_]/_/g')"
  frag="$(printf '%s' "$s" | sed 's/^_*//; s/_*$//')"
  frag="${frag:0:50}"
  printf 'tenant_%s' "${frag}"
}
SCHEMA_A="$(tenant_schema "${TENANT_A}")"
SCHEMA_B="$(tenant_schema "${TENANT_B}")"
SCHEMA_T="$(tenant_schema "${TENANT_T}")"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
  rm -rf "${ARTIFACT_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Apply one migration file the SAME way `make migrate` does: strip the leading
# `#` 42-header lines (sed '/^#/d') before piping to psql, so the header is never
# fed to the SQL parser. $1 = file.
apply_migration() { # $1=file
  sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1
}

# Admin (service-token) request → echo HTTP status, body→BODY_TMP.
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

# Extract a top-level JSON string field value off BODY_TMP. Tolerates ZERO
# matches (grep wrapped in `|| true` so pipefail+set -e does not kill us on a
# missing field — an empty result is a normal "field absent" outcome). $1=field.
json_str() { # $1=field
  { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'
}

# Extract a top-level JSON numeric field value off BODY_TMP (size_bytes etc.).
json_num() { # $1=field
  { grep -o "\"$1\":[0-9]*" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://'
}

wait_ready() { # $1=container $2=port
  local i
  for i in $(seq 1 60); do
    # /health/live is the shared router liveness route (used by the binary's own
    # --healthcheck); a 200 there means the HTTP server + EnsureSchema are up.
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/health/live" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

# ── 0) build the scratch tenant-control FROM CURRENT (drafted) source ──────────
step "0/9 build scratch tenant-control from CURRENT source (the B6 backup/restore code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — gate must exercise the drafted backup/restore code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres + prelude + REAL 005/032/040/041/042 ────────────
step "1/9 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state (line: PG ready loop)"
  sleep 0.5
done
ok "postgres up"

step "1b/9 apply prelude (schema_migrations, auth.current_tenant_id, roles), then REAL 005 + 032 + 040 + 041 + 042"
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
-- migration), so the gate — which boots tenant-control only — must scaffold it,
-- exactly like schema_migrations / roles above. The backup service reads
-- `isolation` from it keyed by the tenant slug; tenant_id holds the slug (TEXT)
-- the /v1/tenants/{id} path carries (the API id), which is what isolationFor
-- binds on. The CHECK lists all four real isolation models so a db_per_tenant
-- row INSERTs (then gets rejected at the BACKUP layer with 400 deferred).
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
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"; sleep 0.5; done
apply_migration "${MIGRATION_005}" || fail "real migration 005_add_tenant_table.sql failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032_tenants.sql failed to apply (line: apply 032)"
apply_migration "${MIGRATION_040}" || fail "real migration 040_tenant_usage.sql failed to apply (line: apply 040)"
apply_migration "${MIGRATION_041}" || fail "real migration 041_tenant_billing.sql failed to apply (line: apply 041)"
[[ -f "${MIGRATION_042}" ]] || fail "migration 042_tenant_backups.sql is MISSING — the B6 migration slice must land before m87 can run (line: 042 exists)"
apply_migration "${MIGRATION_042}" || fail "real migration 042_tenant_backups.sql failed to apply (line: apply 042)"
[[ "$(psql_val "SELECT count(*) FROM public.tenants")" == "0" ]] || fail "tenants should start EMPTY (line: 032 empty check)"
[[ "$(psql_val "SELECT to_regclass('public.tenant_databases') IS NOT NULL")" == "t" ]] \
  || fail "public.tenant_databases not scaffolded by the prelude (line: tenant_databases check)"
[[ "$(psql_val "SELECT to_regclass('public.tenant_backups') IS NOT NULL")" == "t" ]] \
  || fail "public.tenant_backups not created by migration 042 (line: 042 table check)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_backups")" == "0" ]] \
  || fail "tenant_backups should start EMPTY (line: 042 empty check)"
ok "migrations 005 + 032 + 040 + 041 + 042 applied — tenants / tenant_databases / tenant_backups exist and are empty"

# ── 2) boot the BACKUP-ON tenant-control (TENANT_BACKUP_ENABLED=1) ─────────────
step "2/9 boot tenant-control TENANT_BACKUP_ENABLED=1, BACKUP_DATA_DIR=/artifacts on 127.0.0.1:${PORT_ON} (A · positive / B · reject)"
mkdir -p "${ARTIFACT_DIR}" 2>/dev/null \
  || fail "could not create local artifact dir ${ARTIFACT_DIR} (run once: sudo install -d -o \$USER /mnt/storage/$(basename "${ARTIFACT_DIR%-$$}")) (line: artifact mkdir)"
# tenant-control runs as a non-host uid inside the container, so it cannot write
# to a bind mount owned by the host user; make the ephemeral per-run ($$) artifact
# dir world-writable so the LocalFileStore can mkdir/write under /artifacts. The
# dir is removed by the EXIT trap, so 777 is gate-local and short-lived.
chmod 777 "${ARTIFACT_DIR}" 2>/dev/null || true
# Run as the HOST uid:gid so the LocalFileStore's per-tenant subdirs (created
# 0750, owner-only) are owned by the host user — otherwise the host-side artifact
# verification (find under the bind mount) can't traverse a subdir owned by the
# image's default appuser. The Go binary only needs /artifacts (host-owned) +
# network, so an arbitrary uid is fine.
docker run -d --name "${TC_ON}" --network "${NET}" \
  --user "$(id -u):$(id -g)" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_BACKUP_ENABLED=1 \
  -e BACKUP_DATA_DIR=/artifacts \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -v "${ARTIFACT_DIR}:/artifacts" \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "backup-ON tenant-control not ready (line: wait_ready TC_ON)"
ok "backup-ON tenant-control up (LocalFileStore -> /artifacts, backup/restore routes mounted)"

# ── 3) SEED two tenants + one shared_rls tenant via the admin endpoints, then
#       create A/B schema_per_tenant mounts + deterministic rows directly in PG ─
step "3/9 seed A(${TENANT_A}) + B(${TENANT_B}) + S(${TENANT_S},shared_rls) + D(${TENANT_D},db_per_tenant) + T(${TENANT_T},atomicity) via POST /v1/tenants (X-Service-Token)"
C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${TENANT_A}\",\"name\":\"A\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant A expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed A)"
C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${TENANT_B}\",\"name\":\"B\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant B expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed B)"
C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${TENANT_S}\",\"name\":\"S\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant S expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed S)"
C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${TENANT_D}\",\"name\":\"D\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant D expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed D)"
C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${TENANT_T}\",\"name\":\"T\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant T expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed T)"
ok "tenants A + B + S + D + T created (all nano)"

step "3b/9 register mounts (A/B/T schema_per_tenant, S shared_rls, D db_per_tenant); create A/B/T schemas + marker/atomicity rows"
# The backup service looks up isolation from public.tenant_databases and, for
# schema_per_tenant, derives the schema with tenantSchema(slug) (= ${SCHEMA_A} /
# ${SCHEMA_B}). connection_enc/iv/tag are NOT NULL — insert dummy non-empty
# bytea (a schema_per_tenant backup uses the LOCAL pool + derived schema, never
# the DSN, so the placeholder is inert). S is a shared_rls mount whose backup
# must be REJECTED 400 (deferred) before any DSN is touched.
seed_sql() {
  psql_q >/dev/null 2>"${BODY_TMP}.seederr" <<SQL
INSERT INTO public.tenant_databases
  (tenant_id, engine, name, connection_enc, connection_iv, connection_tag, isolation)
VALUES
  ('${TENANT_A}', 'postgresql', 'm87-mount-a', '\\x00', '\\x00', '\\x00', 'schema_per_tenant'),
  ('${TENANT_B}', 'postgresql', 'm87-mount-b', '\\x00', '\\x00', '\\x00', 'schema_per_tenant'),
  ('${TENANT_S}', 'postgresql', 'm87-mount-s', '\\x00', '\\x00', '\\x00', 'shared_rls'),
  ('${TENANT_D}', 'postgresql', 'm87-mount-d', '\\x00', '\\x00', '\\x00', 'db_per_tenant'),
  ('${TENANT_T}', 'postgresql', 'm87-mount-t', '\\x00', '\\x00', '\\x00', 'schema_per_tenant');

CREATE SCHEMA IF NOT EXISTS "${SCHEMA_A}";
CREATE SCHEMA IF NOT EXISTS "${SCHEMA_B}";
CREATE SCHEMA IF NOT EXISTS "${SCHEMA_T}";
CREATE TABLE IF NOT EXISTS "${SCHEMA_A}".m87_marker (id int PRIMARY KEY, payload text NOT NULL);
CREATE TABLE IF NOT EXISTS "${SCHEMA_B}".m87_marker (id int PRIMARY KEY, payload text NOT NULL);
-- ATOM tenant T: TWO tables. enumerateTables orders by table_name, so t_aa is
-- backed up/restored BEFORE t_bb. The atomicity arm breaks t_bb so its COPY
-- fails AFTER t_aa's COPY has already succeeded — proving t_aa's COPY rolls back
-- with the aborted tx.
CREATE TABLE IF NOT EXISTS "${SCHEMA_T}".t_aa (id int PRIMARY KEY, payload text NOT NULL);
CREATE TABLE IF NOT EXISTS "${SCHEMA_T}".t_bb (id int PRIMARY KEY, payload text NOT NULL);
INSERT INTO "${SCHEMA_A}".m87_marker (id, payload)
  SELECT g, 'a-row-' || g FROM generate_series(1, ${ROWS_A}) g;
INSERT INTO "${SCHEMA_B}".m87_marker (id, payload)
  SELECT g, 'b-row-' || g FROM generate_series(1, ${ROWS_B}) g;
INSERT INTO "${SCHEMA_T}".t_aa (id, payload) SELECT g, 't-aa-' || g FROM generate_series(1, ${ROWS_T}) g;
INSERT INTO "${SCHEMA_T}".t_bb (id, payload) SELECT g, 't-bb-' || g FROM generate_series(1, ${ROWS_T}) g;
GRANT USAGE ON SCHEMA "${SCHEMA_A}", "${SCHEMA_B}", "${SCHEMA_T}" TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON "${SCHEMA_A}".m87_marker, "${SCHEMA_B}".m87_marker,
     "${SCHEMA_T}".t_aa, "${SCHEMA_T}".t_bb TO authenticated, service_role;
SQL
}
seed_sql || fail "seeding tenant_databases mounts + A/B/T schemas failed — $(tail -c 600 "${BODY_TMP}.seederr" 2>/dev/null) (line: seed_sql)"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_A}\".m87_marker")" == "${ROWS_A}" ]] \
  || fail "A schema ${SCHEMA_A}.m87_marker should hold ${ROWS_A} rows (line: A seed count)"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_B}\".m87_marker")" == "${ROWS_B}" ]] \
  || fail "B schema ${SCHEMA_B}.m87_marker should hold ${ROWS_B} rows (line: B seed count)"
ok "A=${ROWS_A} rows in ${SCHEMA_A}.m87_marker, B=${ROWS_B} rows in ${SCHEMA_B}.m87_marker; S registered shared_rls"

step "3c/9 capture deterministic baseline checksums md5(string_agg(t::text,'|' ORDER BY id))"
# A scope-level fingerprint that is sensitive to BOTH row count and content/order
# — a restore that returns the right count but wrong bytes still fails this.
CK_SQL_A="SELECT md5(string_agg(t::text, '|' ORDER BY id)) FROM \"${SCHEMA_A}\".m87_marker t"
CK_SQL_B="SELECT md5(string_agg(t::text, '|' ORDER BY id)) FROM \"${SCHEMA_B}\".m87_marker t"
BASE_CK_A="$(psql_val "${CK_SQL_A}")"
BASE_CK_B="$(psql_val "${CK_SQL_B}")"
[[ -n "${BASE_CK_A}" ]] || fail "could not compute A baseline checksum (line: A baseline ck)"
[[ -n "${BASE_CK_B}" ]] || fail "could not compute B baseline checksum (line: B baseline ck)"
ok "baselines captured — A=${BASE_CK_A} B=${BASE_CK_B}"

# ── 4) (A · POSITIVE) backup A → assert artifact + tenant_backups row ──────────
step "4a/9 (A · POSITIVE) POST /v1/tenants/${TENANT_A}/backup → backup_id; artifact under ${ARTIFACT_DIR}/${TENANT_A}/; size>0; sha256 hex; listed completed"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_A}/backup" '{"mount":"m87-mount-a"}')"
[[ "${C}" == "200" || "${C}" == "201" || "${C}" == "202" ]] \
  || fail "(A) POST /backup expected 200/201/202, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A backup)"
BACKUP_A="$(json_str backup_id)"
[[ -z "${BACKUP_A}" ]] && BACKUP_A="$(json_str id)"   # tolerate {id} or {backup_id}
[[ -n "${BACKUP_A}" ]] || fail "(A) POST /backup returned no backup id — $(head -c 300 "${BODY_TMP}") (line: A backup id)"
# The backup is recorded pending->completed asynchronously by the service; poll
# tenant_backups for the terminal status (completed) by id.
A_STATUS=""
for i in $(seq 1 60); do
  A_STATUS="$(psql_val "SELECT status FROM public.tenant_backups WHERE id='${BACKUP_A}'")"
  [[ "${A_STATUS}" == "completed" ]] && break
  [[ "${A_STATUS}" == "failed" ]] && fail "(A) backup ${BACKUP_A} reported status=failed — $(psql_val "SELECT error_message FROM public.tenant_backups WHERE id='${BACKUP_A}'") (line: A backup failed)"
  sleep 0.5
done
[[ "${A_STATUS}" == "completed" ]] || fail "(A) backup ${BACKUP_A} never reached status=completed (last='${A_STATUS}') (line: A backup completed)"
A_SIZE="$(psql_val "SELECT size_bytes FROM public.tenant_backups WHERE id='${BACKUP_A}'")"
[[ -n "${A_SIZE}" && "${A_SIZE}" -gt 0 ]] 2>/dev/null \
  || fail "(A) tenant_backups.size_bytes for ${BACKUP_A} not >0 (got '${A_SIZE}') (line: A size>0)"
A_SHA="$(psql_val "SELECT sha256 FROM public.tenant_backups WHERE id='${BACKUP_A}'")"
[[ "${A_SHA}" =~ ^[0-9a-f]+$ ]] \
  || fail "(A) tenant_backups.sha256 for ${BACKUP_A} is not lower-hex (got '${A_SHA}') (line: A sha hex)"
# Artifact really exists on the mounted local store (the LocalFileStore writes
# BACKUP_DATA_DIR/{tenant}/{backupId}). Count any file under the tenant dir.
A_FILES="$( { find "${ARTIFACT_DIR}/${TENANT_A}" -type f 2>/dev/null | wc -l || true; } | tr -d '[:space:]')"
[[ -n "${A_FILES}" && "${A_FILES}" -ge 1 ]] 2>/dev/null \
  || fail "(A) no artifact file found under ${ARTIFACT_DIR}/${TENANT_A}/ — LocalFileStore did not persist (line: A artifact on disk)"
ok "(A) backup ${BACKUP_A} completed; size_bytes=${A_SIZE}; sha256=${A_SHA:0:16}…; ${A_FILES} artifact file(s) on disk"

step "4b/9 (A · POSITIVE) GET /v1/tenants/${TENANT_A}/backups lists the backup with status=completed"
C="$(admin_req GET "${PORT_ON}" "/v1/tenants/${TENANT_A}/backups")"
[[ "${C}" == "200" ]] || fail "(A) GET /backups expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A list backups)"
grep -q "\"id\":\"${BACKUP_A}\"" "${BODY_TMP}" \
  || fail "(A) GET /backups does not list backup ${BACKUP_A} — $(head -c 300 "${BODY_TMP}") (line: A list has id)"
grep -q '"status":"completed"' "${BODY_TMP}" \
  || fail "(A) GET /backups does not show status=completed — $(head -c 300 "${BODY_TMP}") (line: A list completed)"
ok "(A) GET /backups → 200; lists backup ${BACKUP_A} status=completed"

# ── 5) MUTATE A (the destructive step the restore must undo) ───────────────────
step "5/9 MUTATE A: DELETE FROM ${SCHEMA_A}.m87_marker → count 0"
psql_q -c "DELETE FROM \"${SCHEMA_A}\".m87_marker;" >/dev/null 2>&1 \
  || fail "(A) could not DELETE A's marker rows (line: A mutate delete)"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_A}\".m87_marker")" == "0" ]] \
  || fail "(A) A's marker rows not actually deleted (line: A mutate count 0)"
ok "(A) A's rows wiped (count 0) — restore must bring back EXACTLY ${ROWS_A} rows"

# ── 6) (A · POSITIVE) restore A → rows return EXACTLY (count + checksum) ───────
step "6/9 (A · POSITIVE) POST /v1/tenants/${TENANT_A}/restore/${BACKUP_A} → A's rows return EXACTLY (count==${ROWS_A} AND md5==baseline)"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_A}/restore/${BACKUP_A}")"
[[ "${C}" == "200" || "${C}" == "201" || "${C}" == "202" ]] \
  || fail "(A) POST /restore expected 200/201/202, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A restore)"
# Restore may be async (status restoring->restored); wait for the row count to
# settle back to ROWS_A before fingerprinting.
A_RESTORED_CT=""
for i in $(seq 1 60); do
  A_RESTORED_CT="$(psql_val "SELECT count(*) FROM \"${SCHEMA_A}\".m87_marker")"
  [[ "${A_RESTORED_CT}" == "${ROWS_A}" ]] && break
  sleep 0.5
done
[[ "${A_RESTORED_CT}" == "${ROWS_A}" ]] \
  || fail "(A) restore did not return ${ROWS_A} rows (got '${A_RESTORED_CT}') — $(head -c 300 "${BODY_TMP}") (line: A restore count)"
A_CK_AFTER="$(psql_val "${CK_SQL_A}")"
[[ "${A_CK_AFTER}" == "${BASE_CK_A}" ]] \
  || fail "(A) restore checksum mismatch — got ${A_CK_AFTER}, baseline ${BASE_CK_A} (count right, BYTES wrong) (line: A restore checksum)"
ok "(A) restore EXACT — count==${ROWS_A} AND md5==baseline (${BASE_CK_A}); the round-trip is lossless"

# ── 7) (B · REJECT, LOAD-BEARING) B byte-UNTOUCHED throughout ──────────────────
step "7/9 (B · REJECT, LOAD-BEARING) B byte-UNTOUCHED — count + md5 of ${SCHEMA_B}.m87_marker == B baseline"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_B}\".m87_marker")" == "${ROWS_B}" ]] \
  || fail "(B) B's row count changed during A's backup/mutate/restore — cross-tenant write! (line: B count untouched)"
B_CK_AFTER="$(psql_val "${CK_SQL_B}")"
[[ "${B_CK_AFTER}" == "${BASE_CK_B}" ]] \
  || fail "(B) B's checksum changed during A's restore — got ${B_CK_AFTER}, baseline ${BASE_CK_B}: cross-tenant corruption! (line: B checksum untouched)"
ok "(B) B byte-UNTOUCHED through A's whole cycle (count==${ROWS_B}, md5==${BASE_CK_B}) — restore is scoped to A by construction"

# ── 8) (B · REJECT) cross-tenant restore + shared_rls deferred + parity ────────
step "8a/9 (B · REJECT, LOAD-BEARING) cross-tenant restore — POST /v1/tenants/${TENANT_B}/restore/${BACKUP_A} → 403/404 (backup.tenant_id != B)"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_B}/restore/${BACKUP_A}")"
[[ "${C}" == "403" || "${C}" == "404" ]] \
  || fail "(B) cross-tenant restore of A's backup under B got ${C} (want 403/404) — caller==owner is NOT enforced before DDL! (line: B cross-tenant restore)"
# And it really did NOT touch B (defence in depth: even if the route had run, B
# must be intact). Re-assert B's fingerprint after the rejected attempt.
[[ "$(psql_val "${CK_SQL_B}")" == "${BASE_CK_B}" ]] \
  || fail "(B) B's data changed after a REJECTED cross-tenant restore attempt (line: B intact post-reject)"
ok "(B) cross-tenant restore rejected ${C}; B still byte-identical — ownership validated before any DDL"

step "8b/9 (B · REJECT) shared_rls deferred — POST /v1/tenants/${TENANT_S}/backup → 400 \"isolation not supported for backup/restore (deferred)\""
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_S}/backup" '{"mount":"m87-mount-s"}')"
[[ "${C}" == "400" ]] \
  || fail "(B) shared_rls backup got ${C} (want 400) — the deferral is not enforced — $(head -c 300 "${BODY_TMP}") (line: S deferred 400)"
grep -qi 'deferred' "${BODY_TMP}" \
  || fail "(B) shared_rls 400 body missing the 'deferred' message — $(head -c 300 "${BODY_TMP}") (line: S deferred msg)"
# No backup row should have been recorded for S (rejected before INSERT, or
# rolled back) — defence that the deferral is clean, not a half-written row.
[[ "$(psql_val "SELECT count(*) FROM public.tenant_backups WHERE tenant_id='${TENANT_S}' AND status='completed'")" == "0" ]] \
  || fail "(B) a completed backup row exists for shared_rls tenant S — the deferral leaked an artifact (line: S no completed row)"
ok "(B) shared_rls backup → 400 deferred (message present, no completed row) — MVP scope honestly enforced"

step "8c/9 (B · REJECT) db_per_tenant deferred (B6b) — POST /v1/tenants/${TENANT_D}/backup → 400 \"deferred\""
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_D}/backup" '{"mount":"m87-mount-d"}')"
[[ "${C}" == "400" ]] \
  || fail "(B) db_per_tenant backup got ${C} (want 400) — the B6b deferral is not enforced — $(head -c 300 "${BODY_TMP}") (line: D deferred 400)"
grep -qi 'deferred' "${BODY_TMP}" \
  || fail "(B) db_per_tenant 400 body missing the 'deferred' message — $(head -c 300 "${BODY_TMP}") (line: D deferred msg)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_backups WHERE tenant_id='${TENANT_D}' AND status='completed'")" == "0" ]] \
  || fail "(B) a completed backup row exists for db_per_tenant tenant D — the deferral leaked an artifact (line: D no completed row)"
ok "(B) db_per_tenant backup → 400 deferred (no completed row) — only schema_per_tenant is advertised (db_per_tenant = B6b)"

# ── 8d) (SAFETY · LOAD-BEARING) restore atomicity: a forced mid-restore COPY
#        failure rolls the WHOLE restore back (TRUNCATEs + already-replayed COPYs).
#        T has two tables (t_aa < t_bb). Back up T, mutate both to a single
#        sentinel row (id=999, NOT in the backup id range 1..${ROWS_T}), then DROP
#        a column off t_bb so its COPY (2-col artifact into a 1-col table) FAILS
#        *after* t_aa's COPY already succeeded. Atomic ⇒ the tx rolls back and
#        t_aa returns to EXACTLY the sentinel (count==1); a non-atomic restore
#        would leave t_aa holding the replayed rows (count != 1). ─────────────────
step "8d/9 (SAFETY · LOAD-BEARING) restore ATOMICITY — forced t_bb COPY failure must roll t_aa back to the sentinel"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_T}/backup" '{"mount":"m87-mount-t"}')"
[[ "${C}" == "200" || "${C}" == "201" || "${C}" == "202" ]] \
  || fail "(ATOM) backup T expected 200/201/202, got ${C} — $(head -c 300 "${BODY_TMP}") (line: T backup)"
BACKUP_T="$(json_str backup_id)"; [[ -z "${BACKUP_T}" ]] && BACKUP_T="$(json_str id)"
[[ -n "${BACKUP_T}" ]] || fail "(ATOM) backup T returned no id — $(head -c 300 "${BODY_TMP}") (line: T backup id)"
T_STATUS=""
for i in $(seq 1 60); do
  T_STATUS="$(psql_val "SELECT status FROM public.tenant_backups WHERE id='${BACKUP_T}'")"
  [[ "${T_STATUS}" == "completed" ]] && break
  [[ "${T_STATUS}" == "failed" ]] && fail "(ATOM) backup T failed — $(psql_val "SELECT error_message FROM public.tenant_backups WHERE id='${BACKUP_T}'") (line: T backup failed)"
  sleep 0.5
done
[[ "${T_STATUS}" == "completed" ]] || fail "(ATOM) backup T never completed (last='${T_STATUS}') (line: T backup completed)"
# Mutate BOTH tables to a single recognizable sentinel row (id=999) NOT present in
# the backup (ids 1..${ROWS_T}); break t_bb so the restore's COPY into it FAILS
# (2-col artifact, 1-col table) AFTER t_aa's COPY has already run in the same tx.
psql_q >/dev/null 2>&1 <<SQL || fail "(ATOM) could not mutate T to the sentinel state (line: T mutate)"
DELETE FROM "${SCHEMA_T}".t_aa; DELETE FROM "${SCHEMA_T}".t_bb;
INSERT INTO "${SCHEMA_T}".t_aa (id, payload) VALUES (999, 'sentinel');
INSERT INTO "${SCHEMA_T}".t_bb (id, payload) VALUES (999, 'sentinel');
ALTER TABLE "${SCHEMA_T}".t_bb DROP COLUMN payload;
SQL
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_T}\".t_aa")" == "1" ]] \
  || fail "(ATOM) pre-restore t_aa should hold exactly the sentinel row (line: T pre-restore count)"
# Attempt the restore — it MUST fail (t_bb COPY errors) and roll back ATOMICALLY.
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_T}/restore/${BACKUP_T}")"
[[ "${C}" != "200" && "${C}" != "201" && "${C}" != "202" ]] \
  || fail "(ATOM) restore with a broken t_bb returned success ${C} — the forced COPY failure did not propagate (line: T restore must fail)"
# Assert ROLLBACK: t_aa must STILL be exactly the sentinel (count==1, id=999) —
# t_aa's COPY rolled back with the aborted tx. A non-atomic restore would show !=1.
T_AA_CT=""
for i in $(seq 1 20); do
  T_AA_CT="$(psql_val "SELECT count(*) FROM \"${SCHEMA_T}\".t_aa")"
  [[ -n "${T_AA_CT}" ]] && break
  sleep 0.25
done
[[ "${T_AA_CT}" == "1" ]] \
  || fail "(ATOM) NON-ATOMIC restore — t_aa holds ${T_AA_CT} rows after a failed restore (want 1: the sentinel); t_aa's COPY did NOT roll back with the tx (line: T atomic count)"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_T}\".t_aa WHERE id=999")" == "1" ]] \
  || fail "(ATOM) the sentinel row vanished — the TRUNCATE committed without the COPY (not atomic) (line: T sentinel survives)"
[[ "$(psql_val "SELECT status FROM public.tenant_backups WHERE id='${BACKUP_T}'")" == "failed" ]] \
  || fail "(ATOM) ledger status for the broken restore is not 'failed' — the failure was swallowed (line: T ledger failed)"
ok "(ATOM) forced mid-restore COPY failure rolled back ATOMICALLY — t_aa kept exactly the sentinel, ledger='failed'; restore is all-or-nothing"

# ── 9) (C · PARITY) flag OFF → backup routes 404, base admin route still 200 ──
step "9a/9 (C · PARITY) boot a SECOND tenant-control with TENANT_BACKUP_ENABLED unset on 127.0.0.1:${PORT_OFF}"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "backup-OFF tenant-control not ready (line: wait_ready TC_OFF)"
ok "backup-OFF tenant-control up (same DB, same seeded tenants)"

step "9b/9 (C · PARITY) POST /v1/tenants/${TENANT_A}/backup on the OFF router → 404 (route NOT mounted) WHILE base admin GET /v1/tenants/${TENANT_A} → 200"
C="$(admin_req POST "${PORT_OFF}" "/v1/tenants/${TENANT_A}/backup" '{"mount":"m87-mount-a"}')"
[[ "${C}" == "404" ]] \
  || fail "(C) PARITY: POST /backup with TENANT_BACKUP_ENABLED off expected 404 (route absent), got ${C} — $(head -c 300 "${BODY_TMP}") (line: C backup 404)"
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants/${TENANT_A}")"
[[ "${C}" == "200" ]] \
  || fail "(C) PARITY: base admin GET /v1/tenants/{id} expected 200 on OFF router, got ${C} — $(head -c 300 "${BODY_TMP}") (line: C admin 200)"
grep -q "\"id\":\"${TENANT_A}\"" "${BODY_TMP}" \
  || fail "(C) PARITY: base admin GET /v1/tenants/{id} did not return A — $(head -c 300 "${BODY_TMP}") (line: C admin is A)"
ok "(C) backup route 404 with flag OFF while base admin /v1/tenants/{id} still 200 — byte-parity to today"

# ── summarize ──────────────────────────────────────────────────────────────────
step "summary"
green "[M87] (A) POSITIVE: backup A (artifact on disk, size>0, sha256 hex, listed completed) → DELETE A → restore A → EXACTLY ${ROWS_A} rows + md5==baseline"
green "[M87] (B) REJECT:   B byte-untouched throughout (count+md5); cross-tenant restore of A under B → 403/404; shared_rls + db_per_tenant backup → 400 deferred"
green "[M87] (SAFETY):     forced mid-restore COPY failure rolled back ATOMICALLY — t_aa kept exactly the sentinel, ledger='failed'"
green "[M87] (C) PARITY:   TENANT_BACKUP_ENABLED off → POST /backup 404 (route absent) while base admin GET /v1/tenants/{id} still 200"

# ── emit the gate event via the kernel log helper (best-effort) ─────────────────
step "log GATE m87=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-b6-per-tenant-backup}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m87=PASS" --outcome pass \
      --msg "B6 per-tenant backup/restore: schema_per_tenant backup→mutate→restore A EXACT (count+checksum); B byte-untouched (load-bearing); cross-tenant restore 403/404; shared_rls + db_per_tenant backup 400 deferred (db_per_tenant=B6b); forced mid-restore COPY failure rolls back ATOMICALLY; TENANT_BACKUP_ENABLED OFF → routes 404 while admin 200 (byte-parity)" \
      --ref "scripts/verify/m87-per-tenant-backup.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M87] ALL GATES GREEN — B6 per-tenant backup/restore: A round-trips EXACT, B byte-untouched, cross-tenant 403/404, shared_rls + db_per_tenant 400 deferred, restore atomic on failure, byte-parity when OFF"
exit 0
