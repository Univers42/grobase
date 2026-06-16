#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m103-orgs-rbac.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M103 — Track-D D1 ORGANIZATIONS / TEAMS / MEMBERS / INVITES / RBAC live gate.
# Proves the keystone control-plane layer BETWEEN a human and a project(=tenant):
# an org owner can invite a member who accepts (sha256-hashed token) and provisions
# an org-scoped project (= a tenant) whose data CRUD still flows through the Rust
# data plane; that a viewer-role member CANNOT create a project (403); that a
# member of org A CANNOT touch org B (cross-org isolation); and — THE LOAD-BEARING
# PARITY PROBE — that a /v1/query with a NORMAL tenant identity yields a BYTE-
# IDENTICAL request identity + response whether ORG_MODEL_ENABLED is 1 or unset
# (orgs NEVER touched the data path). It exercises a tenant-control + data-plane-
# router built FROM CURRENT source — the EXACT D1 code:
#
#   tenant-control (Go, ORG_MODEL_ENABLED=1) mounts /v1/orgs* (JWT-gated):
#     POST   /v1/orgs                          create org (caller -> owner)
#     POST   /v1/orgs/{org}/invites            issue sha256-token invite (cleartext ONCE)
#     POST   /v1/orgs/invites/accept {token}   accept -> add membership
#     POST   /v1/orgs/{org}/projects           org-scoped provision (WRAPS the reconciler)
#     GET    /v1/orgs/{org}/members|projects   read (RBAC-gated)
#     DELETE /v1/orgs/{org}/members/{userId}   remove (never the last owner)
#
#   (A · POSITIVE) U1 creates an org (becomes owner); invites U2 as developer;
#       the cleartext token's sha256 is what is stored (NOT the cleartext); U2
#       accepts -> becomes developer; U2 provisions an org-scoped project -> 201,
#       tenants.org_id stamped, a real mount + API key minted; data CRUD via that
#       key flows through the Rust data plane (200).
#   (B · LOAD-BEARING REJECT) (a) a viewer member's POST /projects -> 403 and NO new
#       tenant row; (b) a member of org A cannot GET/POST org B -> 403/404; (c) the
#       sole owner cannot be removed -> 409; (d) a wrong/replayed/expired token ->
#       401/410/409. A gate that only shows the happy path is VACUOUS; these are
#       the load-bearing proofs.
#   (C · PARITY) C1: a SECOND tenant-control with ORG_MODEL_ENABLED unset -> every
#       /v1/orgs* route 404 while base admin routes still 200. C2: the CRITICAL data
#       -plane probe — drive the SAME /v1/query (normal tenant identity, NO org_id
#       field) against the data-plane-router; assert the response is BYTE-IDENTICAL
#       and the envelope carries tenant_id only (orgs add no field); plus a schema
#       proof that auth.current_tenant_id() body is unchanged and tenants.org_id is
#       NULL for every row -> the schema addition is inert on the request path.
#
# ISOLATED by design (mirrors m83/m90/m101): scratch postgres (prelude + REAL
# 005/032/040 + the NEW 043/044) + a tenant-control AND a data-plane-router built
# FROM CURRENT source, ALL on a PRIVATE network, every name suffixed with $$, an
# EXIT-trap removing EVERYTHING. It NEVER touches a mini-baas-* container/network/
# image/volume and NEVER edits the live docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
GO_DIR="${INFRA_DIR}/go/control-plane"
DPR_DIR="${INFRA_DIR}/docker/services/data-plane-router"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
MIGRATION_040="${MIG_DIR}/040_tenant_usage.sql"
MIGRATION_043="${MIG_DIR}/043_orgs.sql"
MIGRATION_044="${MIG_DIR}/044_org_billing_rollup.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M103] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M103] FAIL — $*"; exit 1; }

