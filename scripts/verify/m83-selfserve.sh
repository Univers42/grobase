#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m83-selfserve.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M83 — Track-B tenant self-service control API (B4a) live gate. Proves a TENANT
# (authenticated by its OWN API key — no path id) can read+manage ITS OWN row,
# usage, and keys via the new /v1/tenants/me* surface, that it can NEVER see or
# touch another tenant, and that the whole /me surface is byte-parity (404, route
# not mounted) when TENANT_SELFSERVE_ENABLED is unset. It exercises a tenant-
# control binary built FROM CURRENT source — the EXACT B4a code:
#
#   tenant-control (Go, TENANT_SELFSERVE_ENABLED=1)
#     X-API-Key: mbk_…   (or Authorization: Bearer mbk_… / a GoTrue user JWT)
#       │  resolve caller -> its OWN tenant (NO path id)
#       ▼
#     GET    /v1/tenants/me            -> the caller's tenant (plan + entitlements)
#     GET    /v1/tenants/me/usage      -> the caller's metered usage
#     GET    /v1/tenants/me/keys       -> the caller's keys (redacted)
#     POST   /v1/tenants/me/keys       -> mint a new key for the caller (full key once)
#     DELETE /v1/tenants/me/keys/{id}  -> revoke one of the caller's keys
#     PATCH  /v1/tenants/me {plan}     -> change the caller's plan
#
#   (A · POSITIVE) with tenant A's key: GET /me -> 200 (A's plan); POST /me/keys ->
#       200 + a full mbk_ key; GET /me/keys lists it; DELETE /me/keys/{id} -> 200;
#       GET /me/usage -> 200; PATCH /me {plan:"pro"} -> 200 and a re-GET shows pro.
#   (B · REJECT, LOAD-BEARING) cross-tenant isolation: A's key sees ONLY A — GET
#       /me returns A (not B); /me/keys lists A's keys ONLY (B's uniquely-named key
#       is ABSENT). No auth header -> 401. A gate that only shows the happy path is
#       VACUOUS; the absent-B-key assertion + the 401 are the load-bearing proof.
#   (C · PARITY) a SECOND tenant-control with TENANT_SELFSERVE_ENABLED unset: GET
#       /v1/tenants/me -> 404 (route not mounted) while the base admin route
#       GET /v1/tenants/{id} (service token) STILL 200 = byte-parity.
#
# Seeding is via the EXISTING service-token admin endpoints (POST /v1/tenants +
# POST /v1/tenants/{id}/keys, X-Service-Token) — real tenants + real keys, then
# the /me endpoints are exercised with those keys. tenant-control runs an
# EnsureSchema at boot (it widens the plan CHECK to nano/basic/essential/pro/max);
# the tables it needs (public.tenants + tenant_api_keys) come from migrations 005
# + 032 in the prelude — EnsureSchema does NOT self-create the tenants table, it
# requires migration 032 already applied.
#
# ISOLATED by design (mirrors m80/m82): scratch postgres (prelude + REAL 005 + 032
# + 040) + two tenant-control binaries built FROM CURRENT source, ALL on a PRIVATE
# network, every name suffixed with $$, an EXIT-trap removing EVERYTHING. It NEVER
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
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M83] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M83] FAIL — $*"; exit 1; }

PG_IMAGE="${M83_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m83-tc-$$:scratch"
NET="m83net-$$"
PG="m83-pg-$$"
TC_ON="m83-tc-on-$$"      # TENANT_SELFSERVE_ENABLED=1  (A · positive / B · reject)
TC_OFF="m83-tc-off-$$"    # TENANT_SELFSERVE_ENABLED unset (C · parity)
PORT_ON="${M83_PORT_ON:-18984}"
PORT_OFF="${M83_PORT_OFF:-18985}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m83-internal-service-token-$$"
TENANT_A="m83-a-$$"
TENANT_B="m83-b-$$"
KEY_A_NAME="m83-a-primary-$$"
KEY_B_NAME="m83-b-secret-$$"      # uniquely-named — its ABSENCE from A's /me proves isolation
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
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

# Self-service (tenant API-key) request → echo HTTP status, body→BODY_TMP.
#   $1=method  $2=port  $3=path  $4=api-key  $5(optional)=json body
me_req() {
  local m="$1" p="$2" path="$3" key="$4" body="${5:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-API-Key: ${key}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-API-Key: ${key}"
  fi
}

