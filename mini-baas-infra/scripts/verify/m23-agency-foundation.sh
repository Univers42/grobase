#!/usr/bin/env bash
# **************************************************************************** #
#  m23-agency-foundation.sh — gate for the agency simulation foundation        #
#                                                                              #
#  Proves Wave 0 of the Binocle Intelligence Agency build:                    #
#    1) live tenant: 11 tables exist on the agency mount with the expected    #
#       row counts, served through the REAL gateway path (Kong key-auth →     #
#       query-router → Rust data plane)                                       #
#    2) graph: /query/v1/graph/overview returns a connected investigation     #
#       graph (explicit edges + FK reference generator)                       #
#    3) identities: 21 @agency.local accounts in gotrue, 21 bridge            #
#       identities, 21 members on the org workspace                           #
#    4) ABAC: /permissions/decide returns the designed role differences —     #
#       director allow, analyst masked amount, field agent denied comms +     #
#       hidden ssn, guest denied evidence                                     #
#                                                                              #
#  Requires: both stacks running, agency-tenant.sh + seed_agency_people.sh    #
#  + seed_agency.py + agency-policies.sh applied (make agency-all).           #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${INFRA_ROOT}/../../.." && pwd)"
TENANT_ENV="${INFRA_ROOT}/.agency-tenant.env"
PEOPLE_ENV="${REPO_ROOT}/tools/seeds/.agency-people.env"

