#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m105-hard-erase.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M105 — Track-D D4.4 HARD-ERASE / tenant teardown gate. Today a teardown is
# SOFT-DELETE only (DELETE /v1/tenants/{id} flips status='deleted'; the rows
# stay). D4.4 adds PROVABLE destruction of one tenant's data, scoped so erasing
# tenant A can NEVER touch tenant B, sealing a tamper-evident D3 audit receipt
# (proof the erase happened that survives the data going away) + an
# erasure_receipts ledger row (migration 048). It exercises a tenant-control
# binary built FROM CURRENT source — the EXACT D4.4 code:
#
#   tenant-control (Go, HARD_ERASE_ENABLED=1, TENANT_AUDIT_ENABLED=1)
#     X-Service-Token: …   (admin)
#       │
#       ▼
#     POST /v1/tenants/{id}/erase  -> DROP SCHEMA <tenant> CASCADE (schema_per_tenant)
#                                     | DELETE WHERE tenant matches (shared_rls);
#                                     revoke+delete API keys; seal D3 receipt +
#                                     erasure_receipts row.
#
#   (A · POSITIVE) provision tenant A (schema_per_tenant mount, 100 rows in
#       <tenant_a>.m105_marker) + mint an API key (verifies OK before erase).
#       Hard-erase A -> assert: the schema is DROPPED (to_regclass NULL / 0
#       tables), the API key NO LONGER authenticates (POST /v1/keys/verify =>
#       valid:false), a D3 audit receipt exists AND verifies (chain INTACT,
#       action tenant.erase), and an erasure_receipts row records the purge
#       (status=completed, rows_purged==100, scope schema_per_tenant, audit_seq>0).
#   (B · REJECT, LOAD-BEARING) tenant B (schema_per_tenant mount, 50 rows) must
#       be byte-UNTOUCHED through A's whole erase (B's schema exists, count==50,
#       md5==baseline, B's key STILL authenticates) — only A is purged.
#   (C · REJECT, LOAD-BEARING) WITHOUT HARD_ERASE_ENABLED the erase route is 404
#       AND the tenant data is INTACT (soft-delete only): a SECOND tenant-control
#       with HARD_ERASE_ENABLED unset returns 404 for POST .../erase WHILE the
#       base admin GET /v1/tenants/{id} STILL 200, no erasure_receipts row is
#       written, and a fresh tenant's data is intact (no destruction). This is the
#       FLAG-OFF PARITY arm: flag unset -> route 404, no erasure_receipts, no
#       destruction = byte-identical to today.
#
# Seeding: tenants + keys via the EXISTING service-token admin endpoints (POST
# /v1/tenants ; POST /v1/tenants/{id}/keys, X-Service-Token); the
# schema_per_tenant mount + its rows are created directly in the scratch postgres
# (CREATE SCHEMA + a tenant_databases row isolation='schema_per_tenant'), exactly
# the namespace the erase service derives from tenantSchema(slug).
#
# ISOLATED by design (mirrors m104/m87/m80): scratch postgres (prelude + REAL 005
# + 032 + 047 + 048) + two tenant-control binaries built FROM CURRENT source, ALL
# on a PRIVATE network, every name suffixed with $$, an EXIT-trap removing
# EVERYTHING. It NEVER touches a mini-baas-* container/network/image/volume and
# NEVER edits the live docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
GO_DIR="${INFRA_DIR}/go/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
MIGRATION_047="${MIG_DIR}/047_tenant_audit_log.sql"
MIGRATION_048="${MIG_DIR}/048_tenant_erasure.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M105] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M105] FAIL — $*"; exit 1; }

PG_IMAGE="${M105_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m105-tc-$$:scratch"
NET="m105net-$$"
PG="m105-pg-$$"
TC_ON="m105-tc-on-$$"      # HARD_ERASE_ENABLED=1 (A · positive / B · reject)
TC_OFF="m105-tc-off-$$"    # HARD_ERASE_ENABLED unset (C · flag-off parity)
PORT_ON="${M105_PORT_ON:-19106}"
PORT_OFF="${M105_PORT_OFF:-19107}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m105-internal-service-token-$$"
TENANT_A="m105-a-$$"
TENANT_B="m105-b-$$"
TENANT_C="m105-c-$$"       # parity tenant: must stay INTACT with the flag OFF
ROWS_A=100
ROWS_B=50
ROWS_C=7
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
SCHEMA_C="$(tenant_schema "${TENANT_C}")"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

