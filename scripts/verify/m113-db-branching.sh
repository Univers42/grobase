#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m113-db-branching.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M113 — Track-E DB BRANCHING (Supabase-parity "branches") live gate. A tenant
# can create a named BRANCH of a schema_per_tenant mount — an isolated schema-clone
# (the parent's tables + a full row copy) for preview/staging — list them, and
# drop them. Unlike B6 backup (a restore COPY artifact) or D4.3 export (a portable
# JSON bundle), a branch is a LIVE schema sitting next to the parent in the SAME
# control-plane Postgres: CREATE SCHEMA <branch_schema>, then per parent BASE TABLE
# `CREATE TABLE … (LIKE … INCLUDING ALL)` + `INSERT … SELECT *` — all over the pgx
# pool, NO pg_dump. shared_rls and db_per_tenant are DEFERRED (400 "deferred").
#
# It exercises a tenant-control binary built FROM CURRENT source (the EXACT DB
# branching code):
#
#   tenant-control (Go, DB_BRANCHING_ENABLED=1)
#     X-Service-Token: …   (admin)
#       │
#       ▼
#     POST   /v1/tenants/{id}/branches            -> 201 {id, branch_schema, table_count, row_count}
#     GET    /v1/tenants/{id}/branches            -> 200 [{id, branch_name, status, ...}]
#     DELETE /v1/tenants/{id}/branches/{branchId} -> 204 (schema dropped + ledger row gone)
#
#   (A · POSITIVE) provision a schema_per_tenant tenant A + seed N rows in its
#       schema -> POST branch -> the branch schema EXISTS with EXACTLY N rows copied
#       + a ledger row status=completed with the right table_count/row_count.
#   (B · REJECT, LOAD-BEARING) three walls, all load-bearing:
#       (B1) writes to the BRANCH do not change the PARENT — insert a row into the
#            branch, assert the parent's row count is UNCHANGED (true isolation).
#       (B2) cross-tenant — tenant B cannot branch/read tenant A's schema: a branch
#            of B clones B's (different) data, ZERO of A's rows; and B cannot DROP
#            A's branch (404). The branch service binds tenant_id on every query.
#       (B3) a branch_name with a SQL-meta char ("x; drop schema …") is REJECTED
#            400 — proves the identifier sanitizer (the injection wall). AND a
#            db_per_tenant mount's branch -> 400 deferred.
#   (C · FLAG-OFF PARITY) a SECOND tenant-control with DB_BRANCHING_ENABLED unset:
#       POST /v1/tenants/{id}/branches -> 404 (route NOT mounted) WHILE base admin
#       GET /v1/tenants 200, and tenant_branches has 0 rows — byte-parity to today.
#
# Seeding: tenants via the EXISTING service-token admin endpoint (POST /v1/tenants,
# X-Service-Token); the schema_per_tenant mounts + their rows are created directly
# in the scratch postgres (CREATE SCHEMA + a tenant_databases row). The schema name
# is computed in-gate with the SAME sanitizer the Go tenantSchema() uses.
#
# ISOLATED by design (mirrors m109/m111): scratch postgres (prelude + REAL 005 +
# 032 + 055) + two tenant-control binaries built FROM CURRENT source, ALL on a
# PRIVATE network, every name suffixed with $$, an EXIT-trap removing EVERYTHING.
# It NEVER touches a mini-baas-* container/network/image/volume and NEVER edits
# the live docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
GO_DIR="${INFRA_DIR}/src/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
MIGRATION_055="${MIG_DIR}/055_tenant_branches.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M113] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M113] FAIL — $*"
  exit 1
}