cyan()  { printf '\033[0;36m[M23] %s\033[0m\n' "$*"; }
green() { printf '\033[0;32m[M23] PASS: %s\033[0m\n' "$*"; }
fail()  { printf '\033[0;31m[M23] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "${TENANT_ENV}" ]] || fail "missing ${TENANT_ENV} (run make agency-seed)"
[[ -f "${PEOPLE_ENV}" ]] || fail "missing ${PEOPLE_ENV} (run make agency-people)"
# shellcheck disable=SC1090
source "${TENANT_ENV}"
OWNER_UUID="$(grep '^AGENCY_OWNER_UUID=' "${PEOPLE_ENV}" | cut -d= -f2)"
ORG_WS_ID="$(grep '^AGENCY_ORG_WORKSPACE_ID=' "${PEOPLE_ENV}" | cut -d= -f2)"
person_uuid() { grep "^AGENCY_PERSON_$1=" "${PEOPLE_ENV}" | cut -d= -f2 | cut -d'|' -f1; }
ANALYST_UUID="$(person_uuid 11)"   # Erik Johansson — analyst
AGENT_UUID="$(person_uuid 7)"      # Jack Sullivan — field_agent

# ── 1) tenant tables + row counts through the gateway ────────────────────────
cyan "checking the 11 agency tables through the gateway"
declare -A EXPECT=(
  [cases]=40 [subjects]=60 [locations]=50 [evidence]=120 [leads]=80
  [transactions]=150 [vehicles]=30 [communications]=200 [reports]=40
  [assignments]=100 [edges]=80
)
schema="$(curl -fsS "${AGENCY_KONG_URL}/query/v1/${AGENCY_DB_ID}/schema" \
  -H "apikey: ${AGENCY_ANON_APIKEY}" -H "X-Baas-Api-Key: ${AGENCY_API_KEY}")" \
  || fail "gateway schema fetch failed"
for table in "${!EXPECT[@]}"; do
  echo "${schema}" | grep -q "\"name\":\"${table}\"" || fail "schema missing table ${table}"
done
for table in cases transactions edges; do
  body="$(curl -fsS -X POST "${AGENCY_KONG_URL}/query/v1/${AGENCY_DB_ID}/tables/${table}" \
    -H "apikey: ${AGENCY_ANON_APIKEY}" -H "X-Baas-Api-Key: ${AGENCY_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d '{"op":"aggregate","aggregate":{"aggregates":[{"func":"count","alias":"n"}]}}')" \
    || fail "aggregate count on ${table} failed"
  echo "${body}" | grep -q "\"n\":[ ]*\"\?${EXPECT[${table}]}" \
    || fail "${table} count != ${EXPECT[${table}]}: ${body}"
done
green "11 tables present; spot counts (cases/transactions/edges) match"

# ── 2) graph overview ─────────────────────────────────────────────────────────
cyan "checking the investigation graph"
graph="$(curl -fsS -X POST "${AGENCY_KONG_URL}/query/v1/graph/overview" \
  -H "apikey: ${AGENCY_ANON_APIKEY}" -H "X-Baas-Api-Key: ${AGENCY_API_KEY}" \
  -H 'Content-Type: application/json' \
  -d "{\"resources\":[{\"dbId\":\"${AGENCY_DB_ID}\",\"table\":\"cases\"},{\"dbId\":\"${AGENCY_DB_ID}\",\"table\":\"subjects\"}],\"edgesDbId\":\"${AGENCY_DB_ID}\",\"limit\":200}")" \
  || fail "graph overview failed"
echo "${graph}" | grep -q '"type":"associate"' || fail "graph missing explicit associate edges"
nodes=$(echo "${graph}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["nodes"]))')
[[ "${nodes}" -ge 100 ]] || fail "graph returned only ${nodes} nodes"
green "graph overview serves ${nodes} nodes with explicit investigation edges"

# ── 3) identities ─────────────────────────────────────────────────────────────
cyan "checking accounts, identities, org membership"
RPSQL() { docker exec -i track-binocle-postgres-1 psql -U postgres -d postgres -At "$@"; }
n=$(RPSQL -c "SELECT count(*) FROM auth.users WHERE email LIKE '%@agency.local'")
[[ "${n}" == "21" ]] || fail "expected 21 gotrue accounts, found ${n}"
n=$(RPSQL -c "SELECT count(*) FROM osionos_bridge_identities i JOIN auth.users u ON u.id=i.user_id WHERE u.email LIKE '%@agency.local'")
[[ "${n}" == "21" ]] || fail "expected 21 bridge identities, found ${n}"
# Count the ROSTER members (joined to @agency.local accounts) — the org
# workspace legitimately gains extra members over time (invites are a live
# feature; the dev account may also join), so an exact total would be brittle.
n=$(RPSQL -c "SELECT count(*) FROM osionos_workspace_members m JOIN auth.users u ON u.id=m.user_id WHERE m.workspace_id='${ORG_WS_ID}' AND u.email LIKE '%@agency.local'")
[[ "${n}" == "21" ]] || fail "expected the 21 roster accounts as org members, found ${n}"
# Invite-path evidence is generated fresh each run (Mailpit is an in-memory
# sink — historical emails do not survive container restarts): invite a probe
# user, assert the email lands, then delete the probe account.
PROBE_EMAIL="probe.invite.$(date +%s)@agency.local"
docker exec -e PROBE_EMAIL="${PROBE_EMAIL}" track-binocle-osionos-bridge-1 node -e '
const run = async () => {
  const auth = { "Content-Type": "application/json", Authorization: `Bearer ${process.env.SERVICE_ROLE_KEY}` };
  // Pin the ROOT stack gotrue by container name — the bridge is dual-homed
  // and the `gotrue` alias also exists on the mini-baas network.
  const GOTRUE = "http://track-binocle-gotrue-1:9999";
  const r = await fetch(`${GOTRUE}/invite`, { method: "POST", headers: auth,
    body: JSON.stringify({ email: process.env.PROBE_EMAIL }) });
  if (!r.ok) throw new Error(`invite ${r.status}`);
  const u = await r.json();
  const d = await fetch(`${GOTRUE}/admin/users/${u.id}`, { method: "DELETE", headers: auth });
  if (!d.ok) throw new Error(`cleanup ${d.status}`);
};
run().catch((e) => { console.error(e.message); process.exit(1); });
' || fail "gotrue invite path failed"
sleep 1
curl -s "http://localhost:8025/api/v1/search?query=${PROBE_EMAIL}" | grep -q "You have been invited" \
  || fail "invitation email for ${PROBE_EMAIL} not found in Mailpit"
green "21 accounts + identities + org members; invite→Mailpit path verified live"

# ── 4) ABAC decisions ─────────────────────────────────────────────────────────
cyan "checking role-differentiated ABAC decisions"
PE_TOKEN="$(docker inspect mini-baas-permission-engine \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep '^ADAPTER_REGISTRY_SERVICE_TOKEN=' | cut -d= -f2-)"
[[ -n "${PE_TOKEN}" ]] || fail "permission-engine service token not found"
decide() { # $1 user uuid, $2 table, $3 op
  curl -s -X POST "${AGENCY_KONG_URL}/permissions/v1/permissions/decide" \
    -H "apikey: ${AGENCY_SERVICE_APIKEY}" -H "X-Service-Token: ${PE_TOKEN}" \
    -H "X-Tenant-Id: agency" -H 'Content-Type: application/json' \
    -d "{\"user\":{\"id\":\"$1\"},\"resource_type\":\"table\",\"resource_name\":\"$2\",\"op\":\"$3\"}"
}
decide "${OWNER_UUID}" transactions list | grep -q '"allow":true' \
  || fail "director must be allowed on transactions"
analyst="$(decide "${ANALYST_UUID}" transactions list)"
echo "${analyst}" | grep -q '"allow":true' || fail "analyst must be allowed on transactions"
echo "${analyst}" | grep -q '"amount":"\*\*\*"' || fail "analyst transactions must carry the amount mask: ${analyst}"
decide "${AGENT_UUID}" communications list | grep -q '"allow":false' \
  || fail "field agent must be denied on communications"
decide "${AGENT_UUID}" subjects list | grep -q '"hide":\["ssn"\]' \
  || fail "field agent subjects must hide ssn"
decide "${AGENT_UUID}" transactions update | grep -q '"allow":false' \
  || fail "field agent must be denied transaction writes"
GUEST_UUID="00000000-0000-4000-8000-00000000beef"
docker exec -i mini-baas-postgres psql -U postgres -d postgres -q -c \
  "INSERT INTO user_roles (user_id, role_id) SELECT '${GUEST_UUID}'::uuid, id FROM roles WHERE name='guest' ON CONFLICT DO NOTHING"
decide "${GUEST_UUID}" evidence list | grep -q '"allow":false' \
  || fail "guest must be denied on evidence"
green "director allow / analyst masked / agent denied+hidden / guest denied"

green "M23 agency foundation OK — tenant, data, graph, identities, ABAC all live"