# shellcheck disable=SC2120  # "$@" passthrough is intentional (house psql_q helper); callers pipe heredocs
psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Apply one migration file the SAME way `make migrate` does: strip the leading
# `#` 42-header banner lines (sed '/^#/d') before piping to psql, so the header
# is never fed to the SQL parser (the migration BODY uses `--` SQL comments which
# psql tolerates; only the top banner is `#`-prefixed). $1 = file.
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

# Tenant-self audit GET (header == path id): $1=port $2=tenant $3=sub(events|verify)
audit_self() {
  local port="$1" tenant="$2" sub="$3"
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -H "X-Baas-Tenant-Id: ${tenant}" \
    "http://127.0.0.1:${port}/v1/audit/tenants/${tenant}/${sub}"
}

# Extract a top-level JSON string field value off BODY_TMP. Tolerates ZERO
# matches (grep wrapped in `|| true` so pipefail+set -e does not kill us). $1=field.
json_str() { # $1=field
  { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'
}
# Extract a top-level JSON numeric field value off BODY_TMP. $1=field.
json_num() { # $1=field
  { grep -o "\"$1\":[0-9]*" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://'
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
step "0/10 build scratch tenant-control from CURRENT source (the D4.4 hard-erase code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3070 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — gate must exercise the drafted hard-erase code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres (TCP-ready, not just socket) ─────────────────────
step "1/10 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# The postgres image init runs a SOCKET-ONLY temp server then restarts — gate
# readiness on TCP (pg_isready -h 127.0.0.1) + a real SELECT 1, not the socket.
for i in $(seq 1 80); do
  if docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 \
     && [[ "$(psql_val 'SELECT 1')" == "1" ]]; then break; fi
  [[ $i -eq 80 ]] && { docker logs "${PG}" 2>&1 | tail -20; fail "scratch postgres never reached TCP-ready"; }
  sleep 0.5
done
ok "postgres up + TCP-ready (SELECT 1 ok)"

# ── 1b) prelude (tenants/auth/roles + tenant_databases) then REAL 005/032/047/048 ─
step "1b/10 prelude (schema_migrations, auth.current_tenant_id, roles, tenant_databases) then REAL 005 + 032 + 047 + 048"
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
-- tenant_databases is owned by the adapter-registry's Go EnsureSchema (NOT a SQL
-- migration), so the gate — which boots tenant-control only — must scaffold it.
-- The erase service reads `isolation` from it keyed by the tenant slug (the API
-- id the /v1/tenants/{id} path carries), which is what scopeFor binds on.
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
apply_migration "${MIGRATION_047}" || fail "real migration 047_tenant_audit_log.sql failed to apply (line: apply 047)"
[[ -f "${MIGRATION_048}" ]] || fail "migration 048_tenant_erasure.sql is MISSING — the D4.4 migration slice must land before m105 can run (line: 048 exists)"
apply_migration "${MIGRATION_048}" || fail "real migration 048_tenant_erasure.sql failed to apply (line: apply 048)"
[[ "$(psql_val "SELECT to_regclass('public.erasure_receipts') IS NOT NULL")" == "t" ]] \
  || fail "public.erasure_receipts not created by migration 048 (line: 048 table check)"
[[ "$(psql_val "SELECT count(*) FROM public.erasure_receipts")" == "0" ]] \
  || fail "erasure_receipts should start EMPTY (line: 048 empty check)"
# Append-only at the grant layer: authenticated must NOT have UPDATE/DELETE.
HASUPD="$(psql_val "SELECT count(*) FROM information_schema.role_table_grants WHERE table_name='erasure_receipts' AND grantee='authenticated' AND privilege_type IN ('UPDATE','DELETE')")" || HASUPD="?"
[[ "${HASUPD}" == "0" ]] || fail "authenticated must NOT have UPDATE/DELETE on erasure_receipts, got ${HASUPD} (line: 048 grants)"
ok "migrations 005 + 032 + 047 + 048 applied — tenants / tenant_audit_log / erasure_receipts exist, empty, receipts append-only"

# ── 2) boot the ERASE-ON tenant-control (HARD_ERASE_ENABLED=1 + audit) ─────────
step "2/10 boot tenant-control HARD_ERASE_ENABLED=1 TENANT_AUDIT_ENABLED=1 on 127.0.0.1:${PORT_ON} (A · positive / B · reject)"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e HARD_ERASE_ENABLED=1 \
  -e TENANT_AUDIT_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3070 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3070" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "erase-ON tenant-control not ready (line: wait_ready TC_ON)"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "hard-erase enabled" \
  || { docker logs "${TC_ON}" 2>&1 | tail -20; fail "hard-erase never reported enabled (line: TC_ON enabled log)"; }
ok "erase-ON tenant-control up (POST /v1/tenants/{id}/erase + /v1/audit* mounted)"

# ── 3) SEED tenants A + B + a key each, then schema_per_tenant mounts + rows ────
step "3/10 seed A(${TENANT_A}) + B(${TENANT_B}) via POST /v1/tenants (X-Service-Token); mint an API key for each"
C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${TENANT_A}\",\"name\":\"A\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant A expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed A)"
C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${TENANT_B}\",\"name\":\"B\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant B expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed B)"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_A}/keys" '{"name":"erase-key-a","scopes":["read","write"]}')"
[[ "${C}" == "200" || "${C}" == "201" ]] || fail "mint key A expected 200/201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: key A)"
KEY_A="$(json_str key)"
[[ "${KEY_A}" == mbk_* ]] || fail "key A not returned (got '${KEY_A}') — $(head -c 300 "${BODY_TMP}") (line: key A value)"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_B}/keys" '{"name":"erase-key-b","scopes":["read","write"]}')"
[[ "${C}" == "200" || "${C}" == "201" ]] || fail "mint key B expected 200/201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: key B)"
KEY_B="$(json_str key)"
[[ "${KEY_B}" == mbk_* ]] || fail "key B not returned (got '${KEY_B}') — $(head -c 300 "${BODY_TMP}") (line: key B value)"
ok "tenants A + B created (nano); API keys minted for each"