PG_IMAGE="${M113_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m113-tc-$$:scratch"
NET="m113net-$$"
PG="m113-pg-$$"
TC_ON="m113-tc-on-$$"   # DB_BRANCHING_ENABLED=1     (A · positive / B · reject)
TC_OFF="m113-tc-off-$$" # DB_BRANCHING_ENABLED unset (C · parity)
PORT_ON="${M113_PORT_ON:-19130}"
PORT_OFF="${M113_PORT_OFF:-19131}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m113-internal-service-token-$$"
TENANT_A="m113-a-$$" # schema_per_tenant, positive + isolation base
TENANT_B="m113-b-$$" # schema_per_tenant, the OTHER tenant (cross-tenant wall)
TENANT_D="m113-d-$$" # db_per_tenant -> branch must 400 (deferred)
ROWS_A=80
ROWS_B=40
BODY_TMP="$(mktemp)"

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
# branchSchema(parentSchema, name) = <parentSchema>_br_<name>, truncated to 63.
branch_schema() { # $1=parentSchema $2=name
  local s="$1_br_$2"
  printf '%s' "${s:0:63}"
}

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q() { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
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

# Extract a top-level JSON string field value off BODY_TMP. Tolerates ZERO
# matches (grep wrapped in `|| true` so pipefail+set -e does not kill us).
json_str() { # $1=field
  { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'
}

wait_ready() { # $1=container $2=port
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/health/live" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || {
      red "$1 exited early:"
      docker logs "$1" 2>&1 | tail -20
      return 1
    }
    sleep 0.5
  done
  red "$1 never became ready:"
  docker logs "$1" 2>&1 | tail -20
  return 1
}

# ── 0) build the scratch tenant-control FROM CURRENT (drafted) source ──────────
step "0/8 build scratch tenant-control from CURRENT source (the DB-branching code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null ||
  fail "scratch tenant-control image build failed — gate must exercise the drafted branching code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres + prelude + REAL 005/032/055 ────────────────────
step "1/8 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# Gate readiness on TCP + a REAL SELECT 1 (the image init runs a socket-only temp
# server first; a log-only check races it).
for i in $(seq 1 80); do
  if docker exec "${PG}" pg_isready -h 127.0.0.1 -q 2>/dev/null && [[ "$(psql_val 'SELECT 1')" == "1" ]]; then
    break
  fi
  [[ $i -eq 80 ]] && {
    docker logs "${PG}" 2>&1 | tail -20
    fail "scratch postgres never accepted TCP + SELECT 1 (line: PG ready loop)"
  }
  sleep 0.5
done
ok "postgres up (TCP + SELECT 1)"

step "1b/8 apply prelude (schema_migrations, auth.current_tenant_id, roles, tenant_databases), then REAL 005 + 032 + 055"
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
-- migration), so the gate scaffolds it. The branching service reads `isolation`
-- from it keyed by the tenant slug. The CHECK lists all four real isolation
-- models so a db_per_tenant row INSERTs (then gets rejected at the BRANCH layer).
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
for i in $(seq 1 20); do
  prelude && break
  [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"
  sleep 0.5
done
apply_migration "${MIGRATION_005}" || fail "real migration 005_add_tenant_table.sql failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032_tenants.sql failed to apply (line: apply 032)"
[[ -f "${MIGRATION_055}" ]] || fail "migration 055_tenant_branches.sql is MISSING — the branching migration must land before m113 can run (line: 055 exists)"
apply_migration "${MIGRATION_055}" || fail "real migration 055_tenant_branches.sql failed to apply (line: apply 055)"
[[ "$(psql_val "SELECT count(*) FROM public.tenants")" == "0" ]] || fail "tenants should start EMPTY (line: 032 empty check)"
[[ "$(psql_val "SELECT to_regclass('public.tenant_branches') IS NOT NULL")" == "t" ]] ||
  fail "public.tenant_branches not created by migration 055 (line: 055 table check)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_branches")" == "0" ]] ||
  fail "tenant_branches should start EMPTY (line: 055 empty check)"
ok "migrations 005 + 032 + 055 applied — tenants / tenant_databases / tenant_branches exist, ledger empty"

# ── 2) boot the BRANCHING-ON tenant-control (DB_BRANCHING_ENABLED=1) ───────────
step "2/8 boot tenant-control DB_BRANCHING_ENABLED=1 on 127.0.0.1:${PORT_ON} (A · positive / B · reject)"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e DB_BRANCHING_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "branching-ON tenant-control not ready (line: wait_ready TC_ON)"
ok "branching-ON tenant-control up (branch routes mounted)"

# ── 3) SEED tenants via admin endpoint, then mounts + schema rows in PG ─────────
step "3/8 seed A + B (schema_per_tenant) + D (db_per_tenant) via POST /v1/tenants (X-Service-Token)"
for t in "${TENANT_A}" "${TENANT_B}" "${TENANT_D}"; do
  C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${t}\",\"name\":\"${t}\",\"plan\":\"nano\"}")"
  [[ "${C}" == "201" ]] || fail "seed tenant ${t} expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed ${t})"
done
ok "tenants A + B + D created (all nano)"

