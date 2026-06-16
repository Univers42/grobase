#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m56-functions-live.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M56 — Functions DX live e2e gate (A2). Proves, against the RUNNING mini-baas
# stack through the gateway, that the edge-functions feature is actually live:
#
#   1. deploy/invoke   POST /functions/v1 stores a tenant's source (JWT path);
#                      GET lists it; POST .../invoke runs it in a Deno worker
#                      and returns the handler's body.
#   2. per-fn secrets  POST /admin/v1/function-secrets stores an encrypted
#                      secret; a deployed function reads it at invoke time via
#                      Deno.env (runtime → webhook-dispatcher resolve → inject).
#   3. DB-event trigger a REAL write fires the trigger: the function-dispatcher
#                      consumes the outbox event, invokes the function, and the
#                      delivery ledger records `success`. ALSO proves a write in
#                      one tenant does NOT fire ANOTHER tenant's wildcard trigger
#                      (the cross-tenant firing breach the review caught).
#   4. schedule CRUD   POST/GET/DELETE /admin/v1/function-schedules round-trips
#                      against the function-scheduler (the Kong route fix).
#   5. tenant scope    a FOREIGN user's JWT — even forging our tenant header —
#                      cannot see our functions.
#
# Identity model: functions namespace per X-User-Id (the JWT `sub`); the admin
# trigger/secret surfaces are tenant-scoped from the same forwarded identity.
# The gate mints its JWT with `sub = <tenant slug>` so the functions namespace,
# the trigger/secret tenant scope, AND the data-plane write's outbox tenant_id
# all collapse to one value — the only way the trigger path can match end-to-end.
#
# Requires the stack up with the functions plane (functions-runtime,
# webhook-dispatcher, function-scheduler) and the function migrations applied
# (035/036/037) — step 0 applies them idempotently if missing.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M56] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M56] FAIL — $*"; exit 1; }

# shellcheck source=scripts/verify/lib-live-tenant.sh
source "${SCRIPT_DIR}/lib-live-tenant.sh"

TMP="$(mktemp -d)"
SLUG="m56fn$(date +%s)"
TABLE="m56_rows_$$"