step "3b/10 register A/B schema_per_tenant mounts; create A/B schemas + deterministic marker rows"
seed_sql() {
  psql_q >/dev/null 2>"${BODY_TMP}.seederr" <<SQL
INSERT INTO public.tenant_databases
  (tenant_id, engine, name, connection_enc, connection_iv, connection_tag, isolation)
VALUES
  ('${TENANT_A}', 'postgresql', 'm105-mount-a', '\\x00', '\\x00', '\\x00', 'schema_per_tenant'),
  ('${TENANT_B}', 'postgresql', 'm105-mount-b', '\\x00', '\\x00', '\\x00', 'schema_per_tenant');

CREATE SCHEMA IF NOT EXISTS "${SCHEMA_A}";
CREATE SCHEMA IF NOT EXISTS "${SCHEMA_B}";
CREATE TABLE IF NOT EXISTS "${SCHEMA_A}".m105_marker (id int PRIMARY KEY, payload text NOT NULL);
CREATE TABLE IF NOT EXISTS "${SCHEMA_B}".m105_marker (id int PRIMARY KEY, payload text NOT NULL);
INSERT INTO "${SCHEMA_A}".m105_marker (id, payload)
  SELECT g, 'a-row-' || g FROM generate_series(1, ${ROWS_A}) g;
INSERT INTO "${SCHEMA_B}".m105_marker (id, payload)
  SELECT g, 'b-row-' || g FROM generate_series(1, ${ROWS_B}) g;
GRANT USAGE ON SCHEMA "${SCHEMA_A}", "${SCHEMA_B}" TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON "${SCHEMA_A}".m105_marker, "${SCHEMA_B}".m105_marker TO authenticated, service_role;
SQL
}
seed_sql || fail "seeding tenant_databases mounts + A/B schemas failed — $(tail -c 600 "${BODY_TMP}.seederr" 2>/dev/null) (line: seed_sql)"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_A}\".m105_marker")" == "${ROWS_A}" ]] \
  || fail "A schema ${SCHEMA_A}.m105_marker should hold ${ROWS_A} rows (line: A seed count)"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_B}\".m105_marker")" == "${ROWS_B}" ]] \
  || fail "B schema ${SCHEMA_B}.m105_marker should hold ${ROWS_B} rows (line: B seed count)"