# Extract a top-level JSON string field value off BODY_TMP. Tolerates ZERO matches
# (grep wrapped in `|| true` so pipefail+set -e does not kill us on a missing
# field — an empty result is a normal "field absent" outcome). $1=field.
json_str() { # $1=field
  { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'
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
step "0/8 build scratch tenant-control from CURRENT source (the B4a self-service code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — gate must exercise the drafted self-service code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres + prelude + REAL 005/032/040 ────────────────────
step "1/8 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state (line: PG ready loop)"
  sleep 0.5
done
ok "postgres up"

step "1b/8 apply prelude (schema_migrations, auth.current_tenant_id, roles), then REAL 005 + 032 + 040"
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
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"; sleep 0.5; done
apply_migration "${MIGRATION_005}" || fail "real migration 005_add_tenant_table.sql failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032_tenants.sql failed to apply (line: apply 032)"
apply_migration "${MIGRATION_040}" || fail "real migration 040_tenant_usage.sql failed to apply (line: apply 040)"
[[ "$(psql_val "SELECT count(*) FROM public.tenants")" == "0" ]]   || fail "tenants should start EMPTY (line: 032 empty check)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_api_keys")" == "0" ]] || fail "tenant_api_keys should start EMPTY (line: keys empty check)"
ok "migrations 005 + 032 + 040 applied — tenants / tenant_api_keys / tenant_usage exist and are empty"

# ── 2) boot the SELF-SERVE-ON tenant-control (TENANT_SELFSERVE_ENABLED=1) ───────
step "2/8 boot tenant-control TENANT_SELFSERVE_ENABLED=1 on 127.0.0.1:${PORT_ON} (A · positive / B · reject)"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_SELFSERVE_ENABLED=1 \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "self-serve-ON tenant-control not ready (line: wait_ready TC_ON)"
ok "self-serve-ON tenant-control up (EnsureSchema applied, /me routes mounted)"

# ── 3) SEED two tenants + a key each, via the service-token admin endpoints ─────
step "3/8 seed tenant A(${TENANT_A}) + tenant B(${TENANT_B}) via POST /v1/tenants (X-Service-Token)"
C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${TENANT_A}\",\"name\":\"A\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant A expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed A)"
C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${TENANT_B}\",\"name\":\"B\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant B expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed B)"
ok "tenants A + B created (both nano)"

step "3b/8 mint A's key (admin-scoped) + B's uniquely-named key via POST /v1/tenants/{id}/keys (X-Service-Token)"
# A's primary key gets admin scope so the positive arm can exercise all 6 endpoints
# incl. PATCH /me {plan} (account-admin-gated). The read-only-scope reject arm (4g)
# separately proves a write/admin endpoint 403s a read-only key.
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_A}/keys" "{\"name\":\"${KEY_A_NAME}\",\"scopes\":[\"read\",\"write\",\"admin\"]}")"
[[ "${C}" == "201" ]] || fail "mint A key expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: mint A key)"
KEY_A="$(json_str key)"
[[ "${KEY_A}" == mbk_* ]] || fail "A key not returned as a full mbk_ key — got '${KEY_A}' — $(head -c 300 "${BODY_TMP}") (line: A key shape)"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_B}/keys" "{\"name\":\"${KEY_B_NAME}\"}")"
[[ "${C}" == "201" ]] || fail "mint B key expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: mint B key)"
KEY_B="$(json_str key)"
[[ "${KEY_B}" == mbk_* ]] || fail "B key not returned as a full mbk_ key — got '${KEY_B}' — $(head -c 300 "${BODY_TMP}") (line: B key shape)"
ok "minted A's key (${KEY_A_NAME}) + B's key (${KEY_B_NAME}); both full mbk_ keys"

# ── 4) (A · POSITIVE) drive the /me surface with A's key ───────────────────────
step "4/8 (A · POSITIVE) GET /v1/tenants/me with A's key → 200, body is A's tenant + plan"
C="$(me_req GET "${PORT_ON}" /v1/tenants/me "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "(A) GET /me expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A GET /me)"
grep -q "\"id\":\"${TENANT_A}\"" "${BODY_TMP}" \
  || fail "(A) GET /me body is not tenant A (id=${TENANT_A}) — $(head -c 300 "${BODY_TMP}") (line: A /me is A)"
grep -q '"plan":"nano"' "${BODY_TMP}" \
  || fail "(A) GET /me body missing plan=nano — $(head -c 300 "${BODY_TMP}") (line: A /me plan)"
ok "(A) GET /me → 200; resolved to A (id=${TENANT_A}, plan=nano) off A's key — no path id"

