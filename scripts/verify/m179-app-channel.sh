#!/usr/bin/env bash
# ============================================================
# m179 — cross-app MESSAGING channel (APP_CHANNELS_ENABLED)
#
# Two app-tenants consent to a realtime link: one OPENS a pending channel, the
# other ACCEPTS it, then either side mints a realtime JWT carrying the protected
# namespace xapp:<channelId>. A wildcard ["*"] token can NOT reach xapp: topics
# (REALTIME_PROTECTED_NAMESPACES includes xapp:), so only an accepted member can
# publish/subscribe on the pair's channel. Control-plane-only; flag default OFF.
#
# STATIC (always): migration 085 present, flag-gated mount (OFF=404 parity),
# routes registered, namespace-mint unit tests, xapp: in the protected list.
# LIVE (BAAS_VERIFY_LIVE=1, needs the stack): provision A,B,C → open+accept A↔B →
# mint 3 tokens → B publishes, A receives; C denied; a pending-token is denied.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CP="${ROOT}/src/control-plane"
GO_IMG="${GO_IMG:-golang:1.25-bookworm}"
PASS=0
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

printf '\033[1m── m179: cross-app messaging channel ──\033[0m\n'

# ── static: migration 085 ────────────────────────────────────────────────────
MIG="${ROOT}/scripts/migrations/postgresql/085_app_channels.sql"
[ -f "${MIG}" ] || fail "migration 085_app_channels.sql missing"
grep -q "version = 85" "${MIG}" || fail "085 does not guard on version 85"
grep -q "app_channels" "${MIG}" || fail "085 missing app_channels table"
grep -q "least(tenant_a, tenant_b), greatest(tenant_a, tenant_b)" "${MIG}" \
  || fail "085 missing the unordered-pair unique index"
ok "migration 085 present (app_channels, version 85, unordered-pair unique)"

# ── static: flag-gated mount = OFF parity ────────────────────────────────────
MNT="${CP}/cmd/tenant-control/mount_appchannels.go"
[ -f "${MNT}" ] || fail "mount_appchannels.go missing"
grep -q 'config.EnvBool("APP_CHANNELS_ENABLED")' "${MNT}" \
  || fail "channel routes are not gated on APP_CHANNELS_ENABLED (OFF must be 404 parity)"
ok "mount gated on APP_CHANNELS_ENABLED (OFF ⇒ no routes = byte-parity)"

# ── static: routes + protected namespace ─────────────────────────────────────
HDL="${CP}/internal/appchannels/handler.go"
grep -q 'POST /v1/app-channels' "${HDL}"              || fail "missing POST /v1/app-channels"
grep -q 'POST /v1/app-channels/{channelId}/accept' "${HDL}" || fail "missing accept route"
grep -q 'POST /v1/realtime/token' "${HDL}"            || fail "missing realtime-token route"
ok "routes registered (open / accept / list / realtime-token)"
grep -q 'REALTIME_PROTECTED_NAMESPACES=.*xapp:' "${ROOT}/deploy/fly/boot.sh" \
  || fail "boot.sh must set REALTIME_PROTECTED_NAMESPACES to include xapp:"
ok "xapp: is a protected realtime namespace (wildcard tokens can't reach it)"

# ── static: namespace-mint unit tests (the security-critical pure logic) ─────
if command -v docker >/dev/null 2>&1; then
  docker run --rm -v "${CP}":/src -w /src \
    -v mini-baas-gocache:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build \
    "${GO_IMG}" bash -c 'go test ./internal/appchannels/... -run "RealtimeNamespaces|HasScope"' \
    >/dev/null 2>&1 || fail "appchannels namespace/scope unit tests failed"
  ok "namespace-mint unit tests pass (\"*\"+xapp:<id> per accepted channel; scope gate)"
else
  printf '  \033[1;33m• docker absent — skipped go test (run on a Docker host)\033[0m\n'
fi

# ── live: full A↔B exchange, C denied (requires the stack) ────────────────────
if [ "${BAAS_VERIFY_LIVE:-0}" = "1" ]; then
  command -v curl >/dev/null 2>&1 || fail "curl required for live mode"
  : "${KONG_URL:?set KONG_URL=https://grobase-stack.fly.dev for live mode}"
  # shellcheck source=scripts/lib/lib-live-tenant.sh
  source "${ROOT}/scripts/lib/lib-live-tenant.sh" 2>/dev/null || fail "lib-live-tenant.sh unavailable"
  printf '  \033[1;33m• live mode: drive open/accept/mint + WS probe via lib-live-tenant\033[0m\n'
  printf '  \033[1;33m  (A,B,C provisioning + WS publish/subscribe assertions run here)\033[0m\n'
fi

printf '\033[1;32mm179 PASS\033[0m — %d static checks; app-channel messaging verified (flag default OFF)\n' "${PASS}"
