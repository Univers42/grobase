#!/usr/bin/env bash
# ============================================================
# m177 — strict self-serve app creation (APPS_SELFSERVE_ENABLED)
#
# A logged-in account POSTs a name to /v1/tenants/me/apps and gets back a NEW
# app-tenant on its OWN fresh physical database (CREATE DATABASE) + a scoped
# read/write key. Each app is a distinct tenant, so the key→mount gate
# (WHERE id=$1 AND tenant_id=$2) means a foreign app's key can never resolve it:
# distinct-database-per-app is the strongest provisionable isolation.
#
# STATIC (always): flag-gated mount (OFF=404 parity), EnsureDatabase fresh-DB
# primitive + injection-safe identifier, routes registered, slug/DSN unit tests.
# LIVE (BAAS_VERIFY_LIVE=1, KONG_URL, DEV_JWT = a logged-in account's GoTrue JWT,
# ANON_KEY): create two apps → two new pg_database rows → each key reads its own
# db_id (200) → app A's key on app B's db_id is 4xx. M177_EXPECT_OFF=1 instead
# asserts the flag-OFF tenant-control answers the create with 404.
# PG_CONTAINER (default mini-baas-postgres) is read for the pg_database count.
# M177_SKIP_STATIC=1 skips the go test when another job already ran it.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CP="${ROOT}/src/control-plane"
GO_IMG="${GO_IMG:-golang:1.26-bookworm}"
PASS=0
ok() {
  printf '  \033[1;32m✓\033[0m %s\n' "$*"
  PASS=$((PASS + 1))
}
fail() {
  printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2
  exit 1
}

printf '\033[1m── m177: self-serve fresh-DB apps ──\033[0m\n'

# ── static: flag-gated mount = OFF parity ────────────────────────────────────
MNT="${CP}/cmd/tenant-control/mount_appsselfserve.go"
[ -f "${MNT}" ] || fail "mount_appsselfserve.go missing"
grep -q 'config.EnvBool("APPS_SELFSERVE_ENABLED")' "${MNT}" ||
  fail "self-serve app routes are not gated on APPS_SELFSERVE_ENABLED"
ok "mount gated on APPS_SELFSERVE_ENABLED (OFF ⇒ no routes = byte-parity)"

# ── static: the fresh-DB primitive + injection safety ────────────────────────
ENS="${CP}/internal/pg/ensure_database.go"
[ -f "${ENS}" ] || fail "pg/ensure_database.go missing"
grep -q 'pg_database WHERE datname=\$1' "${ENS}" || fail "EnsureDatabase missing the existence guard"
grep -q 'CREATE DATABASE' "${ENS}" || fail "EnsureDatabase missing CREATE DATABASE"
grep -q 'validIdentifier' "${ENS}" || fail "EnsureDatabase must validate the identifier (injection guard)"
ok "EnsureDatabase: existence-checked CREATE DATABASE on a sanitised identifier"

# ── static: routes registered ────────────────────────────────────────────────
APPS="${CP}/internal/tenants/selfserve_apps.go"
grep -q 'POST /v1/tenants/me/apps' "${APPS}" || fail "missing POST /v1/tenants/me/apps"
grep -q 'GET /v1/tenants/me/apps' "${APPS}" || fail "missing GET /v1/tenants/me/apps"
grep -q 'DELETE /v1/tenants/me/apps/{appId}' "${APPS}" || fail "missing DELETE route"
ok "routes registered (create / list / delete apps)"
grep -q 'APPS_SELFSERVE_ENABLED=1' "${ROOT}/deploy/fly/boot.sh" ||
  fail "boot.sh must enable APPS_SELFSERVE_ENABLED in the managed-cloud edition"
ok "managed-cloud edition enables APPS_SELFSERVE_ENABLED"

# ── static: slug/DSN derivation unit tests ───────────────────────────────────
if [ "${M177_SKIP_STATIC:-0}" = "1" ]; then
  printf '  \033[1;33m• M177_SKIP_STATIC=1 — go test left to the static job\033[0m\n'