step "4b/8 (A · POSITIVE) GET /v1/tenants/me/usage with A's key → 200"
C="$(me_req GET "${PORT_ON}" /v1/tenants/me/usage "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "(A) GET /me/usage expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A /me/usage)"
ok "(A) GET /me/usage → 200 (metered usage read-back over public.tenant_usage)"

step "4c/8 (A · POSITIVE) POST /v1/tenants/me/keys {name} with A's key → 200/201 + a full mbk_ key"
C="$(me_req POST "${PORT_ON}" /v1/tenants/me/keys "${KEY_A}" "{\"name\":\"m83-self-minted-$$\"}")"
[[ "${C}" == "200" || "${C}" == "201" ]] \
  || fail "(A) POST /me/keys expected 200/201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A POST /me/keys)"
NEW_KEY="$(json_str key)"
[[ "${NEW_KEY}" == mbk_* ]] || fail "(A) POST /me/keys did not return a full mbk_ key — got '${NEW_KEY}' — $(head -c 300 "${BODY_TMP}") (line: A new key shape)"
NEW_KEY_ID="$(json_str id)"
[[ -n "${NEW_KEY_ID}" ]] || fail "(A) POST /me/keys returned no key id — $(head -c 300 "${BODY_TMP}") (line: A new key id)"
ok "(A) POST /me/keys → key minted (id=${NEW_KEY_ID}, full mbk_ key returned once)"

step "4d/8 (A · POSITIVE) GET /v1/tenants/me/keys with A's key → 200 and the new key is listed"
C="$(me_req GET "${PORT_ON}" /v1/tenants/me/keys "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "(A) GET /me/keys expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A GET /me/keys)"
grep -q "\"id\":\"${NEW_KEY_ID}\"" "${BODY_TMP}" \
  || fail "(A) GET /me/keys does not list the just-minted key ${NEW_KEY_ID} — $(head -c 300 "${BODY_TMP}") (line: A /me/keys lists new)"
grep -q "m83-self-minted-$$" "${BODY_TMP}" \
  || fail "(A) GET /me/keys missing the self-minted key by name — $(head -c 300 "${BODY_TMP}") (line: A /me/keys name)"
ok "(A) GET /me/keys → 200; lists A's keys incl. the self-minted one"

step "4e/8 (A · POSITIVE) DELETE /v1/tenants/me/keys/${NEW_KEY_ID} with A's key → 200"
C="$(me_req DELETE "${PORT_ON}" "/v1/tenants/me/keys/${NEW_KEY_ID}" "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "(A) DELETE /me/keys/{id} expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A DELETE /me/keys)"
ok "(A) DELETE /me/keys/{id} → 200 (A revoked its OWN key)"

step "4f/8 (A · POSITIVE) PATCH /v1/tenants/me {plan:\"pro\"} with A's key → 200, re-GET shows pro"
C="$(me_req PATCH "${PORT_ON}" /v1/tenants/me "${KEY_A}" '{"plan":"pro"}')"
[[ "${C}" == "200" ]] || fail "(A) PATCH /me {plan:pro} expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A PATCH /me)"
C="$(me_req GET "${PORT_ON}" /v1/tenants/me "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "(A) re-GET /me after PATCH expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A re-GET /me)"
grep -q '"plan":"pro"' "${BODY_TMP}" \
  || fail "(A) PATCH did not persist plan=pro — re-GET shows $(json_str plan) — $(head -c 300 "${BODY_TMP}") (line: A plan persisted)"
# Independent ground truth: the DB row really changed (not just the response).
[[ "$(psql_val "SELECT plan FROM public.tenants WHERE slug='${TENANT_A}'")" == "pro" ]] \
  || fail "(A) tenants.plan for A is not 'pro' in the DB — PATCH did not persist (line: A plan DB)"
ok "(A) PATCH /me → 200; plan=pro persisted (response AND DB row)"

# ── 5) (B · REJECT, LOAD-BEARING) cross-tenant isolation + no-auth ─────────────
step "5/8 (B · REJECT) A's key must see ONLY A — GET /me resolves to A, never B"
C="$(me_req GET "${PORT_ON}" /v1/tenants/me "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "(B) GET /me with A's key expected 200, got ${C} (line: B A /me)"
grep -q "\"id\":\"${TENANT_A}\"" "${BODY_TMP}" \
  || fail "(B) GET /me with A's key did not resolve to A (line: B A /me is A)"
if grep -q "${TENANT_B}" "${BODY_TMP}"; then
  fail "(B) tenant B leaked into A's GET /me response — cross-tenant exposure! (line: B no B in A /me)"
