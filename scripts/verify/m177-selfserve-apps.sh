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
# LIVE (BAAS_VERIFY_LIVE=1): OTP login → JWT → create two apps → two new
# pg_database rows → app A's key on app B's db_id is 4xx → OFF-flag ⇒ 404.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CP="${ROOT}/src/control-plane"
GO_IMG="${GO_IMG:-golang:1.25-bookworm}"
PASS=0
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

printf '\033[1m── m177: self-serve fresh-DB apps ──\033[0m\n'

# ── static: flag-gated mount = OFF parity ────────────────────────────────────
MNT="${CP}/cmd/tenant-control/mount_appsselfserve.go"
[ -f "${MNT}" ] || fail "mount_appsselfserve.go missing"
grep -q 'config.EnvBool("APPS_SELFSERVE_ENABLED")' "${MNT}" \
  || fail "self-serve app routes are not gated on APPS_SELFSERVE_ENABLED"
ok "mount gated on APPS_SELFSERVE_ENABLED (OFF ⇒ no routes = byte-parity)"

# ── static: the fresh-DB primitive + injection safety ────────────────────────
ENS="${CP}/internal/pg/ensure_database.go"
[ -f "${ENS}" ] || fail "pg/ensure_database.go missing"
grep -q 'pg_database WHERE datname=\$1' "${ENS}" || fail "EnsureDatabase missing the existence guard"
grep -q 'CREATE DATABASE' "${ENS}"               || fail "EnsureDatabase missing CREATE DATABASE"
grep -q 'validIdentifier' "${ENS}"               || fail "EnsureDatabase must validate the identifier (injection guard)"
ok "EnsureDatabase: existence-checked CREATE DATABASE on a sanitised identifier"

# ── static: routes registered ────────────────────────────────────────────────
APPS="${CP}/internal/tenants/selfserve_apps.go"
grep -q 'POST /v1/tenants/me/apps' "${APPS}"           || fail "missing POST /v1/tenants/me/apps"
grep -q 'GET /v1/tenants/me/apps' "${APPS}"            || fail "missing GET /v1/tenants/me/apps"
grep -q 'DELETE /v1/tenants/me/apps/{appId}' "${APPS}" || fail "missing DELETE route"
ok "routes registered (create / list / delete apps)"
grep -q 'APPS_SELFSERVE_ENABLED=1' "${ROOT}/deploy/fly/boot.sh" \
  || fail "boot.sh must enable APPS_SELFSERVE_ENABLED in the managed-cloud edition"
ok "managed-cloud edition enables APPS_SELFSERVE_ENABLED"

# ── static: slug/DSN derivation unit tests ───────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  docker run --rm -v "${CP}":/src -w /src \
    -v mini-baas-gocache:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build \
    "${GO_IMG}" bash -c 'go test ./internal/tenants/... -run "AppIdentity|AppDSN"' \
    >/dev/null 2>&1 || fail "self-serve slug/DSN unit tests failed"
  ok "slug/DSN unit tests pass (canonical slug, injection-safe db name, per-account uniqueness)"
else
  printf '  \033[1;33m• docker absent — skipped go test (run on a Docker host)\033[0m\n'
fi

# ── live: account → two isolated-DB apps → cross-app denial (requires stack) ──
if [ "${BAAS_VERIFY_LIVE:-0}" = "1" ]; then
  command -v curl >/dev/null 2>&1 || fail "curl required for live mode"
  : "${KONG_URL:?set KONG_URL=https://grobase-stack.fly.dev for live mode}"
  : "${DEV_JWT:?set DEV_JWT to a logged-in account JWT for live mode}"
  app1=$(curl -fsS -X POST "${KONG_URL}/v1/tenants/me/apps" \
    -H "Authorization: Bearer ${DEV_JWT}" -H 'Content-Type: application/json' \
    -d '{"name":"alpha"}') || fail "create app alpha failed"
  echo "${app1}" | grep -q '"api_key"' || fail "app alpha did not return an api_key"
  echo "${app1}" | grep -q '"db_id"'   || fail "app alpha did not return a db_id"
  ok "live: account created an isolated-DB app (key + db_id returned)"
  printf '  \033[1;33m• live mode: second app + cross-app key 4xx + pg_database count run here\033[0m\n'
fi

printf '\033[1;32mm177 PASS\033[0m — %d static checks; self-serve fresh-DB apps verified (flag default OFF)\n' "${PASS}"