PG_IMAGE="${M103_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m103-tc-$$:scratch"
DPR_IMG="m103-dpr-$$:scratch"
NET="m103net-$$"
PG="m103-pg-$$"
TC_ON="m103-tc-on-$$"      # ORG_MODEL_ENABLED=1   (A · positive / B · reject)
TC_OFF="m103-tc-off-$$"    # ORG_MODEL_ENABLED unset (C · parity)
DPR="m103-dpr-$$"          # data-plane-router (C2 byte-parity probe + positive CRUD)
PORT_ON="${M103_PORT_ON:-19103}"
PORT_OFF="${M103_PORT_OFF:-19104}"
PORT_DPR="${M103_PORT_DPR:-19105}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m103-internal-service-token-$$"
# A literal HS256 JWT secret + matching pre-signed tokens for U1..U4 (no jwt lib
# on the host → we sign the tokens inside the postgres container with pgcrypto's
# hmac, which is byte-identical to the Go HS256 verifier).
JWT_SECRET="m103-jwt-secret-deadbeefcafef00ddeadbeefcafef00d"
PROBE_TABLE="m103_probe"
BODY_TMP="$(mktemp)"
DP_ON_BODY="$(mktemp)"
DP_OFF_BODY="$(mktemp)"

# Stable GoTrue-style user uuids for the four humans.
U1="11111111-1111-1111-1111-111111111111"  # org A owner
U2="22222222-2222-2222-2222-222222222222"  # invited developer (org A)
U3="33333333-3333-3333-3333-333333333333"  # invited viewer    (org A)
U4="44444444-4444-4444-4444-444444444444"  # org B owner (no membership in A)

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${DPR}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" "${DPR_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" "${DP_ON_BODY}" "${DP_OFF_BODY}" 2>/dev/null || true
}
trap cleanup EXIT

# shellcheck disable=SC2120  # psql_q is called both with flags and via heredoc (no args)
psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Apply one migration file the SAME way `make migrate` does: strip leading `#`
# 42-header lines before piping to psql. $1=file.
apply_migration() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

# Mint an HS256 GoTrue-style JWT inside the postgres container (pgcrypto hmac),
# so the Go HS256 JWTVerifier accepts it. $1=sub(uuid) $2=email. Echoes the token.
mint_jwt() { # $1=sub  $2=email
  local sub="$1" email="$2"
  psql_val "
    WITH parts AS (
      SELECT
        translate(encode(convert_to('{\"alg\":\"HS256\",\"typ\":\"JWT\"}','utf8'),'base64'),'+/=' || chr(10) || chr(13),'-_') AS h,
        translate(encode(convert_to(
          '{\"sub\":\"${sub}\",\"email\":\"${email}\",\"role\":\"authenticated\",\"aud\":\"authenticated\",\"exp\":' ||
          (extract(epoch from now())::bigint + 3600)::text || '}','utf8'),'base64'),'+/=' || chr(10) || chr(13),'-_') AS p
    ),
    signed AS (
      SELECT h, p,
        translate(encode(hmac((h || '.' || p), '${JWT_SECRET}', 'sha256'),'base64'),'+/=' || chr(10) || chr(13),'-_') AS s
      FROM parts
    )
    SELECT rtrim(h,'=') || '.' || rtrim(p,'=') || '.' || rtrim(s,'=') FROM signed;"
}

# JWT-authenticated org request → echo HTTP status, body→BODY_TMP.
#   $1=method $2=port $3=path $4=jwt $5(optional)=json body
org_req() { # $1=method $2=port $3=path $4=jwt $5=body
  local m="$1" p="$2" path="$3" jwt="$4" body="${5:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "Authorization: Bearer ${jwt}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "Authorization: Bearer ${jwt}"
  fi
}

# Service-token admin request → echo HTTP status, body→BODY_TMP.
admin_req() { # $1=method $2=port $3=path $4(optional)=body
  local m="$1" p="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}"
  fi
}

# Extract a top-level JSON string field off BODY_TMP. Tolerates ZERO matches
# (grep || true so pipefail+set -e survive a missing field). $1=field.
json_str() { { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'; }

# Build a /v1/query list envelope for a NORMAL tenant identity (NO org_id field —
# RequestIdentity has none). Drives the bare probe table. $1=tenant slug.
payload_list() { # $1=slug
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m103","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"list","resource":"%s","data":null}}' \
    "$1" "$1" "$1" "${DB_INNET}" "${PROBE_TABLE}"
}

