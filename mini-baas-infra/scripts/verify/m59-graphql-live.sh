#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m59-graphql-live.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M59 — GraphQL live gate (A5). Proves GraphQL is GENUINELY live against the
# Debian-glibc pg_graphql Postgres edition, end-to-end over HTTP through
# PostgREST — the same path Kong's /graphql/v1 → /rpc/graphql route serves.
#
# ISOLATED by design: a throwaway postgres-graphql + postgrest on a private
# network with an EPHEMERAL volume, so it never touches the main stack's data
# (the musl→glibc cluster swap would risk collation drift). Mirrors how the
# m40-m45 "one" gates run a standalone binary.
#
#   1. extension+wrapper  apply the REAL 035_pg_graphql.sql on the graphql image:
#                         CREATE EXTENSION pg_graphql + graphql_public.graphql()
#                         (the /rpc/graphql RPC PostgREST exposes).
#   2. in-db resolve      graphql_public.graphql(query := '{ … }') returns the
#                         table's rows (proves the extension + wrapper).
#   3. HTTP over PostgREST POST /rpc/graphql returns {data:{…Collection…}} — the
#                         real serving path (anon role + RLS).
#   4. error envelope     a bad query returns a GraphQL `errors` array (200), not
#                         a transport 500 (GraphQL-over-HTTP contract).
#   5. RLS isolation      two tenants + anon over an RLS table: each tenant reads
#                         ONLY its rows, anon reads none — proves the INVOKER
#                         wrapper makes GraphQL inherit RLS (the review found the
#                         old gate proved liveness on a non-RLS table, so it could
#                         not tell an isolated endpoint from a wide-open one).
#   6. route config       kong.yml maps /graphql/v1 → postgrest /rpc/graphql.
#
# Requires the graphql image built: docker build -t mini-baas-postgres-graphql:16
#   docker/services/postgres-graphql   (or `make build-svc-postgres` w/ overlay).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M59] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M59] FAIL — $*"; exit 1; }

IMAGE="${GRAPHQL_PG_IMAGE:-mini-baas-postgres-graphql:16}"
PGREST_IMAGE="postgrest/postgrest:v12.2.3"
NET="m59net-$$"
PG="m59-pg-$$"
PR="m59-postgrest-$$"
PORT="${M59_PORT:-18959}"
PGPW="postgres"
AUTHPW="authpw-m59"
# HS256 secret PostgREST validates JWTs with (≥32 bytes); used by the RLS
# isolation step to mint per-tenant `authenticated` tokens.
JWT_SECRET="m59-rls-isolation-secret-0123456789abcdef"

# Mint an HS256 JWT carrying role=authenticated + tenant_id (the RLS claim).
mint_jwt() { # tenant_id
  python3 - "${JWT_SECRET}" "$1" <<'PY'
import sys, hmac, hashlib, base64, json, time
secret, tid = sys.argv[1], sys.argv[2]
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=')
hdr = b64(json.dumps({"alg":"HS256","typ":"JWT"}, separators=(',',':')).encode())
pl  = b64(json.dumps({"role":"authenticated","tenant_id":tid,
                      "exp":int(time.time())+3600}, separators=(',',':')).encode())
sig = b64(hmac.new(secret.encode(), hdr+b'.'+pl, hashlib.sha256).digest())
print((hdr+b'.'+pl+b'.'+sig).decode())
PY
}