BASE_CK_B="$(psql_val "SELECT md5(string_agg(t::text, '|' ORDER BY id)) FROM \"${SCHEMA_B}\".m105_marker t")"
[[ -n "${BASE_CK_B}" ]] || fail "could not compute B baseline checksum (line: B baseline ck)"
ok "A=${ROWS_A} rows in ${SCHEMA_A}, B=${ROWS_B} rows in ${SCHEMA_B}; B baseline md5=${BASE_CK_B}"

# ── 4) PRE-ERASE: both keys authenticate ───────────────────────────────────────
step "4/10 PRE-ERASE: A's and B's API keys both authenticate (POST /v1/keys/verify => valid:true)"
C="$(admin_req POST "${PORT_ON}" /v1/keys/verify "{\"key\":\"${KEY_A}\"}")"
[[ "${C}" == "200" ]] || fail "verify A key expected 200, got ${C} — $(head -c 200 "${BODY_TMP}") (line: pre A verify code)"
grep -q '"valid":true' "${BODY_TMP}" || fail "A key should authenticate BEFORE erase — $(head -c 200 "${BODY_TMP}") (line: pre A valid)"
C="$(admin_req POST "${PORT_ON}" /v1/keys/verify "{\"key\":\"${KEY_B}\"}")"
[[ "${C}" == "200" ]] || fail "verify B key expected 200, got ${C} (line: pre B verify code)"
grep -q '"valid":true' "${BODY_TMP}" || fail "B key should authenticate BEFORE erase — $(head -c 200 "${BODY_TMP}") (line: pre B valid)"
ok "both keys valid before erase"

# ── 5) (A · POSITIVE) HARD-ERASE A ─────────────────────────────────────────────
step "5/10 (A · POSITIVE) POST /v1/tenants/${TENANT_A}/erase → schema DROPPED, key dead, receipt + erasure row"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_A}/erase")"
[[ "${C}" == "200" ]] || fail "(A) POST /erase expected 200, got ${C} — $(head -c 400 "${BODY_TMP}") (line: A erase code)"
grep -q '"status":"completed"' "${BODY_TMP}" || fail "(A) erase response not completed — $(head -c 400 "${BODY_TMP}") (line: A erase completed)"
A_ROWS_PURGED="$(json_num rows_purged)"
[[ "${A_ROWS_PURGED}" == "${ROWS_A}" ]] || fail "(A) rows_purged expected ${ROWS_A}, got '${A_ROWS_PURGED}' — $(head -c 400 "${BODY_TMP}") (line: A rows_purged)"
A_AUDIT_SEQ="$(json_num audit_seq)"
[[ -n "${A_AUDIT_SEQ}" && "${A_AUDIT_SEQ}" -gt 0 ]] 2>/dev/null \
  || fail "(A) audit_seq should be >0 (the sealed D3 link), got '${A_AUDIT_SEQ}' (line: A audit_seq)"
ok "(A) erase 200 completed; rows_purged=${A_ROWS_PURGED}; audit_seq=${A_AUDIT_SEQ}"

# ── 6) (A) PROVE the data is GONE: schema dropped, 0 tables/rows ────────────────
step "6/10 (A) PROVE destruction — schema ${SCHEMA_A} DROPPED (to_regschema NULL), 0 tables"
[[ "$(psql_val "SELECT count(*) FROM information_schema.schemata WHERE schema_name='${SCHEMA_A}'")" == "0" ]] \
  || fail "(A) schema ${SCHEMA_A} STILL EXISTS after hard-erase — destruction did not happen! (line: A schema gone)"