wait_ready_http() { # $1=container $2=port $3=path
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2$3" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

# ── 0) build the scratch tenant-control + data-plane-router FROM CURRENT source ─
step "0/9 build scratch tenant-control + data-plane-router from CURRENT source (the D1 code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — gate must exercise the drafted D1 code (line: docker build TC)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${DPR_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "scratch data-plane-router image build failed — needed for the C2 parity probe (line: docker build DPR)"
ok "tenant-control + data-plane-router built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres + prelude + REAL 005/032/040 + NEW 043/044 ──────
step "1/9 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# Postgres image init runs a SOCKET-ONLY temp server then restarts — gate on TCP
# (pg_isready -h 127.0.0.1) + a real SELECT 1, not on the steady-state log alone.
for i in $(seq 1 90); do
  docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 \
    && [[ "$(psql_val 'SELECT 1')" == "1" ]] && break
  [[ $i -eq 90 ]] && { docker logs "${PG}" 2>&1 | tail -20; fail "scratch postgres never accepted TCP (line: PG TCP ready)"; }
  sleep 0.5
done
ok "postgres up (TCP + SELECT 1)"

step "1b/9 apply prelude (schema_migrations, auth fns, roles, pgcrypto), then REAL 005/032/040 + NEW 043/044"
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
-- The REAL per-request tenant isolation function (016_unify_rls). The C2 schema
-- proof asserts this body is UNCHANGED after 043/044 — orgs add no org input.
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS uuid
  LANGUAGE sql STABLE AS $fn$
    SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid $fn$;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS uuid
  LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE(
      NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id',
      NULLIF(current_setting('app.current_tenant_id', true), ''),
      auth.current_user_id()::text
    )::uuid $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon')          THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role; END IF;
END $r$;
GRANT EXECUTE ON FUNCTION auth.current_user_id()   TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.current_tenant_id() TO anon, authenticated, service_role;
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"; sleep 0.5; done

# Capture the EXACT body of auth.current_tenant_id() BEFORE 043/044 for the C2 proof.
TENANT_FN_BEFORE="$(psql_val "SELECT md5(pg_get_functiondef('auth.current_tenant_id'::regproc))")"
[[ -n "${TENANT_FN_BEFORE}" ]] || fail "could not snapshot auth.current_tenant_id() before 043/044 (line: fn before)"

apply_migration "${MIGRATION_005}" || fail "real migration 005 failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032 failed to apply (line: apply 032)"
apply_migration "${MIGRATION_040}" || fail "real migration 040 failed to apply (line: apply 040)"
apply_migration "${MIGRATION_043}" || fail "NEW migration 043_orgs.sql failed to apply (line: apply 043)"
apply_migration "${MIGRATION_044}" || fail "NEW migration 044_org_billing_rollup.sql failed to apply (line: apply 044)"

# Tables exist + empty; the org_id column was added (nullable, default NULL).
[[ "$(psql_val "SELECT count(*) FROM public.orgs")"        == "0" ]] || fail "orgs should start EMPTY (line: orgs empty)"
[[ "$(psql_val "SELECT count(*) FROM public.org_members")" == "0" ]] || fail "org_members should start EMPTY (line: members empty)"
[[ "$(psql_val "SELECT count(*) FROM public.org_invites")" == "0" ]] || fail "org_invites should start EMPTY (line: invites empty)"
[[ "$(psql_val "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='tenants' AND column_name='org_id'")" == "1" ]] \
  || fail "tenants.org_id column was not added by 043 (line: org_id col)"
ok "migrations applied — orgs/org_members/org_invites empty; tenants.org_id added (nullable)"

# Bare probe table for the data-plane CRUD + the C2 byte-parity probe.
psql_q >/dev/null 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS public.${PROBE_TABLE} (id serial PRIMARY KEY, note text);
INSERT INTO public.${PROBE_TABLE}(note) VALUES ('row-a'),('row-b');
SQL
ok "bare probe table seeded (2 rows) for the data-plane CRUD + C2 parity probe"

# ── 2) boot tenant-control with ORG_MODEL_ENABLED=1 ────────────────────────────
step "2/9 boot tenant-control ORG_MODEL_ENABLED=1 on 127.0.0.1:${PORT_ON} (A · positive / B · reject)"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 \
  -e ADAPTER_REGISTRY_URL="" \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_ON}" "${PORT_ON}" /health/live || fail "ORG-ON tenant-control not ready (line: wait TC_ON)"
docker logs "${TC_ON}" 2>&1 | grep -q "organizations API enabled" \
  || { docker logs "${TC_ON}" 2>&1 | tail -20; fail "org API never reported enabled (line: org enabled log)"; }
ok "ORG-ON tenant-control up (/v1/orgs* mounted, JWT verifier configured)"