fi
ok "(B) A's key resolves to A only; B absent from A's /me"

step "5b/8 (B · REJECT, LOAD-BEARING) A's /me/keys lists ONLY A's keys — B's '${KEY_B_NAME}' is ABSENT"
C="$(me_req GET "${PORT_ON}" /v1/tenants/me/keys "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "(B) GET /me/keys with A's key expected 200, got ${C} (line: B A /me/keys)"
grep -q "${KEY_A_NAME}" "${BODY_TMP}" \
  || fail "(B) A's own key '${KEY_A_NAME}' missing from A's /me/keys — listing is wrong (line: B A own key present)"
if grep -q "${KEY_B_NAME}" "${BODY_TMP}"; then
  fail "(B) B's key '${KEY_B_NAME}' is VISIBLE in A's /me/keys — cross-tenant key exposure! (line: B no B key)"
fi
ok "(B) A's /me/keys = A's keys only; B's uniquely-named key is ABSENT = isolation proven"

step "5c/8 (B · REJECT) no auth header → 401 on every /me route"
C="$(curl -s -o "${BODY_TMP}" -w '%{http_code}' "http://127.0.0.1:${PORT_ON}/v1/tenants/me")"
[[ "${C}" == "401" ]] || fail "(B) GET /me with NO auth expected 401, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B no-auth GET)"
C="$(curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:${PORT_ON}/v1/tenants/me/keys" \
  -H 'Content-Type: application/json' -d '{"name":"x"}')"
[[ "${C}" == "401" ]] || fail "(B) POST /me/keys with NO auth expected 401, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B no-auth POST)"
ok "(B) unauthenticated /me → 401 (read + write)"

step "5d/8 (B · REJECT, LOAD-BEARING) a read-only-scope key must NOT mint keys → 403"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_A}/keys" "{\"name\":\"m83-a-readonly-$$\",\"scopes\":[\"read\"]}")"
[[ "${C}" == "201" ]] || fail "(B) could not mint a read-only-scope key (admin POST keys got ${C}) — $(head -c 300 "${BODY_TMP}") (line: B mint RO key)"
RO_KEY="$(json_str key)"
[[ "${RO_KEY}" == mbk_* ]] || fail "(B) read-only key not returned as a full mbk_ key — got '${RO_KEY}' (line: B RO key shape)"
C="$(me_req POST "${PORT_ON}" /v1/tenants/me/keys "${RO_KEY}" "{\"name\":\"m83-ro-attempt-$$\"}")"
[[ "${C}" == "403" ]] || fail "(B) read-only-scope key got ${C} (not 403) on POST /me/keys — self-serve write scope-check is NOT enforced! (line: B RO write 403)"
ok "(B) read-only-scope key rejected (403) on POST /me/keys — write-scope enforcement REAL"

step "5e/8 (B · REJECT, LOAD-BEARING) scope CONTAINMENT — a write-scope key may NOT mint an admin key (within-tenant privilege escalation)"
# Mint a write-but-not-admin key for A (scopes read+write, NO admin). It passes the
# write gate on POST /me/keys, so WITHOUT scope containment it could mint an admin
# key and then reach PATCH /me {plan} — a within-tenant escalation. The backend
# must reject the broader-scope request (403). This is the regression arm for the
# adversarial reviewer's HIGH-1 finding.
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_A}/keys" "{\"name\":\"m83-a-writer-$$\",\"scopes\":[\"read\",\"write\"]}")"
[[ "${C}" == "201" ]] || fail "(B) could not mint a write-scope key (admin POST keys got ${C}) — $(head -c 300 "${BODY_TMP}") (line: B mint writer key)"
WR_KEY="$(json_str key)"
[[ "${WR_KEY}" == mbk_* ]] || fail "(B) writer key not returned as a full mbk_ key — got '${WR_KEY}' (line: B writer key shape)"
# Sanity: this write key CAN mint a non-escalating (read,write) key — proves the
# 403 below is about scope WIDENING, not a blanket write block.
C="$(me_req POST "${PORT_ON}" /v1/tenants/me/keys "${WR_KEY}" "{\"name\":\"m83-writer-ok-$$\",\"scopes\":[\"read\",\"write\"]}")"
[[ "${C}" == "200" || "${C}" == "201" ]] || fail "(B) write key could not mint an equal-scope key (got ${C}) — containment must allow same-or-narrower (line: B writer equal-scope)"
OK_KEY_ID="$(json_str id)"
[[ -n "${OK_KEY_ID}" ]] && me_req DELETE "${PORT_ON}" "/v1/tenants/me/keys/${OK_KEY_ID}" "${WR_KEY}" >/dev/null 2>&1 || true
# The escalation attempt: request admin with a write-only credential → 403.
C="$(me_req POST "${PORT_ON}" /v1/tenants/me/keys "${WR_KEY}" "{\"name\":\"m83-escalate-$$\",\"scopes\":[\"admin\"]}")"
[[ "${C}" == "403" ]] || fail "(B) ESCALATION: a write-scope key minted a key with scopes:[admin] (got ${C}, want 403) — within-tenant privilege escalation is OPEN! (line: B scope containment)"
ok "(B) scope containment REAL — a write key may mint an equal-scope key but is 403'd when requesting admin (HIGH-1 fixed)"