[[ "$(psql_val "SELECT to_regclass('\"${SCHEMA_A}\".m105_marker') IS NULL")" == "t" ]] \
  || fail "(A) ${SCHEMA_A}.m105_marker STILL resolvable after erase (line: A table gone)"
ok "(A) ${SCHEMA_A} schema + all its tables are GONE — provable destruction"

# ── 7) (A) the API key NO LONGER authenticates ─────────────────────────────────
step "7/10 (A) A's API key NO LONGER authenticates (POST /v1/keys/verify => valid:false)"
C="$(admin_req POST "${PORT_ON}" /v1/keys/verify "{\"key\":\"${KEY_A}\"}")"
# A now-invalid key returns HTTP 401 (verifyKey sets status 401 when !valid) with a
# {valid:false} body — the dead-credential signal, not 200.
[[ "${C}" == "401" ]] || fail "(A) verify after erase expected 401 (dead key), got ${C} (line: A post verify code)"
grep -q '"valid":false' "${BODY_TMP}" \
  || fail "(A) A's key STILL authenticates after hard-erase — credentials not revoked! — $(head -c 200 "${BODY_TMP}") (line: A key dead)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_api_keys k JOIN public.tenants t ON t.id=k.tenant_id WHERE t.slug='${TENANT_A}'")" == "0" ]] \
  || fail "(A) A still has API key rows after erase (line: A keys deleted in DB)"
ok "(A) A's key invalid (valid:false) + 0 key rows remain — no credential authenticates"

# ── 8) (A) D3 audit receipt EXISTS + VERIFIES + erasure_receipts row records it ─
step "8/10 (A) D3 audit receipt verifies (chain INTACT, action tenant.erase) + erasure_receipts row records the purge"
# The tenant entity is soft-marked deleted, but its audit chain survives — the
# self-header still reaches its own chain (the audit route binds tenant_id, not
# tenant status). Verify the chain is INTACT.
C="$(audit_self "${PORT_ON}" "${TENANT_A}" verify)"
[[ "${C}" == "200" ]] || fail "(A) audit verify expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A audit verify code)"
grep -q '"intact":true' "${BODY_TMP}" \
  || fail "(A) the erase receipt chain must verify INTACT — $(head -c 400 "${BODY_TMP}") (line: A chain intact)"
# The receipt event itself: query the chain, assert a tenant.erase event exists.
C="$(audit_self "${PORT_ON}" "${TENANT_A}" events)"
[[ "${C}" == "200" ]] || fail "(A) audit events expected 200, got ${C} (line: A audit events code)"
grep -q '"action":"tenant.erase"' "${BODY_TMP}" \
  || fail "(A) no tenant.erase event on the chain — the D3 receipt was not sealed — $(head -c 400 "${BODY_TMP}") (line: A erase event)"
# Cross-check the chain in the DB too (defence): the audit row survives the data.
[[ "$(psql_val "SELECT count(*) FROM public.tenant_audit_log WHERE tenant_id='${TENANT_A}' AND action='tenant.erase'")" == "1" ]] \
  || fail "(A) exactly one tenant.erase audit row should exist for A (line: A audit row in DB)"
# The erasure_receipts ledger row records the purge.
ERASE_STATUS="$(psql_val "SELECT status FROM public.erasure_receipts WHERE tenant_id='${TENANT_A}'")"
[[ "${ERASE_STATUS}" == "completed" ]] || fail "(A) erasure_receipts status for A is '${ERASE_STATUS}', want completed (line: A receipt status)"
ERASE_SCOPE="$(psql_val "SELECT scope FROM public.erasure_receipts WHERE tenant_id='${TENANT_A}'")"
[[ "${ERASE_SCOPE}" == "schema_per_tenant" ]] || fail "(A) erasure_receipts scope is '${ERASE_SCOPE}', want schema_per_tenant (line: A receipt scope)"
ERASE_RP="$(psql_val "SELECT rows_purged FROM public.erasure_receipts WHERE tenant_id='${TENANT_A}'")"
[[ "${ERASE_RP}" == "${ROWS_A}" ]] || fail "(A) erasure_receipts rows_purged is '${ERASE_RP}', want ${ROWS_A} (line: A receipt rows)"
ERASE_AS="$(psql_val "SELECT audit_seq FROM public.erasure_receipts WHERE tenant_id='${TENANT_A}'")"
[[ "${ERASE_AS}" == "${A_AUDIT_SEQ}" ]] || fail "(A) erasure_receipts audit_seq '${ERASE_AS}' != response audit_seq ${A_AUDIT_SEQ} (line: A receipt audit_seq xlink)"
ok "(A) D3 receipt verifies INTACT (tenant.erase sealed) + erasure_receipts row: completed, schema_per_tenant, rows_purged=${ERASE_RP}, audit_seq=${ERASE_AS}"