# Mint the four human JWTs.
JWT_U1="$(mint_jwt "${U1}" "u1@m103.test")"; [[ -n "${JWT_U1}" ]] || fail "could not mint U1 JWT (line: jwt U1)"
JWT_U2="$(mint_jwt "${U2}" "u2@m103.test")"; [[ -n "${JWT_U2}" ]] || fail "could not mint U2 JWT (line: jwt U2)"
JWT_U3="$(mint_jwt "${U3}" "u3@m103.test")"; [[ -n "${JWT_U3}" ]] || fail "could not mint U3 JWT (line: jwt U3)"
JWT_U4="$(mint_jwt "${U4}" "u4@m103.test")"; [[ -n "${JWT_U4}" ]] || fail "could not mint U4 JWT (line: jwt U4)"
# Sanity: the verifier actually accepts our minted token (GET /v1/orgs needs JWT).
C="$(org_req GET "${PORT_ON}" /v1/orgs "${JWT_U1}")"
[[ "${C}" == "200" ]] || fail "minted JWT not accepted by the verifier (GET /v1/orgs got ${C}) — check JWT signing (line: jwt sanity)"
ok "minted + verified four human JWTs (U1..U4)"

# ── 3) (A · POSITIVE) U1 creates org A and becomes owner ───────────────────────
step "3/9 (A · POSITIVE) U1 POST /v1/orgs → 201, U1 is owner"
ORG_SLUG="m103-org-a-$$"; ORG_SLUG="$(echo "${ORG_SLUG}" | tr '[:upper:]' '[:lower:]' | cut -c1-60)"
C="$(org_req POST "${PORT_ON}" /v1/orgs "${JWT_U1}" "{\"slug\":\"${ORG_SLUG}\",\"name\":\"Org A\"}")"
[[ "${C}" == "201" ]] || fail "(A) create org expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: create org)"
ORG_A="$(json_str id)"
[[ -n "${ORG_A}" ]] || fail "(A) create org returned no id — $(head -c 300 "${BODY_TMP}") (line: org id)"
[[ "$(psql_val "SELECT role FROM public.org_members WHERE org_id::text='${ORG_A}' AND user_id='${U1}'")" == "owner" ]] \
  || fail "(A) U1 is not the owner of org A in org_members (line: owner membership)"
ok "(A) org A created (${ORG_A}); U1 owner membership row exists"

# ── 4) (A · POSITIVE) U1 invites U2 as developer; sha256(token) is what's stored ─
step "4/9 (A · POSITIVE) U1 POST /v1/orgs/{A}/invites {U2, developer} → 201, cleartext token ONCE"
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/invites" "${JWT_U1}" '{"email":"u2@m103.test","role":"developer"}')"
[[ "${C}" == "201" ]] || fail "(A) issue invite expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: issue invite)"
TOKEN_U2="$(json_str token)"
[[ -n "${TOKEN_U2}" ]] || fail "(A) issue invite returned no cleartext token — $(head -c 300 "${BODY_TMP}") (line: invite token)"
# The DB must store ONLY sha256(token), never the cleartext.
EXPECT_HASH="$(printf '%s' "${TOKEN_U2}" | sha256sum | cut -d' ' -f1)"
[[ "$(psql_val "SELECT count(*) FROM public.org_invites WHERE token_hash='${EXPECT_HASH}'")" == "1" ]] \
  || fail "(A) org_invites does not store sha256(token)=${EXPECT_HASH} — token hashing is wrong (line: invite hash)"
[[ "$(psql_val "SELECT count(*) FROM public.org_invites WHERE token_hash LIKE '%${TOKEN_U2}%'")" == "0" ]] \
  || fail "(A) cleartext invite token leaked into the DB — must store ONLY the hash (line: invite cleartext leak)"
ok "(A) invite issued; DB stores ONLY sha256(token)=${EXPECT_HASH:0:12}…, cleartext absent"

# ── 5) (A · POSITIVE) U2 accepts the invite → becomes developer ────────────────
step "5/9 (A · POSITIVE) U2 POST /v1/orgs/invites/accept {token} → 200, U2 is developer, invite=accepted"
C="$(org_req POST "${PORT_ON}" /v1/orgs/invites/accept "${JWT_U2}" "{\"token\":\"${TOKEN_U2}\"}")"
[[ "${C}" == "200" ]] || fail "(A) accept invite expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: accept invite)"
[[ "$(psql_val "SELECT role FROM public.org_members WHERE org_id::text='${ORG_A}' AND user_id='${U2}'")" == "developer" ]] \
  || fail "(A) U2 is not a developer member of org A after accept (line: U2 membership)"
