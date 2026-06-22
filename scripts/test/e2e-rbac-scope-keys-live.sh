#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    e2e-rbac-scope-keys-live.sh                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/22 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/22 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# SELF-CONTAINED LIVE cross-repo e2e — builds + brings up the whole stack from
# source and drives the full journey over real sockets, then asserts each leg:
#   grobase tenant-control (all RBAC flags ON) + vault42-server (SQLite store,
#   VAULT42_SCOPE_KEYS_ENABLED, no contract) + the 42ctl binary, 3 identities.
#
# Flow: org -> team -> env(prod,dev) -> env-init -> grant(team,writer,prod) ->
#   invite -> accept -> keys enroll -> sync-keys -> set-env(prod,dev) ->
#   member decrypts prod, is DENIED dev, unprovisioned is DENIED prod ->
#   revoke + rotate-scope -> removed member blocked on the new revision.
#
# Unlike the bring-your-own-stack e2e-rbac-scope-keys.sh, this one stands the
# stack up itself (scratch Postgres + tenant-control image + vault42-server) so
# one command reproduces the demo end-to-end. Cross-repo by nature: needs this
# grobase checkout (GROBASE_ROOT, auto from $0), the vendored vault42 build
# (the `vault42-target` docker volume — `make -C vendor/vault42 build`), and the
# 42ctl binary (CTL=, default ~/Documents/42ctl/target/release/42ctl).
set -uo pipefail

SUF=$$
NET="e2enet-${SUF}"
PG="e2e-pg-${SUF}"
TC="e2e-tc-${SUF}"
V42="e2e-v42-${SUF}"
JWT_SECRET="e2e-jwt-secret-deadbeefcafef00ddeadbeefcafef00d"
TC_PORT=19173
V42_PORT=18443
GRO="http://127.0.0.1:${TC_PORT}"
ROOT="${GROBASE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MIG="${ROOT}/scripts/migrations/postgresql"
CTL="${CTL:-${HOME}/Documents/42ctl/target/release/42ctl}"
TOOLIMG="${RUST_TOOLCHAIN_IMG:-mini-baas-rust-toolchain:latest}"
WORK="$(mktemp -d "/tmp/e2e-${SUF}.XXXX")"
PASS="pp-${SUF}"
export NO_COLOR=1

ADMIN_SUB="a0000000-0000-4000-8000-000000000001"
SERGIO_SUB="50000000-0000-4000-8000-000000000002"
VADIM_SUB="60000000-0000-4000-8000-000000000003"

c() { printf '\033[0;36m%s\033[0m\n' "$*"; }
g() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
r() { printf '\033[0;31mFAIL — %s\033[0m\n' "$*"; }
die() { r "$*"; echo "---- tenant-control logs ----"; docker logs --tail 40 "${TC}" 2>&1 | tail -40; echo "---- vault42 logs ----"; docker logs --tail 25 "${V42}" 2>&1 | tail -25; exit 1; }

cleanup() {
  docker rm -f "${PG}" "${TC}" "${V42}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" || true
}
trap cleanup EXIT

psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
psql_exec() { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

mint_jwt() { # $1=sub $2=email
  psql_val "
    WITH parts AS (
      SELECT
        translate(encode(convert_to('{\"alg\":\"HS256\",\"typ\":\"JWT\"}','utf8'),'base64'),'+/=' || chr(10) || chr(13),'-_') AS h,
        translate(encode(convert_to(
          '{\"sub\":\"$1\",\"email\":\"$2\",\"role\":\"authenticated\",\"aud\":\"authenticated\",\"exp\":' ||
          (extract(epoch from now())::bigint + 3600)::text || '}','utf8'),'base64'),'+/=' || chr(10) || chr(13),'-_') AS p),
    signed AS (
      SELECT h, p, translate(encode(hmac((h||'.'||p),'${JWT_SECRET}','sha256'),'base64'),'+/=' || chr(10) || chr(13),'-_') AS s FROM parts)
    SELECT rtrim(h,'=')||'.'||rtrim(p,'=')||'.'||rtrim(s,'=') FROM signed;"
}

setup_identity() { # $1=name $2=sub $3=email
  local d="${WORK}/$1"; mkdir -p "$d"
  cat > "$d/config.json" <<JSON
{"current":"default","profiles":{"default":{"server":"http://127.0.0.1:${V42_PORT}","authority":"${GRO}","grobase":"${GRO}"}}}
JSON
  FT_CONFIG="$d/config.json" FT_KEYSTORE="$d/keystore.v42" FT_PASSPHRASE="${PASS}" "${CTL}" keys init >/dev/null 2>&1 \
    || { echo "keys init failed for $1"; return 1; }
  mint_jwt "$2" "$3" > "$d/session.tok"
}

ctl() { # $1=name, rest=args
  local d="${WORK}/$1"; shift
  FT_CONFIG="${d}/config.json" FT_KEYSTORE="${d}/keystore.v42" FT_SESSION="${d}/session.tok" FT_PASSPHRASE="${PASS}" "${CTL}" "$@"
}
field() { sed 's/\x1b\[[0-9;]*m//g' | awk -v k="$1" '$1==k{print $2; exit}'; }

# ── 1. infra: network + scratch postgres ──────────────────────────────────────
c "[1/12] network + scratch postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD=postgres postgres:16-alpine >/dev/null
for i in $(seq 1 90); do
  docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && \
    [ "$(psql_val 'SELECT 1')" = "1" ] && break
  [ "$i" = 90 ] && die "postgres never came up"; sleep 0.5
done
g "postgres up"

# ── 2. migrations ─────────────────────────────────────────────────────────────
c "[2/12] schema prelude + migrations 005..084"
psql_exec >/dev/null 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid $fn$;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id', NULLIF(current_setting('app.current_tenant_id', true), ''), auth.current_user_id()::text)::uuid $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon')          THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role; END IF;
END $r$;
GRANT EXECUTE ON FUNCTION auth.current_user_id() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.current_tenant_id() TO anon, authenticated, service_role;
SQL
for m in 005_add_tenant_table 032_tenants 040_tenant_usage 043_orgs 044_org_billing_rollup 047_tenant_audit_log \
         072_teams 073_project_grants 077_environments 078_groups 079_project_grants_ext \
         080_invites 081_user_pubkeys 082_vault42_scope_keys 083_env_scope_pubkey 084_vault42_env_secrets; do
  f="${MIG}/${m}.sql"; [ -f "$f" ] || die "missing migration ${m}"
  sed '/^#/d' "$f" | psql_exec -f - >/dev/null 2>&1 || die "migration ${m} failed"
done
g "migrations applied ($(psql_val 'SELECT count(*) FROM schema_migrations') rows)"

# ── 3. tenant-control (RBAC flags ON) ─────────────────────────────────────────
c "[3/12] build + run tenant-control (all RBAC flags ON)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 -t "${TC}:img" "${ROOT}/src/control-plane" >/dev/null 2>&1 || die "tenant-control build failed"
docker run -d --name "${TC}" --network "${NET}" \
  -e DATABASE_URL="postgres://postgres:postgres@${PG}:5432/postgres" \
  -e INTERNAL_SERVICE_TOKEN="e2e-internal-${SUF}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e ORG_MODEL_ENABLED=1 -e RBAC_HIERARCHY_ENABLED=1 -e ENVIRONMENTS_ENABLED=1 \
  -e GROUPS_ENABLED=1 -e INVITES_ENABLED=1 -e USER_PUBKEYS_ENABLED=1 -e EMAIL_OTP_ENABLED=1 \
  -e ADAPTER_REGISTRY_URL="" -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled -e LOG_LEVEL=debug \
  -p "127.0.0.1:${TC_PORT}:3020" "${TC}:img" >/dev/null
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${GRO}/v1/orgs" 2>/dev/null || echo 000)
  [ "${code}" != "000" ] && break
  [ "$i" = 60 ] && die "tenant-control never answered"; sleep 0.5
done
g "tenant-control up at ${GRO}"

# ── 4. vault42-server (SQLite, scope flag, no contract) ───────────────────────
c "[4/12] run vault42-server (SQLite store, VAULT42_SCOPE_KEYS_ENABLED, no contract)"
docker run -d --name "${V42}" --network "${NET}" \
  -v vault42-target:/vt:ro -e VAULT42_STORE=sqlite -e VAULT42_DB=/tmp/v42.db \
  -e VAULT42_HOST=0.0.0.0 -e VAULT42_PORT=8443 -e VAULT42_SCOPE_KEYS_ENABLED=1 \
  -p "127.0.0.1:${V42_PORT}:8443" "${TOOLIMG}" /vt/release/vault42-server >/dev/null