cleanup() {
  # best-effort: delete our deployed functions + probe table + trigger/secret,
  # then let the lib soft-delete the tenant.
  for fn in echofn secretfn trigfn; do
    curl -s -o /dev/null -X DELETE "${KONG}/functions/v1/${fn}" \
      -H "apikey: ${ANON}" -H "Authorization: Bearer ${JWT}" 2>/dev/null || true
  done
  if [[ -n "${TRIGGER_ID:-}" ]]; then
    curl -s -o /dev/null -X DELETE "${KONG}/admin/v1/function-triggers/${TRIGGER_ID}" \
      -H "apikey: ${SVC}" -H "Authorization: Bearer ${JWT}" 2>/dev/null || true
  fi
  if [[ -n "${OTHER_TRIGGER_ID:-}" ]]; then
    curl -s -o /dev/null -X DELETE "${KONG}/admin/v1/function-triggers/${OTHER_TRIGGER_ID}" \
      -H "apikey: ${SVC}" -H "Authorization: Bearer ${JWT}" -H "X-Baas-Tenant-Id: ${OTHER_SLUG:-}" 2>/dev/null || true
  fi
  curl -s -o /dev/null -X DELETE "${KONG}/admin/v1/function-secrets/API_TOKEN?function_name=secretfn" \
    -H "apikey: ${SVC}" -H "Authorization: Bearer ${JWT}" 2>/dev/null || true
  if [[ -n "${DB:-}" ]]; then
    curl -s -o /dev/null -X POST "${KONG}/query/v1/${DB}/schema/ddl" \
      -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${APIKEY}" -H 'Content-Type: application/json' \
      -d "{\"op\":\"drop_table\",\"table\":\"${TABLE}\"}" 2>/dev/null || true
  fi
  live_tenant_cleanup 2>/dev/null || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

# Mint an HS256 JWT (iss=supabase → matches the Kong `authenticated` consumer's
# jwt_secret; the global pre-function decodes `sub` into X-User-Id).
mint_jwt() { # secret sub
  python3 - "$1" "$2" <<'PY'
import sys, hmac, hashlib, base64, json, time
secret, sub = sys.argv[1], sys.argv[2]
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=')
hdr = b64(json.dumps({"alg":"HS256","typ":"JWT"}, separators=(',',':')).encode())
pl  = b64(json.dumps({"iss":"supabase","sub":sub,"role":"authenticated",
                      "email":sub+"@m56.local","exp":int(time.time())+3600},
                     separators=(',',':')).encode())
sig = b64(hmac.new(secret.encode(), hdr+b'.'+pl, hashlib.sha256).digest())
print((hdr+b'.'+pl+b'.'+sig).decode())
PY
}

# ── 0) prerequisites: function migrations + tenant + JWT ─────────────────────
step "0/6 prerequisites (migrations, tenant, JWT)"
if [[ "$(docker exec mini-baas-postgres psql -U postgres -d postgres -tAc \
      "SELECT to_regclass('public.function_triggers') IS NOT NULL" 2>/dev/null)" != "t" ]]; then
  for m in 035_function_triggers 036_function_schedules 037_function_secrets; do
    sed '/^#/d' "${BAAS_DIR}/scripts/migrations/postgresql/${m}.sql" \
      | docker exec -i mini-baas-postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null \
      || fail "could not apply migration ${m}"
  done
fi
live_tenant_provision "${SLUG}" || fail "tenant provisioning failed"
KONG="${LIVE_KONG_URL}"; DB="${LIVE_TENANT_DB_ID}"
ANON="${LIVE_ANON_APIKEY}"; SVC="${LIVE_SERVICE_APIKEY}"; APIKEY="${LIVE_TENANT_API_KEY}"

JWT_SECRET="$(_lt_env mini-baas-gotrue GOTRUE_JWT_SECRET)"
[[ -z "${JWT_SECRET}" ]] && JWT_SECRET="$(_lt_env mini-baas-kong JWT_SECRET)"
[[ -z "${JWT_SECRET}" ]] && JWT_SECRET="$(grep -E '^JWT_SECRET=' "${BAAS_DIR}/.env" | head -1 | cut -d= -f2-)"
[[ -n "${JWT_SECRET}" ]] || fail "could not discover JWT_SECRET"
JWT="$(mint_jwt "${JWT_SECRET}" "${SLUG}")"
FOE_JWT="$(mint_jwt "${JWT_SECRET}" "m56foe-${SLUG}")"
ok "tenant '${SLUG}', mount ${DB}, JWT minted (sub=slug)"

# curl helpers: write body to /tmp/m56.json, echo status.
as_user()   { curl -s -o /tmp/m56.json -w '%{http_code}' -X "$1" "${KONG}$2" -H "apikey: ${ANON}" -H "Authorization: Bearer ${JWT}" "${@:3}"; }
as_foe()    { curl -s -o /tmp/m56.json -w '%{http_code}' -X "$1" "${KONG}$2" -H "apikey: ${ANON}" -H "Authorization: Bearer ${FOE_JWT}" "${@:3}"; }
as_admin()  { curl -s -o /tmp/m56.json -w '%{http_code}' -X "$1" "${KONG}$2" -H "apikey: ${SVC}"  -H "Authorization: Bearer ${JWT}" "${@:3}"; }
as_tenant() { curl -s -o /tmp/m56.json -w '%{http_code}' -X "$1" "${KONG}$2" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${APIKEY}" "${@:3}"; }
has()  { grep -q "$1" /tmp/m56.json || fail "$2: response missing $1 — $(head -c 300 /tmp/m56.json)"; }
nhas() { grep -q "$1" /tmp/m56.json && fail "$2: response leaked $1 — $(head -c 300 /tmp/m56.json)"; return 0; }

deploy() { # name codefile
  local body; body="$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"code":open(sys.argv[2]).read()}))' "$1" "$2")"
  printf '%s' "${body}" > "${TMP}/body.json"
  as_user POST /functions/v1 -H 'Content-Type: application/json' --data-binary @"${TMP}/body.json"
}

# ── 1) deploy / list / invoke ────────────────────────────────────────────────
step "1/6 deploy → list → invoke"
cat > "${TMP}/echofn.ts" <<'TS'
export default async function (input: { tenant_id: string; body: unknown }) {
  return { status: 200, body: { ok: true, echo: input.body, tenant: input.tenant_id } };
}
TS
[[ "$(deploy echofn "${TMP}/echofn.ts")" == "201" ]] || fail "deploy echofn — $(head -c 300 /tmp/m56.json)"
has '"name":"echofn"' "deploy"
[[ "$(as_user GET /functions/v1)" == "200" ]] || fail "list functions"
has '"name":"echofn"' "list"
[[ "$(as_user POST /functions/v1/echofn/invoke -H 'Content-Type: application/json' -d '{"hello":"world"}')" == "200" ]] \
  || fail "invoke echofn — $(head -c 300 /tmp/m56.json)"
has '"ok":true' "invoke"
has '"hello":"world"' "invoke echo"
has "\"tenant\":\"${SLUG}\"" "invoke tenant"
ok "deployed, listed, invoked (echo + tenant namespace correct)"

# ── 2) per-function secrets ──────────────────────────────────────────────────
step "2/6 per-function secret resolved + injected at invoke"
[[ "$(as_admin POST /admin/v1/function-secrets -H 'Content-Type: application/json' \
      -d '{"key":"API_TOKEN","value":"s3cr3t-m56","function_name":"secretfn"}')" == "201" ]] \
  || fail "set secret — $(head -c 300 /tmp/m56.json)"
[[ "$(as_admin GET /admin/v1/function-secrets)" == "200" ]] || fail "list secrets"
has '"key":"API_TOKEN"' "list secrets"
nhas 's3cr3t-m56' "list secrets must not leak plaintext"
cat > "${TMP}/secretfn.ts" <<'TS'
export default async function () {
  return { status: 200, body: { token: Deno.env.get("API_TOKEN") ?? null } };
}
TS
[[ "$(deploy secretfn "${TMP}/secretfn.ts")" == "201" ]] || fail "deploy secretfn"
[[ "$(as_user POST /functions/v1/secretfn/invoke -H 'Content-Type: application/json' -d '{}')" == "200" ]] \
  || fail "invoke secretfn — $(head -c 300 /tmp/m56.json)"
has '"token":"s3cr3t-m56"' "secret injected into worker env"
ok "secret stored encrypted (no plaintext in list), resolved + injected at invoke"

# ── 3) DB-event trigger fires the function ───────────────────────────────────
step "3/6 DB-event trigger → function-dispatcher → delivery success"
cat > "${TMP}/trigfn.ts" <<'TS'
export default async function (input: { headers: Record<string, string> }) {
  return { status: 200, body: { fired: true, source: input.headers["x-baas-event-source"] ?? null } };
}
TS
[[ "$(deploy trigfn "${TMP}/trigfn.ts")" == "201" ]] || fail "deploy trigfn"
[[ "$(as_admin POST /admin/v1/function-triggers -H 'Content-Type: application/json' \
      -d '{"name":"on-write","function_name":"trigfn","aggregates":[],"event_types":[],"enabled":true}')" == "201" ]] \
  || fail "create trigger — $(head -c 300 /tmp/m56.json)"
TRIGGER_ID="$(python3 -c 'import json;print(json.load(open("/tmp/m56.json"))["id"])')"
[[ -n "${TRIGGER_ID}" ]] || fail "trigger create returned no id"
ok "wildcard trigger ${TRIGGER_ID} → trigfn"

# Negative control for cross-tenant firing: register a SECOND, different-tenant
# wildcard trigger. Under the pre-fix dispatcher (no `WHERE tenant_id`; RLS
# bypassed by the superuser connection) tenant ${SLUG}'s write below fired EVERY
# tenant's trigger — so this ghost trigger MUST stay dry after the fix. Admin
# routes are not header-cleared, so X-Baas-Tenant-Id selects the ghost tenant.
OTHER_SLUG="m56ghost-${SLUG}"
[[ "$(as_admin POST /admin/v1/function-triggers -H "X-Baas-Tenant-Id: ${OTHER_SLUG}" -H 'Content-Type: application/json' \
      -d '{"name":"ghost-on-write","function_name":"ghostfn","aggregates":[],"event_types":[],"enabled":true}')" == "201" ]] \
  || fail "create ghost trigger — $(head -c 300 /tmp/m56.json)"
OTHER_TRIGGER_ID="$(python3 -c 'import json;print(json.load(open("/tmp/m56.json"))["id"])')"
ok "ghost trigger ${OTHER_TRIGGER_ID} (tenant ${OTHER_SLUG}) — cross-tenant control"

# probe table + a real write. The table carries a tenant_id column: the outbox
# event payload IS the written row, so the dispatcher's tenant-scoped match only
# works when the row stamps the tenant (the natural multi-tenant contract — the
# seeded `orders` stream payloads carry tenant_id the same way).
[[ "$(as_tenant POST "/query/v1/${DB}/schema/ddl" -H 'Content-Type: application/json' \
      -d "{\"op\":\"create_table\",\"table\":\"${TABLE}\",\"columns\":[
            {\"name\":\"id\",\"normalized_type\":\"integer\",\"nullable\":false,\"default\":null,\"enum_values\":null},
            {\"name\":\"tenant_id\",\"normalized_type\":\"text\",\"nullable\":true,\"default\":null,\"enum_values\":null},
            {\"name\":\"note\",\"normalized_type\":\"text\",\"nullable\":true,\"default\":null,\"enum_values\":null}],
          \"primary_key\":[\"id\"]}")" =~ ^2 ]] || fail "create probe table — $(head -c 300 /tmp/m56.json)"
[[ "$(as_tenant POST "/query/v1/${DB}/tables/${TABLE}" -H 'Content-Type: application/json' \
      -d "{\"op\":\"insert\",\"data\":{\"id\":56001,\"tenant_id\":\"${SLUG}\",\"note\":\"fire\"}}")" =~ ^2 ]] || fail "insert row — $(head -c 300 /tmp/m56.json)"

DELIVERED=""
for _ in $(seq 1 30); do
  if [[ "$(as_admin GET "/admin/v1/function-triggers/${TRIGGER_ID}/deliveries")" == "200" ]] \
     && grep -q '"status":"success"' /tmp/m56.json; then DELIVERED="yes"; break; fi
  sleep 1
done
[[ "${DELIVERED}" == "yes" ]] || fail "trigger never delivered success — $(head -c 400 /tmp/m56.json)"
ok "write → outbox → dispatcher → function invoke → delivery success"

# Cross-tenant no-fire: OUR write must NOT have fired the ghost tenant's trigger.
# The event was already processed (OUR delivery is `success`), so the dispatcher
# has already decided whether to fan out cross-tenant — the ghost's delivery set
# must be empty. With the bug it would carry a delivery (status + our payload).
[[ "$(as_admin GET "/admin/v1/function-triggers/${OTHER_TRIGGER_ID}/deliveries" -H "X-Baas-Tenant-Id: ${OTHER_SLUG}")" == "200" ]] \
  || fail "ghost deliveries query — $(head -c 300 /tmp/m56.json)"
grep -q '"status"' /tmp/m56.json \
  && fail "CROSS-TENANT FIRING: tenant ${SLUG}'s write created a delivery on tenant ${OTHER_SLUG}'s trigger — $(head -c 400 /tmp/m56.json)"
ok "cross-tenant isolation: our write fired ONLY our trigger, ghost tenant stayed dry"

# ── 4) schedule CRUD (the function-scheduler Kong route fix) ──────────────────
step "4/6 schedule CRUD round-trip"
[[ "$(as_admin POST /admin/v1/function-schedules -H 'Content-Type: application/json' \
      -d '{"name":"nightly","function_name":"echofn","schedule_expr":"@daily","enabled":false}')" == "201" ]] \
  || fail "create schedule — $(head -c 300 /tmp/m56.json)"
SCHED_ID="$(python3 -c 'import json;print(json.load(open("/tmp/m56.json"))["id"])')"
[[ "$(as_admin GET /admin/v1/function-schedules)" == "200" ]] || fail "list schedules"
has '"name":"nightly"' "list schedules"
[[ "$(as_admin DELETE "/admin/v1/function-schedules/${SCHED_ID}")" == "200" ]] || fail "delete schedule"
ok "schedule create/list/delete via function-scheduler route"

# ── 5) tenant isolation (incl. forged namespace header) ──────────────────────
step "5/6 a foreign user JWT — even with a forged tenant header — sees nothing"
[[ "$(as_foe GET /functions/v1)" == "200" ]] || fail "foreign list call"
nhas '"name":"echofn"' "foreign user must not see our functions"
# the /functions/ pre-function clear must neutralize a forged namespace header:
# foe JWT + forged X-Baas-Tenant-Id/X-Tenant-Id = our slug still sees nothing.
[[ "$(as_foe GET /functions/v1 -H "X-Baas-Tenant-Id: ${SLUG}" -H "X-Tenant-Id: ${SLUG}")" == "200" ]] \
  || fail "foreign forged-header list call"
nhas '"name":"echofn"' "forged X-Baas-Tenant-Id must not reveal our functions"
ok "functions namespaced per user — foreign JWT (even forging our tenant) sees nothing"

# ── 6) anon-only (no JWT) is rejected ────────────────────────────────────────
step "6/6 anon-key-only (no JWT) deploy is rejected"
code="$(curl -s -o /tmp/m56.json -w '%{http_code}' -X POST "${KONG}/functions/v1" \
        -H "apikey: ${ANON}" -H 'Content-Type: application/json' -d '{"name":"nope","code":"export default()=>({})"}')"
[[ "${code}" == "401" ]] || fail "anon-only deploy should be 401, got ${code} — $(head -c 200 /tmp/m56.json)"
ok "no identity → 401 (functions require an authenticated user)"

green "[M56] ALL GATES GREEN — functions DX fully live: deploy/invoke · per-fn secrets · DB-event trigger firing (+cross-tenant no-fire) · schedule CRUD · tenant isolation (+forged-header) · anon-reject"