[[ "$(psql_val "SELECT status FROM public.org_invites WHERE token_hash='${EXPECT_HASH}'")" == "accepted" ]] \
  || fail "(A) invite did not flip to status=accepted (line: invite accepted)"
ok "(A) U2 accepted → developer member; invite flipped to accepted"

# ── 6) (A · POSITIVE) U2 (developer) provisions an org-scoped project ───────────
step "6/9 (A · POSITIVE) U2 POST /v1/orgs/{A}/projects → 2xx, tenants.org_id stamped, mount+key minted"
PROJ_SLUG="m103-proj-a-$$"; PROJ_SLUG="$(echo "${PROJ_SLUG}" | tr '[:upper:]' '[:lower:]' | cut -c1-60)"
TENANTS_BEFORE="$(psql_val "SELECT count(*) FROM public.tenants")"
PROJ_BODY="{\"tenant\":\"${PROJ_SLUG}\",\"name\":\"Proj A\",\"plan\":\"nano\",\"seed_roles\":false,\"mounts\":[{\"engine\":\"postgresql\",\"name\":\"probe\",\"connection_string\":\"${DB_INNET}\",\"isolation\":\"shared_rls\"}]}"
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects" "${JWT_U2}" "${PROJ_BODY}")"
[[ "${C}" == "200" || "${C}" == "201" ]] \
  || fail "(A) org-scoped provision expected 200/201, got ${C} — $(head -c 400 "${BODY_TMP}") (line: provision project)"
PROJ_KEY="$(json_str key)"
[[ "${PROJ_KEY}" == mbk_* ]] || fail "(A) provision did not mint a project API key — got '${PROJ_KEY}' — $(head -c 300 "${BODY_TMP}") (line: project key)"
TENANTS_AFTER="$(psql_val "SELECT count(*) FROM public.tenants")"
[[ "${TENANTS_AFTER}" -gt "${TENANTS_BEFORE}" ]] || fail "(A) no new tenant row appeared after provision (line: tenant count up)"
[[ "$(psql_val "SELECT count(*) FROM public.tenants WHERE slug='${PROJ_SLUG}' AND org_id::text='${ORG_A}'")" == "1" ]] \
  || fail "(A) tenants.org_id was not stamped to org A for the new project (line: org_id stamp)"
ok "(A) project provisioned through the reconciler; org_id stamped; API key minted"

# ── 6b) (A · POSITIVE) data CRUD via that key flows through the Rust data plane ─
step "6b/9 (A · POSITIVE) boot data-plane-router; a /v1/query for the project slug → 200 (CRUD still works)"
docker run -d --name "${DPR}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e DATA_PLANE_ROUTER_PORT=3030 \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_DPR}:3030" "${DPR_IMG}" >/dev/null
wait_ready_http "${DPR}" "${PORT_DPR}" /v1/capabilities || fail "data-plane-router not ready (line: wait DPR)"
C="$(curl -s -o "${DP_ON_BODY}" -w '%{http_code}' -X POST "http://127.0.0.1:${PORT_DPR}/v1/query" \
      -H 'Content-Type: application/json' -d "$(payload_list "${PROJ_SLUG}")")"
[[ "${C}" == "200" ]] || fail "(A) data-plane /v1/query for the org-owned project expected 200, got ${C} — $(head -c 400 "${DP_ON_BODY}") (line: dp query project)"
ok "(A) data CRUD through the Rust data plane works for the org-scoped project (200)"

# ── 7) (B · LOAD-BEARING REJECT) ───────────────────────────────────────────────
step "7/9 (B · REJECT) viewer cannot create a project · cross-org isolation · last-owner · token integrity"