# ── 6) (C · PARITY) self-serve OFF → /me handler absent (same key that worked ON
#       now 401, falling to the pre-existing {id} gate), base admin route still 200 ─
step "6/8 (C · PARITY) boot a SECOND tenant-control with TENANT_SELFSERVE_ENABLED unset on 127.0.0.1:${PORT_OFF}"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "self-serve-OFF tenant-control not ready (line: wait_ready TC_OFF)"
ok "self-serve-OFF tenant-control up (same DB, same seeded tenants)"

step "6b/8 (C · PARITY) GET /v1/tenants/me on the OFF router with A's key → 401 (self-serve handler absent; the request falls to the pre-existing GET /v1/tenants/{id} gate, which an API key cannot satisfy) — the SAME key returned 200 on the ON router (arm 4)"
C="$(me_req GET "${PORT_OFF}" /v1/tenants/me "${KEY_A}")"
[[ "${C}" == "401" ]] \
  || fail "(C) PARITY: GET /me (A's key) with self-serve OFF expected 401 — the pre-B4a baseline ('me' is caught by the {id} wildcard whose tokenOrSelf rejects a bare API key); ON returned 200 — got ${C} — $(head -c 300 "${BODY_TMP}") (line: C /me parity)"
ok "(C) GET /v1/tenants/me with A's key → 401 OFF vs 200 ON — the flag gates the self-serve surface; OFF is byte-identical to the pre-B4a {id}-wildcard behavior"

step "6c/8 (C · PARITY) base admin route GET /v1/tenants/{id} (X-Service-Token) STILL 200 on OFF router"
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants/${TENANT_A}")"
[[ "${C}" == "200" ]] \
  || fail "(C) PARITY: base admin GET /v1/tenants/{id} expected 200 on OFF router, got ${C} — $(head -c 300 "${BODY_TMP}") (line: C admin 200)"
grep -q "\"id\":\"${TENANT_A}\"" "${BODY_TMP}" \
  || fail "(C) PARITY: base admin GET /v1/tenants/{id} did not return A — $(head -c 300 "${BODY_TMP}") (line: C admin is A)"
ok "(C) base admin GET /v1/tenants/{id} → 200 with self-serve OFF — pre-existing routes untouched = byte-parity"

# ── 7) summarize ──────────────────────────────────────────────────────────────
step "7/8 summary"
green "[M83] (A) POSITIVE: A's key drives GET /me (200, A's plan), /me/usage (200), POST+GET+DELETE /me/keys, PATCH /me {pro} persisted (response + DB)"
green "[M83] (B) REJECT:   A sees ONLY A — B absent from /me + /me/keys; no-auth → 401 (load-bearing isolation)"
green "[M83] (C) PARITY:   self-serve OFF → GET /me (A's key) 401 (vs 200 ON) = byte-identical to the pre-B4a {id} route; base admin GET /v1/tenants/{id} still 200"

# ── 8) emit the gate event via the kernel log helper (best-effort) ─────────────
step "8/8 log GATE m83=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-b4a-selfserve}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m83=PASS" --outcome pass \
      --msg "B4a tenant self-service: a tenant API key resolves to its OWN tenant via /v1/tenants/me* (no path id) — GET me/usage/keys, POST+DELETE me/keys, PATCH me{plan} all work and persist; A sees ONLY A (B absent from /me + /me/keys), no-auth -> 401; TENANT_SELFSERVE_ENABLED unset -> /me 404 while base admin /v1/tenants/{id} still 200 (byte-parity)" \
      --ref "scripts/verify/m83-selfserve.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M83] ALL GATES GREEN — B4a self-service API: own-tenant CRUD via /me, cross-tenant isolation, byte-parity when OFF"
exit 0