# ── 9) (B · REJECT, LOAD-BEARING) tenant B byte-UNTOUCHED + key still works ─────
step "9/10 (B · REJECT, LOAD-BEARING) B byte-UNTOUCHED — schema exists, count==${ROWS_B}, md5==baseline, B's key STILL authenticates"
[[ "$(psql_val "SELECT count(*) FROM information_schema.schemata WHERE schema_name='${SCHEMA_B}'")" == "1" ]] \
  || fail "(B) B's schema ${SCHEMA_B} was destroyed by A's erase — CROSS-TENANT DESTRUCTION! (line: B schema exists)"
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_B}\".m105_marker")" == "${ROWS_B}" ]] \
  || fail "(B) B's row count changed during A's erase — cross-tenant write! (line: B count untouched)"
B_CK_AFTER="$(psql_val "SELECT md5(string_agg(t::text, '|' ORDER BY id)) FROM \"${SCHEMA_B}\".m105_marker t")"
[[ "${B_CK_AFTER}" == "${BASE_CK_B}" ]] \
  || fail "(B) B's checksum changed during A's erase — got ${B_CK_AFTER}, baseline ${BASE_CK_B}: cross-tenant corruption! (line: B checksum)"
C="$(admin_req POST "${PORT_ON}" /v1/keys/verify "{\"key\":\"${KEY_B}\"}")"
[[ "${C}" == "200" ]] || fail "(B) verify B key expected 200, got ${C} (line: B post verify code)"
grep -q '"valid":true' "${BODY_TMP}" \
  || fail "(B) B's key stopped authenticating during A's erase — A's erase revoked B's credential! — $(head -c 200 "${BODY_TMP}") (line: B key alive)"
[[ "$(psql_val "SELECT count(*) FROM public.erasure_receipts WHERE tenant_id='${TENANT_B}'")" == "0" ]] \
  || fail "(B) an erasure_receipts row exists for B — A's erase recorded a B purge! (line: B no receipt)"
ok "(B) B byte-UNTOUCHED (schema + ${ROWS_B} rows + md5==baseline), B's key STILL valid, 0 B receipts — only A was purged"

# ── 10) (C · FLAG-OFF PARITY) flag unset → route 404, no receipts, data intact ─
# A flag-OFF PARITY arm must STOP/REMOVE the ENABLED container before testing OFF.
step "10/10 (C · FLAG-OFF PARITY) STOP the ENABLED container; boot with HARD_ERASE_ENABLED unset (same DB)"
docker rm -fv "${TC_ON}" >/dev/null 2>&1 || true
# Seed a fresh parity tenant C with data + mount on the SAME DB.
psql_q >/dev/null 2>&1 <<SQL || fail "(C) could not seed parity tenant C (line: C seed)"
INSERT INTO public.tenants (slug, name, plan, status) VALUES ('${TENANT_C}', 'C', 'nano', 'active');
INSERT INTO public.tenant_databases
  (tenant_id, engine, name, connection_enc, connection_iv, connection_tag, isolation)
