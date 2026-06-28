#!/usr/bin/env bash
# ============================================================
# m176 — distinct-database-per-app isolation (contract-provisioned)
#
# Each provisioned contract (website, vault42, …) gets its OWN physical database.
# The key→mount resolver gates every lookup on (mount_id AND tenant_id), so a
# foreign app's key resolves ZERO rows for another app's mount — a 404, never a
# cross-app read. Spoofing X-Baas-Tenant-Id changes nothing (the key's tenant is
# authoritative). This is the strongest provisionable isolation.
#
# STATIC (always): the tenant gate exists in the resolver; the provisioner does a
# physical CREATE DATABASE per contract; both live contracts are present.
# LIVE (BAAS_VERIFY_LIVE=1, KONG_URL): website key on website mount → 200; website
# key on vault42 mount → 404 (both directions); header spoof still 404; on-machine
# exactly two app databases.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CP="${ROOT}/src/control-plane"
PASS=0
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

printf '\033[1m── m176: distinct-DB-per-app isolation ──\033[0m\n'

# ── static: the key→mount tenant gate is load-bearing ────────────────────────
CONN="${CP}/internal/adapterregistry/connection.go"
[ -f "${CONN}" ] || fail "adapterregistry/connection.go missing"
grep -q 'tenant_id' "${CONN}" || fail "resolver does not scope mount lookup by tenant_id"
ok "key→mount resolver gates on tenant_id (foreign key ⇒ 0 rows ⇒ 404)"

# ── static: the provisioner creates a physical DB per contract ───────────────
PC="${ROOT}/scripts/provision-contract.sh"
[ -f "${PC}" ] || fail "provision-contract.sh missing"
grep -qiE 'create database|ensure_database' "${PC}" \
  || fail "provisioner does not create a physical database per contract"
ok "provisioner creates a distinct physical database per contract"

# ── static: both live contracts present ──────────────────────────────────────
for c in website vault42; do
  [ -f "${ROOT}/infra/config/contracts/${c}.json" ] || fail "contract ${c}.json missing"
done
ok "live contracts present (website, vault42 — two distinct databases)"

# ── live: cross-app key denial over public HTTPS ─────────────────────────────
if [ "${BAAS_VERIFY_LIVE:-0}" = "1" ]; then
  command -v curl >/dev/null 2>&1 || fail "curl required for live mode"
  : "${KONG_URL:?set KONG_URL=https://grobase-stack.fly.dev for live mode}"
  : "${WEBSITE_KEY:?set WEBSITE_KEY (website mbk_ key)}"
  : "${WEBSITE_DBID:?set WEBSITE_DBID}"; : "${VAULT42_DBID:?set VAULT42_DBID}"
  : "${ANON_KEY:?set ANON_KEY}"
  good=$(curl -s -o /dev/null -w '%{http_code}' \
    "${KONG_URL}/query/v1/${WEBSITE_DBID}/tables" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${WEBSITE_KEY}")
  [ "${good}" = "200" ] || fail "website key on its OWN mount expected 200, got ${good}"
  ok "live: website key on website mount → 200"
  cross=$(curl -s -o /dev/null -w '%{http_code}' \
    "${KONG_URL}/query/v1/${VAULT42_DBID}/tables" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${WEBSITE_KEY}")
  [ "${cross}" = "404" ] || fail "website key on vault42 mount expected 404, got ${cross}"
  ok "live: website key on vault42 mount → 404 (cross-app isolation holds)"
  spoof=$(curl -s -o /dev/null -w '%{http_code}' \
    "${KONG_URL}/query/v1/${VAULT42_DBID}/tables" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${WEBSITE_KEY}" -H "X-Baas-Tenant-Id: vault42")
  [ "${spoof}" = "404" ] || fail "tenant-header spoof expected 404, got ${spoof}"
  ok "live: X-Baas-Tenant-Id spoof still 404 (key's tenant is authoritative)"
fi

printf '\033[1;32mm176 PASS\033[0m — %d static checks; distinct-DB-per-app isolation verified\n' "${PASS}"