cleanup() {
  docker rm -fv "${PR}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql_pg() { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

# ── 0) bring up the isolated graphql postgres ────────────────────────────────
step "0/6 boot isolated postgres-graphql (${IMAGE})"
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || fail "image '${IMAGE}' not built — docker build -t ${IMAGE} docker/services/postgres-graphql"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" \
  -e POSTGRES_PASSWORD="${PGPW}" "${IMAGE}" \
  postgres -c wal_level=logical >/dev/null
for i in $(seq 1 40); do
  docker exec "${PG}" pg_isready -U postgres -d postgres >/dev/null 2>&1 && break
  [[ $i -eq 40 ]] && fail "postgres-graphql never became ready"
  sleep 0.5
done
# pg_graphql ships only in this image — confirm it is actually available.
AVAIL="$(psql_pg -tAc "SELECT count(*) FROM pg_available_extensions WHERE name='pg_graphql'")"
[[ "${AVAIL}" == "1" ]] || fail "pg_graphql NOT available in ${IMAGE} (the build did not bundle it)"
ok "postgres-graphql up; pg_graphql available in the image"

# ── 1) PostgREST roles + a reflected table + the REAL 035 migration ──────────
step "1/6 roles + table + apply 035_pg_graphql.sql (extension + graphql_public wrapper)"
psql_pg >/dev/null <<'SQL'
-- PostgREST role triad + authenticator login role
DO $$ BEGIN
  CREATE ROLE anon NOLOGIN;            EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE authenticated NOLOGIN;   EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE service_role NOLOGIN BYPASSRLS; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE ROLE authenticator LOGIN PASSWORD 'authpw-m59' NOINHERIT;
  EXCEPTION WHEN duplicate_object THEN NULL; END $$;
GRANT anon, authenticated, service_role TO authenticator;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

-- a reflected table with a PK (pg_graphql needs a PK to expose a Collection)
CREATE TABLE IF NOT EXISTS public.todos (id serial PRIMARY KEY, title text NOT NULL);
INSERT INTO public.todos (title) VALUES ('buy milk'), ('write gate') ON CONFLICT DO NOTHING;
GRANT SELECT ON public.todos TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON SEQUENCE public.todos_id_seq TO anon, authenticated, service_role;

-- an RLS-protected, two-tenant table to prove GraphQL HONORS isolation (the
-- review found the old gate proved liveness on a non-RLS table — it could not
-- tell an isolated endpoint from a wide-open one). Policy scopes by the JWT
-- tenant_id claim PostgREST sets into request.jwt.claims. (No underscores in
-- the table/column names: pg_graphql does not inflect snake_case → camelCase by
-- default, so `isorows`/`tenant` map 1:1 to the GraphQL field names.)
CREATE TABLE IF NOT EXISTS public.isorows (
  id serial PRIMARY KEY, tenant text NOT NULL, secret text NOT NULL);
INSERT INTO public.isorows (tenant, secret)
  VALUES ('tenantA','A-only-secret'), ('tenantB','B-only-secret') ON CONFLICT DO NOTHING;
GRANT SELECT ON public.isorows TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON SEQUENCE public.isorows_id_seq TO anon, authenticated, service_role;
ALTER TABLE public.isorows ENABLE ROW LEVEL SECURITY;
CREATE POLICY isorows_tenant ON public.isorows FOR SELECT TO anon, authenticated
  USING (tenant = NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id');
SQL
# Apply the REAL migration file (strip the 42-header), proving it works on-image.
sed '/^#/d' "${BAAS_DIR}/scripts/migrations/postgresql/035_pg_graphql.sql" | psql_pg >/dev/null
# Verify extension + wrapper now exist.
HASEXT="$(psql_pg -tAc "SELECT count(*) FROM pg_extension WHERE extname='pg_graphql'")"
HASFN="$(psql_pg -tAc "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='graphql_public' AND p.proname='graphql'")"
[[ "${HASEXT}" == "1" ]] || fail "035 did not create the pg_graphql extension"
[[ "${HASFN}" == "1" ]] || fail "035 did not create graphql_public.graphql wrapper"
ok "extension installed; graphql_public.graphql() wrapper created"

# ── 2) in-database resolve via the wrapper ───────────────────────────────────
step "2/6 graphql_public.graphql(query := …) resolves table rows (in-db)"
GQLQ='{ todosCollection { edges { node { id title } } } }'
INDB="$(psql_pg -tAc "SELECT graphql_public.graphql(query := '${GQLQ}')::text")"
grep -q 'buy milk' <<<"${INDB}" || fail "in-db resolve missing data: ${INDB}"
grep -q 'todosCollection' <<<"${INDB}" || fail "in-db resolve missing collection: ${INDB}"
ok "pg_graphql resolves a real query to data through the wrapper"

# ── 3) HTTP through PostgREST /rpc/graphql ───────────────────────────────────
step "3/6 GraphQL over HTTP (PostgREST /rpc/graphql, anon role)"
docker run -d --name "${PR}" --network "${NET}" \
  -e PGRST_DB_URI="postgres://authenticator:${AUTHPW}@${PG}:5432/postgres" \
  -e PGRST_DB_SCHEMAS="public,graphql_public" \
  -e PGRST_DB_ANON_ROLE="anon" \
  -e PGRST_JWT_SECRET="${JWT_SECRET}" \
  -p "127.0.0.1:${PORT}:3000" "${PGREST_IMAGE}" >/dev/null
for i in $(seq 1 40); do
  curl -sf "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
  [[ $i -eq 40 ]] && fail "postgrest never became ready: $(docker logs ${PR} 2>&1 | tail -5)"
  sleep 0.5
done
BODY="$(python3 -c 'import json,sys;print(json.dumps({"query":sys.argv[1]}))' "${GQLQ}")"
# graphql_public is NOT PostgREST's default (first) schema, so /rpc resolution
# needs Content-Profile to pick it (Kong injects this on the real /graphql/v1).
HTTP="$(curl -s -o /tmp/m59.json -w '%{http_code}' -X POST "http://127.0.0.1:${PORT}/rpc/graphql" \
        -H 'Content-Type: application/json' -H 'Content-Profile: graphql_public' -d "${BODY}")"
[[ "${HTTP}" == "200" ]] || fail "POST /rpc/graphql expected 200, got ${HTTP} — $(head -c 300 /tmp/m59.json)"
grep -q 'buy milk' /tmp/m59.json || fail "HTTP GraphQL response missing data — $(head -c 300 /tmp/m59.json)"
grep -q '"data"' /tmp/m59.json || fail "HTTP GraphQL response has no data envelope — $(head -c 300 /tmp/m59.json)"
ok "POST /rpc/graphql → {data:{todosCollection:…}} over HTTP via PostgREST"

# ── 4) GraphQL error envelope (200 + errors, not a transport 500) ────────────
step "4/6 a bad query returns a GraphQL errors array (200)"
BADBODY="$(python3 -c 'import json;print(json.dumps({"query":"{ no_such_field }"}))')"
HTTP="$(curl -s -o /tmp/m59.json -w '%{http_code}' -X POST "http://127.0.0.1:${PORT}/rpc/graphql" \
        -H 'Content-Type: application/json' -H 'Content-Profile: graphql_public' -d "${BADBODY}")"