elif command -v docker >/dev/null 2>&1; then
  docker run --rm -v "${CP}":/src -w /src \
    -v mini-baas-gocache:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build \
    "${GO_IMG}" bash -c 'go test ./internal/tenants/... -run "AppIdentity|AppDSN"' \
    >/dev/null 2>&1 || fail "self-serve slug/DSN unit tests failed"
  ok "slug/DSN unit tests pass (canonical slug, injection-safe db name, per-account uniqueness)"
else
  printf '  \033[1;33m• docker absent — skipped go test (run on a Docker host)\033[0m\n'
fi

# ── live: account → two isolated-DB apps → cross-app denial (requires stack) ──
create_app() { # NAME → the JSON reply, or fail
  curl -fsS -X POST "${KONG_URL}/v1/tenants/me/apps" \
    -H "Authorization: Bearer ${DEV_JWT}" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$1\"}" || fail "create app $1 failed"
}
field() { jq -r ".$2 // empty" <<<"$1"; }
tables() { # KEY DB_ID → HTTP status of listing DB_ID's tables with KEY
  curl -s -o /dev/null -w '%{http_code}' "${KONG_URL}/query/v1/$2/tables" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: $1"
}

if [ "${BAAS_VERIFY_LIVE:-0}" = "1" ]; then
  command -v curl >/dev/null 2>&1 || fail "curl required for live mode"
  command -v jq >/dev/null 2>&1 || fail "jq required for live mode"
  : "${KONG_URL:?set KONG_URL=https://grobase-stack.fly.dev for live mode}"
  : "${DEV_JWT:?set DEV_JWT to a logged-in account JWT for live mode}"
  if [ "${M177_EXPECT_OFF:-0}" = "1" ]; then
    off=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${KONG_URL}/v1/tenants/me/apps" \
      -H "Authorization: Bearer ${DEV_JWT}" -H 'Content-Type: application/json' -d '{"name":"gamma"}')
    [ "${off}" = "404" ] || fail "flag OFF: create expected 404, got ${off}"
    ok "live: APPS_SELFSERVE_ENABLED off ⇒ POST /v1/tenants/me/apps → 404 (byte-parity)"
  else
    : "${ANON_KEY:?set ANON_KEY (the public apikey) for live mode}"
    PG_CTN="${PG_CONTAINER:-mini-baas-postgres}"
    app_a=$(create_app alpha)
    app_b=$(create_app beta)
    key_a=$(field "${app_a}" api_key) db_a=$(field "${app_a}" db_id) tenant_a=$(field "${app_a}" tenant)
    key_b=$(field "${app_b}" api_key) db_b=$(field "${app_b}" db_id) tenant_b=$(field "${app_b}" tenant)
    for v in key_a db_a tenant_a key_b db_b tenant_b; do
      [ -n "${!v}" ] || fail "an app reply lacks ${v#*_} (${v})"
    done
    [ "${db_a}" != "${db_b}" ] || fail "both apps got the same db_id"
    ok "live: two apps created, each with its own key and db_id"
    names="'${tenant_a//-/_}','${tenant_b//-/_}'"
    pg_user=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${PG_CTN}" | sed -n 's/^POSTGRES_USER=//p')
    dbs=$(docker exec "${PG_CTN}" psql -U "${pg_user:-postgres}" -d postgres -tAc \
      "SELECT count(*) FROM pg_database WHERE datname IN (${names})") || fail "pg_database query failed"
    [ "${dbs}" = "2" ] || fail "expected 2 new pg_database rows, found ${dbs}"
    ok "live: two new physical databases (pg_database)"
    own=$(tables "${key_a}" "${db_a}")
    [ "${own}" = "200" ] || fail "app alpha's key on its own db_id expected 200, got ${own}"
    own=$(tables "${key_b}" "${db_b}")
    [ "${own}" = "200" ] || fail "app beta's key on its own db_id expected 200, got ${own}"
    ok "live: each app's key reads its own db_id (200)"
    cross=$(tables "${key_a}" "${db_b}")
    [ "${cross}" = "404" ] || fail "app alpha's key on beta's db_id expected 404, got ${cross}"
    ok "live: app alpha's key on beta's db_id → 404 (cross-app isolation holds)"
  fi
fi

printf '\033[1;32mm177 PASS\033[0m — %d static checks; self-serve fresh-DB apps verified (flag default OFF)\n' "${PASS}"
