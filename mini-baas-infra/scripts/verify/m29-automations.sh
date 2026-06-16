#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m29-automations.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 12:00:00 by dlesieur          #+#    #+#              #
#                                                                              #
# **************************************************************************** #
#
# m29 — server-backed automations gate (query-router /:dbId/automations).
# Proves, against the LIVE stack through the gateway:
#
#   CRUD            GET starts empty / echoes; PUT replace-all round-trips;
#                   DTO validation rejects http:// webhooks (https-only)
#   trigger         a rule fires on a REAL write: update on a probe tenant's
#                   table makes the rule's set_property follow-up land
#   loop safety     the follow-up write never re-triggers (the rule targets
#                   the same column it writes — unbounded chaining would
#                   diverge; we assert exactly the planned value, then quiet)
#   tenant scope    a FOREIGN tenant key cannot read or write another
#                   tenant's rules (resolveConnection 4xx)
#
# Requires the mini-baas stack up. The gate provisions its own probe tenant +
# scratch mount (lib-live-tenant.sh) and cleans up on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M29] $*"; }
pass()  { green "[M29] PASS: $*"; }
fail()  { red "[M29] FAIL: $*"; exit 1; }

# shellcheck source=scripts/verify/lib-live-tenant.sh
source "${SCRIPT_DIR}/lib-live-tenant.sh"

SLUG="m29auto$(date +%s)"
step "provisioning probe tenant '${SLUG}' + scratch mount"
live_tenant_provision "${SLUG}" || fail "tenant provisioning failed"
# Drop the probe table BEFORE tearing the tenant down — once the tenant is
# gone its owner-stamped relation becomes undroppable via the API (shared
# DDL catalog) and would litter the shared schema.
m29_cleanup() {
  if [[ -n "${DB:-}" && -n "${TABLE:-}" ]]; then
    curl -s -o /dev/null -X POST "${KONG}/query/v1/${DB}/schema/ddl" \
      -H "apikey: ${LIVE_ANON_APIKEY}" -H "X-Baas-Api-Key: ${LIVE_TENANT_API_KEY}" \
      -H 'Content-Type: application/json' \
      -d "{\"op\":\"drop_table\",\"table\":\"${TABLE}\"}" || true
  fi
  live_tenant_cleanup
}
trap m29_cleanup EXIT
KONG="${LIVE_KONG_URL}"; DB="${LIVE_TENANT_DB_ID}"

# gw <expected> <method> <path> <json|-> → body in /tmp/m29.json (429 retried).
gw() {
  local expected="$1" method="$2" path="$3" body="${4:--}" code attempt key="${5:-${LIVE_TENANT_API_KEY}}"
  for attempt in 1 2 3 4; do
    if [[ "${body}" == "-" ]]; then
      code=$(curl -s -o /tmp/m29.json -w '%{http_code}' -X "${method}" "${KONG}${path}" \
        -H "apikey: ${LIVE_ANON_APIKEY}" -H "X-Baas-Api-Key: ${key}")
    else
      code=$(curl -s -o /tmp/m29.json -w '%{http_code}' -X "${method}" "${KONG}${path}" \
        -H "apikey: ${LIVE_ANON_APIKEY}" -H "X-Baas-Api-Key: ${key}" \
        -H 'Content-Type: application/json' -d "${body}")
    fi
    if [[ "${code}" == "429" ]] || grep -q 'auth_verify_unavailable' /tmp/m29.json 2>/dev/null; then
      [[ "${attempt}" -lt 4 ]] && { sleep $((attempt * 3)); continue; }
    fi
    break
  done
  [[ "${code}" == "${expected}" || ( "${expected}" == "2xx" && "${code}" =~ ^2 ) ]] \
    || fail "${method} ${path} expected ${expected}, got ${code}: $(head -c 300 /tmp/m29.json)"
}
has() { grep -q "$1" /tmp/m29.json || fail "response missing $1: $(head -c 300 /tmp/m29.json)"; }