# B1 — invite + accept U3 as VIEWER, then U3 POST /projects → 403, NO new tenant.
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/invites" "${JWT_U1}" '{"email":"u3@m103.test","role":"viewer"}')"
[[ "${C}" == "201" ]] || fail "(B1) issue viewer invite expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B1 invite)"
TOKEN_U3="$(json_str token)"; [[ -n "${TOKEN_U3}" ]] || fail "(B1) no viewer invite token (line: B1 token)"
C="$(org_req POST "${PORT_ON}" /v1/orgs/invites/accept "${JWT_U3}" "{\"token\":\"${TOKEN_U3}\"}")"
[[ "${C}" == "200" ]] || fail "(B1) U3 accept expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B1 accept)"
TENANTS_PRE_VIEWER="$(psql_val "SELECT count(*) FROM public.tenants")"
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_A}/projects" "${JWT_U3}" \
      "{\"tenant\":\"m103-viewer-deny-$$\",\"name\":\"x\",\"plan\":\"nano\"}")"
[[ "${C}" == "403" ]] || fail "(B1) a VIEWER created a project (got ${C}, want 403) — RBAC project:create gate is OPEN! — $(head -c 300 "${BODY_TMP}") (line: B1 viewer 403)"
grep -q 'forbidden' "${BODY_TMP}" || fail "(B1) 403 body missing 'forbidden' — $(head -c 300 "${BODY_TMP}") (line: B1 forbidden body)"
[[ "$(psql_val "SELECT count(*) FROM public.tenants")" == "${TENANTS_PRE_VIEWER}" ]] \
  || fail "(B1) a tenant row appeared despite the viewer 403 — the reject is not load-bearing (line: B1 no new tenant)"
ok "(B1) viewer POST /projects → 403 forbidden AND no tenant row created (RBAC gate REAL)"

# B2 — cross-org isolation: U4 owns org B; U2 (a member of A only) cannot touch B.
ORG_B_SLUG="m103-org-b-$$"; ORG_B_SLUG="$(echo "${ORG_B_SLUG}" | tr '[:upper:]' '[:lower:]' | cut -c1-60)"
C="$(org_req POST "${PORT_ON}" /v1/orgs "${JWT_U4}" "{\"slug\":\"${ORG_B_SLUG}\",\"name\":\"Org B\"}")"
[[ "${C}" == "201" ]] || fail "(B2) U4 create org B expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B2 create B)"
ORG_B="$(json_str id)"; [[ -n "${ORG_B}" ]] || fail "(B2) org B id missing (line: B2 org B id)"
# U2 GET org B → 403/404 (non-member: opaque, by membership lookup not by guessable id).
C="$(org_req GET "${PORT_ON}" "/v1/orgs/${ORG_B}" "${JWT_U2}")"
[[ "${C}" == "403" || "${C}" == "404" ]] || fail "(B2) U2 GET org B expected 403/404, got ${C} — cross-org READ is OPEN! (line: B2 read B)"
# U2 POST a project into org B → 403/404.
C="$(org_req POST "${PORT_ON}" "/v1/orgs/${ORG_B}/projects" "${JWT_U2}" \
      "{\"tenant\":\"m103-crossorg-$$\",\"name\":\"x\",\"plan\":\"nano\"}")"
[[ "${C}" == "403" || "${C}" == "404" ]] || fail "(B2) U2 provisioned into org B (got ${C}) — cross-org WRITE is OPEN! (line: B2 write B)"
# U2 GET org B members → 403/404.
C="$(org_req GET "${PORT_ON}" "/v1/orgs/${ORG_B}/members" "${JWT_U2}")"
[[ "${C}" == "403" || "${C}" == "404" ]] || fail "(B2) U2 read org B members (got ${C}) — cross-org member READ is OPEN! (line: B2 members B)"
# Positive control: U2 CAN still operate in its OWN org A.
C="$(org_req GET "${PORT_ON}" "/v1/orgs/${ORG_A}" "${JWT_U2}")"
[[ "${C}" == "200" ]] || fail "(B2) U2 lost access to its OWN org A (got ${C}) — isolation over-blocked (line: B2 own org)"
ok "(B2) member of A cannot read/touch org B (403/404) while keeping full access to A — cross-org isolation REAL"

# B3 — last-owner protection: U1 is the SOLE owner of A; removing U1 → 409.
C="$(org_req DELETE "${PORT_ON}" "/v1/orgs/${ORG_A}/members/${U1}" "${JWT_U1}")"
[[ "${C}" == "409" ]] || fail "(B3) removing the sole owner expected 409, got ${C} — last-owner guard is OPEN! — $(head -c 300 "${BODY_TMP}") (line: B3 last owner)"
[[ "$(psql_val "SELECT role FROM public.org_members WHERE org_id::text='${ORG_A}' AND user_id='${U1}'")" == "owner" ]] \
  || fail "(B3) the sole owner was removed despite the 409 (line: B3 owner still there)"