VALUES ('${TENANT_C}', 'postgresql', 'm105-mount-c', '\\x00', '\\x00', '\\x00', 'schema_per_tenant');
CREATE SCHEMA IF NOT EXISTS "${SCHEMA_C}";
CREATE TABLE IF NOT EXISTS "${SCHEMA_C}".m105_marker (id int PRIMARY KEY, payload text NOT NULL);
INSERT INTO "${SCHEMA_C}".m105_marker (id, payload) SELECT g, 'c-row-' || g FROM generate_series(1, ${ROWS_C}) g;
SQL
RECEIPTS_BEFORE="$(psql_val "SELECT count(*) FROM public.erasure_receipts")"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3070 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3070" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "erase-OFF tenant-control not ready (line: wait_ready TC_OFF)"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -q "hard-erase disabled" \
  || { docker logs "${TC_OFF}" 2>&1 | tail -20; fail "OFF tenant-control did not report hard-erase disabled (flag default not OFF?) (line: TC_OFF disabled log)"; }
# POST .../erase → 404 (route NOT mounted) WHILE base admin GET /v1/tenants/{id} → 200.
C="$(admin_req POST "${PORT_OFF}" "/v1/tenants/${TENANT_C}/erase")"
[[ "${C}" == "404" ]] \
  || fail "(C) PARITY: POST /erase with HARD_ERASE_ENABLED off expected 404 (route absent), got ${C} — $(head -c 300 "${BODY_TMP}") (line: C erase 404)"
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants/${TENANT_C}")"
[[ "${C}" == "200" ]] \
  || fail "(C) PARITY: base admin GET /v1/tenants/{id} expected 200 on OFF router, got ${C} — $(head -c 300 "${BODY_TMP}") (line: C admin 200)"
# Data intact: C's schema + rows untouched, NO new erasure_receipts row written.
[[ "$(psql_val "SELECT count(*) FROM \"${SCHEMA_C}\".m105_marker")" == "${ROWS_C}" ]] \
  || fail "(C) PARITY: C's data was destroyed with the flag OFF — soft-delete only violated! (line: C data intact)"
RECEIPTS_AFTER="$(psql_val "SELECT count(*) FROM public.erasure_receipts")"
[[ "${RECEIPTS_AFTER}" == "${RECEIPTS_BEFORE}" ]] \
  || fail "(C) PARITY: flag OFF wrote an erasure_receipts row (before=${RECEIPTS_BEFORE} after=${RECEIPTS_AFTER}) (line: C no new receipt)"
ok "(C) flag OFF: POST /erase → 404 (unmounted) while admin GET /v1/tenants/{id} → 200; C's ${ROWS_C} rows INTACT; 0 new receipts — byte-parity (soft-delete only)"

# ── summarize ──────────────────────────────────────────────────────────────────
step "summary"
green "[M105] (A) POSITIVE: erase A → schema DROPPED CASCADE (0 tables), key valid:false (0 key rows), D3 receipt verifies INTACT (tenant.erase), erasure_receipts completed rows_purged=${ROWS_A} audit_seq=${A_AUDIT_SEQ}"
green "[M105] (B) REJECT:   B byte-untouched (schema + ${ROWS_B} rows + md5==baseline), B's key STILL valid, 0 B receipts — only A purged"
green "[M105] (C) PARITY:   HARD_ERASE_ENABLED off → POST /erase 404 (route absent) while admin GET /v1/tenants/{id} 200; data INTACT; no erasure_receipts — soft-delete only"

# ── emit the gate event via the kernel log helper (best-effort) ─────────────────
step "log GATE m105=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-d4-4-hard-erase}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m105=PASS" --outcome pass \
      --msg "D4.4 hard-erase: provision A (schema_per_tenant + key) → erase A → schema DROPPED CASCADE, key valid:false, D3 receipt verifies INTACT (tenant.erase), erasure_receipts completed rows_purged audit_seq; B byte-untouched + key alive (load-bearing); HARD_ERASE_ENABLED OFF → /erase 404 while admin 200, data INTACT, no receipts (byte-parity, soft-delete only)" \
      --ref "scripts/verify/m105-hard-erase.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M105] ALL GATES GREEN — D4.4 hard-erase PROVABLY destroys A (schema + keys), seals a tamper-evident D3 receipt + erasure_receipts row, leaves B untouched, and is byte-parity (soft-delete only) when OFF"
exit 0