step "3b/8 register mounts (A/B schema_per_tenant, D db_per_tenant); create A/B schemas + marker rows"
seed_sql() {
  psql_q >/dev/null 2>"${BODY_TMP}.seederr" <<SQL
INSERT INTO public.tenant_databases
  (tenant_id, engine, name, connection_enc, connection_iv, connection_tag, isolation)
VALUES
  ('${TENANT_A}', 'postgresql', 'm113-mount-a', '\\x00', '\\x00', '\\x00', 'schema_per_tenant'),
  ('${TENANT_B}', 'postgresql', 'm113-mount-b', '\\x00', '\\x00', '\\x00', 'schema_per_tenant'),
  ('${TENANT_D}', 'postgresql', 'm113-mount-d', '\\x00', '\\x00', '\\x00', 'db_per_tenant');

CREATE SCHEMA IF NOT EXISTS "${SCHEMA_A}";
CREATE SCHEMA IF NOT EXISTS "${SCHEMA_B}";
CREATE TABLE IF NOT EXISTS "${SCHEMA_A}".m113_marker (id int PRIMARY KEY, payload text NOT NULL);
CREATE TABLE IF NOT EXISTS "${SCHEMA_B}".m113_marker (id int PRIMARY KEY, payload text NOT NULL);
INSERT INTO "${SCHEMA_A}".m113_marker (id, payload)
  SELECT g, 'A_ROW_PAYLOAD_' || g FROM generate_series(1, ${ROWS_A}) g;
INSERT INTO "${SCHEMA_B}".m113_marker (id, payload)
  SELECT g, 'B_ROW_PAYLOAD_' || g FROM generate_series(1, ${ROWS_B}) g;
GRANT USAGE ON SCHEMA "${SCHEMA_A}", "${SCHEMA_B}" TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON "${SCHEMA_A}".m113_marker, "${SCHEMA_B}".m113_marker TO authenticated, service_role;
SQL
}
seed_sql || fail "seeding mounts + schemas failed — $(tail -c 600 "${BODY_TMP}.seederr" 2>/dev/null) (line: seed_sql)"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_A}\".m113_marker")" == "${ROWS_A}" ]] ||
  fail "A schema should hold ${ROWS_A} rows (line: A seed count)"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_B}\".m113_marker")" == "${ROWS_B}" ]] ||
  fail "B schema should hold ${ROWS_B} rows (line: B seed count)"
ok "A=${ROWS_A} rows (schema ${SCHEMA_A}), B=${ROWS_B} rows (schema ${SCHEMA_B})"

# ── 4) (A · POSITIVE) branch A → branch schema EXISTS with EXACTLY A's rows ─────
step "4a/8 (A · POSITIVE) POST /v1/tenants/${TENANT_A}/branches name=staging → 201; branch schema exists with EXACTLY ${ROWS_A} rows"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_A}/branches" '{"name":"staging","mount":"m113-mount-a"}')"
[[ "${C}" == "201" ]] ||
  fail "(A) POST /branches expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A branch)"
BRANCH_A="$(json_str id)"
[[ -n "${BRANCH_A}" ]] || fail "(A) POST /branches returned no id — $(head -c 300 "${BODY_TMP}") (line: A branch id)"
BR_SCHEMA_A="$(branch_schema "${SCHEMA_A}" staging)"
# Ledger row completed with the right counts.
A_LSTATUS="$(psql_val "SELECT status FROM public.tenant_branches WHERE id='${BRANCH_A}'")"
[[ "${A_LSTATUS}" == "completed" ]] || fail "(A) ledger status='${A_LSTATUS}', want completed — $(psql_val "SELECT error_message FROM public.tenant_branches WHERE id='${BRANCH_A}'") (line: A status)"
A_LRC="$(psql_val "SELECT row_count FROM public.tenant_branches WHERE id='${BRANCH_A}'")"
A_LTC="$(psql_val "SELECT table_count FROM public.tenant_branches WHERE id='${BRANCH_A}'")"
[[ "${A_LRC}" == "${ROWS_A}" ]] || fail "(A) ledger row_count=${A_LRC}, want ${ROWS_A} (line: A row_count)"
[[ "${A_LTC}" == "1" ]] || fail "(A) ledger table_count=${A_LTC}, want 1 (line: A table_count)"
# The branch SCHEMA actually exists in Postgres with the cloned table + rows.
[[ "$(psql_val "SELECT count(*) FROM information_schema.schemata WHERE schema_name='${BR_SCHEMA_A}'")" == "1" ]] ||
  fail "(A) branch schema ${BR_SCHEMA_A} does not exist (line: A schema exists)"