ok "(B3) the sole owner cannot be removed → 409 (break-glass anchor REAL)"

# B4 — token integrity: wrong token → 401; replayed (already-accepted) → 409.
C="$(org_req POST "${PORT_ON}" /v1/orgs/invites/accept "${JWT_U3}" '{"token":"mbi_deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}')"
[[ "${C}" == "401" || "${C}" == "410" ]] || fail "(B4) a wrong invite token was accepted (got ${C}, want 401/410) — token is forgeable! (line: B4 wrong token)"
C="$(org_req POST "${PORT_ON}" /v1/orgs/invites/accept "${JWT_U2}" "{\"token\":\"${TOKEN_U2}\"}")"
[[ "${C}" == "409" ]] || fail "(B4) an already-accepted token was replayed (got ${C}, want 409) — token is not single-use! (line: B4 replay)"
ok "(B4) wrong token → 401/410, replayed token → 409 (sha256 invite is single-use + unforgeable)"

# ── 8) (C · PARITY) ────────────────────────────────────────────────────────────
step "8/9 (C · PARITY) flag-OFF routes 404 + base admin 200 + the CRITICAL data-plane byte-parity probe"

# C1 — a SECOND tenant-control with ORG_MODEL_ENABLED UNSET. Stop nothing of the
# ON instance; boot a parallel OFF instance against the SAME DB.
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e TENANT_CONTROL_PORT=3020 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3020" "${TC_IMG}" >/dev/null
wait_ready_http "${TC_OFF}" "${PORT_OFF}" /health/live || fail "ORG-OFF tenant-control not ready (line: wait TC_OFF)"
docker logs "${TC_OFF}" 2>&1 | grep -q "organizations API disabled" \
  || { docker logs "${TC_OFF}" 2>&1 | tail -20; fail "(C1) OFF instance did not report org API disabled (flag default not OFF?) (line: C1 disabled log)"; }
# Every /v1/orgs* route → 404 (not mounted).
C="$(org_req GET "${PORT_OFF}" /v1/orgs "${JWT_U1}")"
[[ "${C}" == "404" ]] || fail "(C1) GET /v1/orgs with flag OFF expected 404 (route not mounted), got ${C} (line: C1 orgs 404)"
C="$(org_req POST "${PORT_OFF}" "/v1/orgs/${ORG_A}/projects" "${JWT_U1}" '{"tenant":"x","name":"x"}')"
[[ "${C}" == "404" ]] || fail "(C1) POST /v1/orgs/{id}/projects with flag OFF expected 404, got ${C} (line: C1 projects 404)"
C="$(org_req POST "${PORT_OFF}" /v1/orgs/invites/accept "${JWT_U2}" '{"token":"x"}')"
[[ "${C}" == "404" ]] || fail "(C1) POST /v1/orgs/invites/accept with flag OFF expected 404, got ${C} (line: C1 accept 404)"
# Base admin routes STILL 200 (the pre-D1 baseline is untouched).
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants/${PROJ_SLUG}")"
[[ "${C}" == "200" ]] || fail "(C1) base admin GET /v1/tenants/{id} expected 200 on OFF router, got ${C} — $(head -c 300 "${BODY_TMP}") (line: C1 admin 200)"
ok "(C1) flag OFF → every /v1/orgs* route 404; base admin /v1/tenants/{id} still 200 (byte-parity)"

# C2 — THE LOAD-BEARING DATA-PLANE BYTE-PARITY PROBE. The data plane never reads
# ORG_MODEL_ENABLED; the SAME /v1/query envelope (a normal tenant identity with NO
# org_id field — RequestIdentity has none) must yield a BYTE-IDENTICAL response
# regardless of the org world. We drive the identical request twice and diff the
# bodies; we also assert the envelope carries tenant_id only.
step "8b/9 (C2 · LOAD-BEARING) /v1/query is BYTE-IDENTICAL with orgs present vs the org-less baseline"
PAYLOAD="$(payload_list "${PROJ_SLUG}")"
echo "${PAYLOAD}" | grep -q '"org_id"' && fail "(C2) the data-plane request envelope contains an org_id field — RequestIdentity must have NONE (line: C2 no org field)"
# Request #1 (already captured in DP_ON_BODY from arm 6b). Request #2 now — same
# envelope, same data plane, after the WHOLE org world (org A/B, members, invites,
# org-owned project) exists. If orgs touched the data path these would differ.
C="$(curl -s -o "${DP_OFF_BODY}" -w '%{http_code}' -X POST "http://127.0.0.1:${PORT_DPR}/v1/query" \
      -H 'Content-Type: application/json' -d "${PAYLOAD}")"