[[ "${HTTP}" == "200" ]] || fail "bad query should be 200 per GraphQL-over-HTTP, got ${HTTP}"
grep -q '"errors"' /tmp/m59.json || fail "bad query did not return a GraphQL errors array — $(head -c 300 /tmp/m59.json)"
ok "GraphQL-level error returned as 200 + errors[] (not a transport 500)"

# ── 5) RLS tenant isolation over GraphQL (the real isolation proof) ──────────
step "5/6 GraphQL HONORS RLS: two tenants + anon, negative assertions"
ISOQ='{ isorowsCollection { edges { node { id tenant secret } } } }'
ISOBODY="$(python3 -c 'import json,sys;print(json.dumps({"query":sys.argv[1]}))' "${ISOQ}")"
iso_call() { # bearer(optional) -> writes /tmp/m59.json
  if [[ -n "$1" ]]; then
    curl -s -o /tmp/m59.json -X POST "http://127.0.0.1:${PORT}/rpc/graphql" \
      -H 'Content-Type: application/json' -H 'Content-Profile: graphql_public' \
      -H "Authorization: Bearer $1" -d "${ISOBODY}" >/dev/null
  else
    curl -s -o /tmp/m59.json -X POST "http://127.0.0.1:${PORT}/rpc/graphql" \
      -H 'Content-Type: application/json' -H 'Content-Profile: graphql_public' \
      -d "${ISOBODY}" >/dev/null
  fi
}
# tenant A sees ONLY A's row
iso_call "$(mint_jwt tenantA)"
grep -q 'A-only-secret' /tmp/m59.json || fail "tenant A could not read its own row — $(head -c 300 /tmp/m59.json)"
grep -q 'B-only-secret' /tmp/m59.json && fail "RLS BREACH: tenant A read tenant B's row via GraphQL — $(head -c 300 /tmp/m59.json)"
# tenant B sees ONLY B's row
iso_call "$(mint_jwt tenantB)"
grep -q 'B-only-secret' /tmp/m59.json || fail "tenant B could not read its own row — $(head -c 300 /tmp/m59.json)"
grep -q 'A-only-secret' /tmp/m59.json && fail "RLS BREACH: tenant B read tenant A's row via GraphQL — $(head -c 300 /tmp/m59.json)"
# anon (no JWT) sees NEITHER — the opposite of the outbox_events leak the review found
iso_call ""
grep -q 'only-secret' /tmp/m59.json && fail "RLS BREACH: anon read RLS-protected rows via GraphQL — $(head -c 300 /tmp/m59.json)"
ok "each tenant sees only its rows; anon sees none — GraphQL inherits RLS under the caller's role"

# ── 6) Kong route config maps /graphql/v1 → /rpc/graphql ─────────────────────
step "6/6 Kong route /graphql/v1 → postgrest /rpc/graphql"
KCONF="${BAAS_DIR}/docker/services/kong/conf/kong.yml"
grep -q 'rpc/graphql' "${KCONF}" || fail "kong.yml graphql route does not target /rpc/graphql"
awk '/- name: graphql$/{f=1} f&&/paths:.*graphql\/v1/{print; found=1} END{exit !found}' "${KCONF}" >/dev/null \
  || fail "kong.yml has no /graphql/v1 route"
ok "kong.yml: /graphql/v1 → http://postgrest:3000/rpc/graphql"

green "[M59] ALL GATES GREEN — GraphQL live + RLS-honest: pg_graphql image + graphql_public INVOKER wrapper + PostgREST /rpc/graphql over HTTP, two-tenant isolation proven"