sleep 2
docker ps --filter "name=${V42}" --format '{{.Status}}' | grep -qi up || die "vault42-server not running"
g "vault42-server up on :${V42_PORT}"

# ── 5. three identities (admin, sergio, vadim) ────────────────────────────────
c "[5/12] create 3 identities + minted session JWTs"
setup_identity admin  "${ADMIN_SUB}"  admin@example.com  || die "admin identity"
setup_identity sergio "${SERGIO_SUB}" sergio@example.com || die "sergio identity"
setup_identity vadim  "${VADIM_SUB}"  vadim@example.com  || die "vadim identity"
g "admin/sergio/vadim ready"

# ── 6. org + project + envs ───────────────────────────────────────────────────
c "[6/12] admin: create org + seed project + envs prod/dev"
ORG="$(ctl admin org create --slug univers42 --name Univers42 2>/dev/null | field id)"
[ -n "${ORG}" ] || die "org create returned no id"
PROJ="$(psql_val 'SELECT gen_random_uuid()')"
psql_exec >/dev/null 2>&1 <<SQL || die "seed project"
INSERT INTO public.tenants (id, name, slug, owner_user_id, org_id)
VALUES ('${PROJ}', 'app', 'app-${SUF}', '${ADMIN_SUB}', '${ORG}');
SQL
ctl admin env create --project "${PROJ}" --name prod >/dev/null 2>&1 || die "env create prod"
ctl admin env create --project "${PROJ}" --name dev  >/dev/null 2>&1 || die "env create dev"
PROD_ENV="$(curl -fsS "${GRO}/v1/projects/${PROJ}/environments" -H "Authorization: Bearer $(cat "${WORK}/admin/session.tok")" | jq -r '.[]|select(.name=="prod")|.id')"
DEV_ENV="$(curl -fsS "${GRO}/v1/projects/${PROJ}/environments" -H "Authorization: Bearer $(cat "${WORK}/admin/session.tok")" | jq -r '.[]|select(.name=="dev")|.id')"
[ -n "${PROD_ENV}" ] && [ -n "${DEV_ENV}" ] || die "env ids not found (prod='${PROD_ENV}' dev='${DEV_ENV}')"
g "org=${ORG} proj=${PROJ} prod_env=${PROD_ENV} dev_env=${DEV_ENV}"

# ── 7. bootstrap scope keys for prod + dev ────────────────────────────────────
c "[7/12] admin: env-init prod + dev (scope keypairs)"
ctl admin vault env-init --org "${ORG}" --project "${PROJ}" --env prod 2>&1 | sed 's/^/    /' || die "env-init prod"
ctl admin vault env-init --org "${ORG}" --project "${PROJ}" --env dev  2>&1 | sed 's/^/    /' || die "env-init dev"
g "prod + dev scope keys bootstrapped"

# ── 8. team + grant (writer on prod only) ─────────────────────────────────────
c "[8/12] admin: team core + grant team writer on PROD only"
TEAM="$(ctl admin team create --org "${ORG}" --slug core --name Core 2>/dev/null | field id)"
[ -n "${TEAM}" ] || die "team create returned no id"
ctl admin team grant-project --org "${ORG}" --team "${TEAM}" --project "${PROJ}" --env "${PROD_ENV}" --role writer 2>&1 | sed 's/^/    /' || die "grant-project prod"
g "team=${TEAM} granted writer on prod"

# ── 9. admin seals prod + dev secrets ─────────────────────────────────────────
c "[9/12] admin: seal a prod secret + a dev secret"
printf 'postgres://prod-db' | ctl admin vault set-env --org "${ORG}" --project "${PROJ}" --env prod DATABASE_URL 2>&1 | sed 's/^/    /' || die "set-env prod"
printf 'postgres://dev-db'  | ctl admin vault set-env --org "${ORG}" --project "${PROJ}" --env dev  DATABASE_URL 2>&1 | sed 's/^/    /' || die "set-env dev"
g "prod + dev secrets sealed to their scope keys"