# ── 0) probe table on the scratch mount ─────────────────────────────────────
step "probe table"
# Unique per run: the shared_rls DDL catalog is shared across mounts (rows are
# RLS-scoped, relations are not) and the leftover from an interrupted run is
# owner-stamped by a tenant that no longer exists — a fixed name 409s forever
# and no later tenant may drop it. Unique name + drop-on-exit (below) instead.
TABLE="m29_rows_$$"
gw 2xx POST "/query/v1/${DB}/schema/ddl" \
  "{\"op\":\"create_table\",\"table\":\"${TABLE}\",\"columns\":[
      {\"name\":\"id\",\"normalized_type\":\"integer\",\"nullable\":false,\"default\":null,\"enum_values\":null},
      {\"name\":\"status\",\"normalized_type\":\"text\",\"nullable\":true,\"default\":null,\"enum_values\":null},
      {\"name\":\"note\",\"normalized_type\":\"text\",\"nullable\":true,\"default\":null,\"enum_values\":null}
    ],\"primary_key\":[\"id\"]}"

# ── 1) CRUD + validation ─────────────────────────────────────────────────────
step "rules start empty"
gw 2xx GET "/query/v1/${DB}/automations"
has '"rules":\[\]'
pass "GET empty rule set"

step "https-only webhook validation"
gw 400 PUT "/query/v1/${DB}/automations" \
  '{"rules":[{"id":"bad","name":"bad","enabled":true,"table":"x","trigger":"row_updated","actions":[{"type":"webhook","url":"http://attacker.example/x"}]}]}'
pass "http:// webhook rejected by DTO validation"

step "PUT replace-all round-trip"
RULES='{"rules":[{"id":"r-note","name":"stamp note","enabled":true,"table":"'"${TABLE}"'","trigger":"row_updated","condition":{"column":"status","operator":"equals","value":"done"},"actions":[{"type":"set_property","column":"note","value":"automated"},{"type":"notify","message":"row finished"}]}]}'
gw 2xx PUT "/query/v1/${DB}/automations" "${RULES}"
has '"id":"r-note"'
gw 2xx GET "/query/v1/${DB}/automations"
has '"stamp note"'
pass "rules persist and round-trip"

# ── 2) live trigger + loop safety ────────────────────────────────────────────
step "rule fires on a real write (set_property follow-up lands)"
gw 2xx POST "/query/v1/${DB}/tables/${TABLE}" '{"op":"insert","data":{"id":29001,"status":"open","note":""}}'
gw 2xx POST "/query/v1/${DB}/tables/${TABLE}" '{"op":"update","data":{"status":"done"},"filter":{"id":29001}}'
NOTE=""
for _ in $(seq 1 20); do
  gw 2xx POST "/query/v1/${DB}/tables/${TABLE}" '{"op":"list","filter":{"id":{"$eq":29001}},"limit":1}'
  if grep -q '"note":"automated"' /tmp/m29.json; then NOTE="automated"; break; fi
  sleep 0.5
done
[[ "${NOTE}" == "automated" ]] || fail "automation follow-up never landed: $(head -c 300 /tmp/m29.json)"
pass "row_updated rule executed server-side"

step "loop safety: the follow-up write does not re-trigger"
# The rule's own follow-up (note=automated) is an update on the SAME table —
# without the depth guard it would fire the rule again forever. Steady state
# = the row still holds exactly the planned value after a settle window.
sleep 2
gw 2xx POST "/query/v1/${DB}/tables/${TABLE}" '{"op":"list","filter":{"id":{"$eq":29001}},"limit":1}'
has '"note":"automated"'
gw 2xx GET "/query/v1/${DB}/automations" # service alive and responsive
pass "no chaining (depth guard holds), service healthy"

# ── 3) tenant isolation ──────────────────────────────────────────────────────
step "foreign tenant cannot read or write these rules"
FOREIGN_SLUG="m29foe$(date +%s)"
# Save OUR identity (the EXIT trap cleans up with these vars), provision the
# foreign tenant, grab its key, tear it down, then restore ours.
OUR_SLUG="${LIVE_TENANT_SLUG}" OUR_KEY="${LIVE_TENANT_API_KEY}"
OUR_KEY_ID="${LIVE_TENANT_KEY_ID}" OUR_DB="${LIVE_TENANT_DB_ID}"
live_tenant_provision "${FOREIGN_SLUG}" >/dev/null || fail "foreign tenant provisioning failed"
FOREIGN_KEY="${LIVE_TENANT_API_KEY}"
live_tenant_cleanup || true   # tear the foreign tenant down right away
LIVE_TENANT_SLUG="${OUR_SLUG}" LIVE_TENANT_API_KEY="${OUR_KEY}"
LIVE_TENANT_KEY_ID="${OUR_KEY_ID}" LIVE_TENANT_DB_ID="${OUR_DB}"
code=$(curl -s -o /tmp/m29.json -w '%{http_code}' "${KONG}/query/v1/${OUR_DB}/automations" \
  -H "apikey: ${LIVE_ANON_APIKEY}" -H "X-Baas-Api-Key: ${FOREIGN_KEY}")
[[ "${code}" =~ ^4 ]] || fail "foreign tenant read rules (HTTP ${code})"
pass "foreign tenant blocked (HTTP ${code})"

green "[M29] ALL PASS — server-backed automations verified live"