[[ "$(psql_val "SELECT count(*) FROM \"${BR_SCHEMA_A}\".m113_marker")" == "${ROWS_A}" ]] ||
  fail "(A) branch schema has $(psql_val "SELECT count(*) FROM \"${BR_SCHEMA_A}\".m113_marker") rows, want EXACTLY ${ROWS_A} (line: A clone rows)"
ok "(A) branch ${BRANCH_A} completed; schema ${BR_SCHEMA_A} exists w/ ${ROWS_A} cloned rows, ledger table_count=1 row_count=${ROWS_A}"

step "4b/8 (A · POSITIVE) GET /v1/tenants/${TENANT_A}/branches lists the branch status=completed"
C="$(admin_req GET "${PORT_ON}" "/v1/tenants/${TENANT_A}/branches")"
[[ "${C}" == "200" ]] || fail "(A) GET /branches expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A list)"
grep -q "\"id\":\"${BRANCH_A}\"" "${BODY_TMP}" || fail "(A) GET /branches missing ${BRANCH_A} (line: A list has id)"
grep -q '"status":"completed"' "${BODY_TMP}" || fail "(A) GET /branches not completed (line: A list completed)"
ok "(A) GET /branches → 200; lists ${BRANCH_A} status=completed"

# ── 5) (B · REJECT, LOAD-BEARING) branch isolation: write to branch ≠ parent ────
step "5/8 (B1 · LOAD-BEARING) write to the BRANCH does NOT change the PARENT (true isolation)"
PARENT_BEFORE="$(psql_val "SELECT count(*) FROM \"${SCHEMA_A}\".m113_marker")"
psql_q -c "INSERT INTO \"${BR_SCHEMA_A}\".m113_marker (id, payload) VALUES (999999, 'BRANCH_ONLY_ROW')" >/dev/null 2>&1 ||
  fail "(B1) could not insert into branch schema — branch is not a writable clone (line: B1 branch insert)"
PARENT_AFTER="$(psql_val "SELECT count(*) FROM \"${SCHEMA_A}\".m113_marker")"
[[ "${PARENT_AFTER}" == "${PARENT_BEFORE}" && "${PARENT_AFTER}" == "${ROWS_A}" ]] ||
  fail "(B1) parent row count changed ${PARENT_BEFORE}->${PARENT_AFTER} after a BRANCH insert — NOT isolated! (line: B1 parent unchanged)"
BR_AFTER="$(psql_val "SELECT count(*) FROM \"${BR_SCHEMA_A}\".m113_marker")"
[[ "${BR_AFTER}" == "$((ROWS_A + 1))" ]] ||
  fail "(B1) branch row count is ${BR_AFTER}, want $((ROWS_A + 1)) after the branch-only insert (line: B1 branch grew)"
ok "(B1) branch grew to ${BR_AFTER}, parent stayed ${PARENT_AFTER}=${ROWS_A} — schema-clone is genuinely isolated"

# ── 6) (B · REJECT, LOAD-BEARING) cross-tenant: B branches B, never A ──────────
step "6a/8 (B2 · LOAD-BEARING) tenant B branches its OWN schema → ZERO of A's rows; B's branch has B's ${ROWS_B} rows"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_B}/branches" '{"name":"staging","mount":"m113-mount-b"}')"
[[ "${C}" == "201" ]] || fail "(B2) POST B /branches expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B2 branch)"
BRANCH_B="$(json_str id)"
[[ -n "${BRANCH_B}" ]] || fail "(B2) B branch returned no id (line: B2 branch id)"
BR_SCHEMA_B="$(branch_schema "${SCHEMA_B}" staging)"
[[ "$(psql_val "SELECT count(*) FROM \"${BR_SCHEMA_B}\".m113_marker")" == "${ROWS_B}" ]] ||
  fail "(B2) B's branch has $(psql_val "SELECT count(*) FROM \"${BR_SCHEMA_B}\".m113_marker") rows, want ${ROWS_B} (line: B2 B clone rows)"
# Load-bearing: B's branch schema contains ZERO of A's payload (no cross-tenant clone).
B_BLEED="$({ psql_val "SELECT count(*) FROM \"${BR_SCHEMA_B}\".m113_marker WHERE payload LIKE 'A_ROW_PAYLOAD_%'"; })"
[[ "${B_BLEED}" == "0" ]] ||
  fail "(B2) B's branch contains ${B_BLEED} of A's rows — CROSS-TENANT CLONE LEAK! (line: B2 no A bleed)"