# ── 10. invite sergio -> accept -> enroll -> sync-keys ────────────────────────
c "[10/12] sergio joins team (invite+accept), enrolls pubkey; admin sync-keys"
TOK="$(ctl admin team invite --org "${ORG}" --team "${TEAM}" --email sergio@example.com 2>/dev/null | field token)"
if [ -n "${TOK}" ]; then
  ctl sergio invite accept --token "${TOK}" 2>&1 | sed 's/^/    accept: /' || die "sergio invite accept"
else
  ctl admin team add-member --org "${ORG}" --team "${TEAM}" --user "${SERGIO_SUB}" 2>&1 | sed 's/^/    add: /' || die "team add-member fallback"
fi
ctl sergio keys enroll --org "${ORG}" 2>&1 | sed 's/^/    enroll: /' || die "sergio keys enroll"
ctl admin vault sync-keys --org "${ORG}" --project "${PROJ}" --env prod 2>&1 | sed 's/^/    sync: /' || die "sync-keys prod"
ctl admin vault scope-status --org "${ORG}" --project "${PROJ}" --env prod 2>&1 | sed 's/^/    status: /' || true
g "sergio joined + enrolled; prod scope key wrapped to sergio"

# ── 11. the assertions ────────────────────────────────────────────────────────
c "[11/12] ASSERTIONS"
GOT="$(ctl sergio vault get-env --org "${ORG}" --project "${PROJ}" --env prod DATABASE_URL 2>"${WORK}/sergio.err" || true)"
if [ "${GOT}" != "postgres://prod-db" ]; then
  echo "  --- sergio get-env stderr ---"; sed 's/^/    /' "${WORK}/sergio.err"
  echo "  --- admin get-env prod (control) ---"; ctl admin vault get-env --org "${ORG}" --project "${PROJ}" --env prod DATABASE_URL 2>&1 | sed 's/^/    /'
  die "sergio could NOT read prod secret (got '${GOT}')"
fi
g "sergio decrypts prod/DATABASE_URL = '${GOT}'  (per-env grant + provisioning works)"

if ctl sergio vault get-env --org "${ORG}" --project "${PROJ}" --env dev DATABASE_URL >/dev/null 2>&1; then
  die "PER-ENV ISOLATION BROKEN — sergio (prod-only) read a dev secret"
fi
g "sergio DENIED dev secret  (per-environment isolation holds)"

if ctl vadim vault get-env --org "${ORG}" --project "${PROJ}" --env prod DATABASE_URL >/dev/null 2>&1; then
  die "DENY-BY-DEFAULT BROKEN — unprovisioned vadim read prod"
fi
g "vadim DENIED prod  (deny-by-default + provisioning gate hold)"

# ── 12. revoke + rotate -> removed member blocked on new revision ─────────────
c "[12/12] revoke sergio + rotate-scope prod, then sergio blocked on the new revision"
docker exec -i "${PG}" psql -U postgres -d postgres -c "DELETE FROM public.team_members WHERE user_id='${SERGIO_SUB}';" >/dev/null 2>&1 || true
ctl admin vault rotate-scope --org "${ORG}" --project "${PROJ}" --env prod 2>&1 | sed 's/^/    rotate: /' || die "rotate-scope"
printf 'postgres://prod-db-ROTATED' | ctl admin vault set-env --org "${ORG}" --project "${PROJ}" --env prod DATABASE_URL 2>&1 | sed 's/^/    reset: /' || die "set-env post-rotate"
NEW="$(ctl sergio vault get-env --org "${ORG}" --project "${PROJ}" --env prod DATABASE_URL 2>/dev/null || true)"
if printf '%s' "${NEW}" | grep -q ROTATED; then
  die "FORWARD SECRECY BROKEN — removed sergio read the post-rotation revision ('${NEW}')"
fi
g "after revoke+rotate, removed sergio cannot read the new prod revision  (forward-secure)"

printf '\033[0;32m\n[E2E] ALL GREEN — live cross-repo org/team + per-environment + zero-knowledge scope-key flow:\033[0m\n'
printf '\033[0;32m[E2E]   invite -> accept -> enroll -> grant -> sync-keys -> member decrypts prod, NOT dev;\033[0m\n'
printf '\033[0;32m[E2E]   unprovisioned denied; revoke + rotate-scope = forward-secure.\033[0m\n'