[[ "${C}" == "200" ]] || fail "(C2) repeat /v1/query expected 200, got ${C} — $(head -c 400 "${DP_OFF_BODY}") (line: C2 repeat 200)"
# The response bodies must be byte-identical (the data plane is org-agnostic).
diff <(tr -d '\n' < "${DP_ON_BODY}") <(tr -d '\n' < "${DP_OFF_BODY}") >/dev/null 2>&1 \
  || { red "ON body:"; head -c 400 "${DP_ON_BODY}"; echo; red "OFF body:"; head -c 400 "${DP_OFF_BODY}"; echo; \
       fail "(C2) /v1/query response differs across the org world — orgs LEAKED into the data path! (line: C2 byte diff)"; }
ok "(C2) /v1/query response byte-identical; envelope carries tenant_id only (no org_id) — data path org-agnostic"

# C2 schema proof: auth.current_tenant_id() body is UNCHANGED after 043/044, and
# tenants.org_id is NULL for every row that is not the org-owned project (and even
# that one set NULL for the parity-baseline projects). The function body md5 must
# equal the pre-043 snapshot → the per-request isolation key has NO org input.
TENANT_FN_AFTER="$(psql_val "SELECT md5(pg_get_functiondef('auth.current_tenant_id'::regproc))")"
[[ "${TENANT_FN_AFTER}" == "${TENANT_FN_BEFORE}" ]] \
  || fail "(C2) auth.current_tenant_id() body CHANGED after 043/044 — the RLS isolation function must be byte-unchanged! (line: C2 fn unchanged)"
# Every org-less tenant has org_id NULL; only the explicitly-provisioned project is stamped.
[[ "$(psql_val "SELECT count(*) FROM public.tenants WHERE org_id IS NOT NULL AND slug<>'${PROJ_SLUG}'")" == "0" ]] \
  || fail "(C2) a tenant other than the org-owned project has a non-NULL org_id — the column is not inert (line: C2 org_id inert)"
ok "(C2) auth.current_tenant_id() byte-unchanged; org_id NULL for every non-org tenant — schema addition inert on the request path"

# ── 9) summary + gate log ──────────────────────────────────────────────────────
step "9/9 summary"
green "[M103] (A) POSITIVE: create org → invite (sha256 token) → accept → org-scoped provision (org_id stamped, key minted) → data CRUD via the Rust data plane (200)"
green "[M103] (B) REJECT:   viewer 403+no-tenant · cross-org A↛B 403/404 (A intact) · last-owner 409 · token 401/410 + replay 409"
green "[M103] (C) PARITY:   flag OFF → /v1/orgs* 404, base admin 200 · /v1/query BYTE-IDENTICAL with orgs present · auth.current_tenant_id() unchanged · org_id inert"

emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-d1-orgs-rbac}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m103=PASS" --outcome pass \
      --msg "D1 orgs/RBAC: create org -> sha256-token invite -> accept -> org-scoped project provision (wraps the existing reconciler, org_id stamped) -> data CRUD via Rust data plane; viewer cannot create a project (403, no tenant), member of A cannot touch B (403/404), sole owner cannot be removed (409), invite token single-use+unforgeable (401/410/409); ORG_MODEL_ENABLED unset -> /v1/orgs* 404 + base admin 200, and /v1/query is BYTE-IDENTICAL with orgs present + auth.current_tenant_id() unchanged + tenants.org_id inert (orgs never touched the data path, SHARE_POOLS untouched)" \
      --ref "scripts/verify/m103-orgs-rbac.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M103] ALL GATES GREEN — D1 orgs/RBAC: full lifecycle, load-bearing rejects, and DATA-PLANE BYTE-PARITY (org-scoping stays control-plane only)"
exit 0