ok "(B2) B's branch schema ${BR_SCHEMA_B} has ${ROWS_B} B-rows, ZERO A-rows — branch clones only the caller's own schema"

step "6b/8 (B2 · LOAD-BEARING) tenant B cannot DROP tenant A's branch (cross-tenant DELETE → 404)"
C="$(admin_req DELETE "${PORT_ON}" "/v1/tenants/${TENANT_B}/branches/${BRANCH_A}")"
[[ "${C}" == "404" ]] ||
  fail "(B2) B dropping A's branch got ${C} (want 404) — cross-tenant DROP not walled! (line: B2 cross drop 404)"
# Defence: A's branch + its schema still exist after B's failed drop.
[[ "$(psql_val "SELECT count(*) FROM public.tenant_branches WHERE id='${BRANCH_A}'")" == "1" ]] ||
  fail "(B2) A's branch ledger row vanished after B's cross-tenant DROP attempt (line: B2 A row survives)"
[[ "$(psql_val "SELECT count(*) FROM information_schema.schemata WHERE schema_name='${BR_SCHEMA_A}'")" == "1" ]] ||
  fail "(B2) A's branch schema vanished after B's cross-tenant DROP attempt (line: B2 A schema survives)"
ok "(B2) B's DROP of A's branch → 404; A's branch + schema intact — tenant_id binds every branch query"

# ── 7) (B · REJECT) injection wall + db_per_tenant deferred ────────────────────
step "7a/8 (B3 · LOAD-BEARING) a branch_name with a SQL-meta char is REJECTED 400 (the identifier sanitizer)"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_A}/branches" '{"name":"x; drop schema public cascade","mount":"m113-mount-a"}')"
[[ "${C}" == "400" ]] ||
  fail "(B3) injection branch name got ${C} (want 400) — the identifier sanitizer did not fire — $(head -c 300 "${BODY_TMP}") (line: B3 injection 400)"
# Defence: public schema (and A's data) survived the attempted injection.
[[ "$(psql_val "SELECT count(*) FROM information_schema.schemata WHERE schema_name='public'")" == "1" ]] ||
  fail "(B3) public schema GONE — injection actually executed! (line: B3 public survives)"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_A}\".m113_marker")" == "${ROWS_A}" ]] ||
  fail "(B3) A's data changed after injection attempt (line: B3 A data survives)"
# Also reject a name with a bare space (another meta char).
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_A}/branches" '{"name":"bad name","mount":"m113-mount-a"}')"
[[ "${C}" == "400" ]] || fail "(B3) space-bearing branch name got ${C} (want 400) (line: B3 space 400)"
ok "(B3) meta-char branch names → 400; public schema + A's data intact — SQL-identifier injection wall holds"

step "7b/8 (B3) db_per_tenant deferred — POST /v1/tenants/${TENANT_D}/branches → 400 \"deferred\""
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_D}/branches" '{"name":"staging","mount":"m113-mount-d"}')"
[[ "${C}" == "400" ]] ||
  fail "(B3) db_per_tenant branch got ${C} (want 400) — the deferral is not enforced — $(head -c 300 "${BODY_TMP}") (line: D deferred 400)"
grep -qi 'deferred' "${BODY_TMP}" ||
  fail "(B3) db_per_tenant 400 body missing the 'deferred' message — $(head -c 300 "${BODY_TMP}") (line: D deferred msg)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_branches WHERE tenant_id='${TENANT_D}'")" == "0" ]] ||
  fail "(B3) a branch row exists for db_per_tenant tenant D — the deferral leaked a branch (line: D no row)"
ok "(B3) db_per_tenant branch → 400 deferred (no ledger row) — only schema_per_tenant advertised"

step "7c/8 (A · POSITIVE) DELETE the branch → 204; schema gone + ledger row gone"
C="$(admin_req DELETE "${PORT_ON}" "/v1/tenants/${TENANT_A}/branches/${BRANCH_A}")"
[[ "${C}" == "204" ]] || fail "(A) DELETE /branches/{id} expected 204, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A drop 204)"
[[ "$(psql_val "SELECT count(*) FROM information_schema.schemata WHERE schema_name='${BR_SCHEMA_A}'")" == "0" ]] ||
  fail "(A) branch schema ${BR_SCHEMA_A} still exists after DELETE (line: A schema dropped)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_branches WHERE id='${BRANCH_A}'")" == "0" ]] ||
  fail "(A) branch ledger row still exists after DELETE (line: A row dropped)"
# Parent schema is untouched by the branch drop.
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_A}\".m113_marker")" == "${ROWS_A}" ]] ||
  fail "(A) parent schema changed after branch DELETE (line: A parent intact post-drop)"
ok "(A) DELETE → 204; branch schema + ledger row gone, parent ${SCHEMA_A} intact (${ROWS_A} rows)"

# ── 8) (C · PARITY) flag OFF → branch routes 404, base admin route still 200 ───
step "8a/8 (C · PARITY) boot a SECOND tenant-control with DB_BRANCHING_ENABLED unset on 127.0.0.1:${PORT_OFF}"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "branching-OFF tenant-control not ready (line: wait_ready TC_OFF)"
ok "branching-OFF tenant-control up (same DB, same seeded tenants)"

step "8b/8 (C · PARITY) POST /v1/tenants/${TENANT_B}/branches on the OFF router → 404 (route NOT mounted) WHILE base admin GET /v1/tenants → 200, tenant_branches 0 net rows"
C="$(admin_req POST "${PORT_OFF}" "/v1/tenants/${TENANT_B}/branches" '{"name":"staging2","mount":"m113-mount-b"}')"
[[ "${C}" == "404" ]] ||
  fail "(C) PARITY: POST /branches with DB_BRANCHING_ENABLED off expected 404, got ${C} — $(head -c 300 "${BODY_TMP}") (line: C branch 404)"
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants")"
[[ "${C}" == "200" ]] ||
  fail "(C) PARITY: base admin GET /v1/tenants expected 200 on OFF router, got ${C} — $(head -c 300 "${BODY_TMP}") (line: C admin 200)"
grep -q "\"id\":\"${TENANT_A}\"" "${BODY_TMP}" ||
  fail "(C) PARITY: base admin GET /v1/tenants did not list A — $(head -c 300 "${BODY_TMP}") (line: C admin lists A)"
# With the flag OFF, the 404'd call wrote NOTHING new (B's only branch row is the
# one B2 created above; no staging2 leaked through).
[[ "$(psql_val "SELECT count(*) FROM public.tenant_branches WHERE branch_name='staging2'")" == "0" ]] ||
  fail "(C) PARITY: a staging2 branch row leaked from the OFF router (line: C no leak)"
ok "(C) branch route 404 with flag OFF while base admin GET /v1/tenants still 200 (lists A); no row leaked — byte-parity to today"

# ── summarize ──────────────────────────────────────────────────────────────────
step "summary"
green "[M113] (A) POSITIVE: branch A (schema_per_tenant) → branch schema ${BR_SCHEMA_A} with EXACTLY ${ROWS_A} cloned rows + ledger{table_count=1,row_count=${ROWS_A},status=completed}; list 200; DELETE 204 drops schema + row, parent intact"
green "[M113] (B) REJECT:   (B1) branch insert leaves parent UNCHANGED (isolation); (B2) B branches only B's schema (ZERO A-rows) + B's DROP of A's branch → 404 (A intact); (B3) meta-char name → 400 (public + A data survive) + db_per_tenant → 400 deferred"
green "[M113] (C) PARITY:   DB_BRANCHING_ENABLED off → POST /branches 404 (route absent) while base admin GET /v1/tenants 200; no branch row leaked"

# ── emit the gate event via the kernel log helper (best-effort) ─────────────────
step "log GATE m113=PASS"
emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-e-db-branching}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m113=PASS" --outcome pass \
      --msg "Track-E DB branching (Supabase-parity branches): schema_per_tenant mount -> isolated schema-clone (CREATE SCHEMA + LIKE INCLUDING ALL + INSERT SELECT, NO pg_dump) with EXACTLY the tenant's rows + a completed ledger row; LOAD-BEARING: (B1) branch write leaves parent unchanged, (B2) B branches only B's schema (zero A-rows) + B's DROP of A's branch -> 404, (B3) meta-char branch name -> 400 (identifier injection wall) + db_per_tenant -> 400 deferred; DELETE drops schema+row; DB_BRANCHING_ENABLED OFF -> routes 404 while admin 200 (byte-parity)" \
      --ref "scripts/verify/m113-db-branching.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M113] ALL GATES GREEN — Track-E DB branching: schema-clone with EXACTLY one tenant's rows, branch≠parent isolation, cross-tenant ZERO clone + 404 DROP wall, identifier-injection 400, db_per_tenant 400 deferred, byte-parity when OFF"
exit 0
