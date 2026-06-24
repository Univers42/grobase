#!/usr/bin/env bash
# **************************************************************************** #
#  m149-gourmand-baas.sh — vite-gourmand-on-Grobase isolation + triggers gate  #
#                                                                              #
#  Proves vite-gourmand runs faithfully on Grobase (owner-scoped PostgreSQL),  #
#  end to end through Kong against the RUNNING stack:                          #
#    F1  shared catalog — `Menu` (a mount shared_resource) is readable by two  #
#        DIFFERENT user JWTs (world-readable, not owner-scoped).               #
#    F2a owner-scoping — an `Order` inserted under user A's JWT is owner-       #
#        stamped `user:<subA>` and is NOT visible to user B.                   #
#    F2b admin bypass — the SAME Order IS visible to the admin JWT.            #
#    T6  loyalty guard — redeeming below zero is rejected by the BEFORE INSERT #
#        trigger (balance unchanged).                                          #
#    T1  order FSM — an illegal pending→delivered transition is rejected;      #
#        pending→confirmed is accepted.                                        #
#                                                                              #
#  Requires DATA_PLANE_PER_TABLE_ISOLATION=1 + DATA_PLANE_ADMIN_BYPASS=1 on    #
#  the data plane. Provisioning (gourmand-baas.sh) is idempotent.              #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PG_CTN="mini-baas-postgres"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M149] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M149] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

jval() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null || true; }
jrows() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("rows",[])))' "$1" 2>/dev/null || echo 0; }
jrow0() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])).get("rows",[]); print(r[0].get(sys.argv[2],"") if r else "")' "$1" "$2" 2>/dev/null || true; }
jsub() { python3 -c '
import sys,base64,json
p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p)).get("sub",""))' "$1" 2>/dev/null || true; }

# ── 1) provision (idempotent) ────────────────────────────────────────────────
step "1/6 provision the gourmand tenant + owner-scoped mount (idempotent)"
bash "${BAAS_DIR}/scripts/seed/gourmand-baas.sh" >"${TMP}/seed.log" 2>&1 \
  || fail "provisioning failed — $(tail -3 "${TMP}/seed.log")"
# shellcheck disable=SC1091
source "${BAAS_DIR}/.gourmand-baas.env"
KONG="${VG_KONG_URL}"; ANON="${VG_ANON_APIKEY}"; AK="${VG_API_KEY}"; DB="${VG_DB_ID}"
[[ -n "${KONG}" && -n "${AK}" && -n "${DB}" ]] || fail "incomplete provisioning state"
ok "tenant=${VG_TENANT_SLUG} mount=${DB}"

# /query CRUD helper (optional user Bearer as $3) → /tmp result, echoes status.
q() {
  local hdr=(-H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" -H 'Content-Type: application/json')
  [[ -n "${3:-}" ]] && hdr+=(-H "Authorization: Bearer $3")
  curl -s -o "${TMP}/q.json" -w '%{http_code}' -X POST "${KONG}/query/v1/${DB}/tables/$1" "${hdr[@]}" -d "$2"
}
# Create a confirmed GoTrue user with role $2 → echoes "<sub> <jwt>".
mk_user() {
  local email role="$2"
  email="m149_$1_$(date +%s)$$@gourmand.local"
  curl -s -o "${TMP}/au.json" -X POST "${KONG}/auth/v1/admin/users" \
    -H "apikey: ${ANON}" -H "Authorization: Bearer ${VG_SERVICE_APIKEY}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"M149pass!secret\",\"role\":\"${role}\",\"email_confirm\":true}" >/dev/null
  curl -s -o "${TMP}/tk.json" -X POST "${KONG}/auth/v1/token?grant_type=password" \
    -H "apikey: ${ANON}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"M149pass!secret\"}"
  local jwt sub
  jwt="$(jval "${TMP}/tk.json" access_token)"
  sub="$(jsub "${jwt}")"
  [[ -n "${jwt}" && -n "${sub}" ]] || fail "mk_user $1 returned no JWT/sub: $(head -c 200 "${TMP}/tk.json")"
  echo "${email} ${sub} ${jwt}"
}
# Insert an app "User" profile under a user JWT → echoes the SERIAL id.
mk_profile() {
  local email="$1" jwt="$2"
  [[ "$(q User "{\"op\":\"insert\",\"data\":{\"email\":\"${email}\",\"first_name\":\"M149\"}}" "${jwt}")" == "201" ]] \
    || fail "User profile insert failed: $(head -c 200 "${TMP}/q.json")"
  jrow0 "${TMP}/q.json" id
}

# ── 2) F1: shared `Menu` catalog readable by two different users ─────────────
step "2/6 F1 shared catalog: Menu readable by two different user JWTs"
read -r EA UA JA <<<"$(mk_user a customer)"
read -r EB UB JB <<<"$(mk_user b customer)"
[[ "$(q Menu '{"op":"list","limit":5}' "${JA}")" == "201" ]] || fail "A cannot read Menu: $(head -c 200 "${TMP}/q.json")"
ra="$(jrows "${TMP}/q.json")"
[[ "$(q Menu '{"op":"list","limit":5}' "${JB}")" == "201" ]] || fail "B cannot read Menu"
rb="$(jrows "${TMP}/q.json")"
[[ "${ra}" -ge 1 && "${rb}" -ge 1 ]] || fail "Menu not readable by both (A=${ra} B=${rb}) — shared_resources broken"
ok "Menu (shared_resource) readable across two owners (A=${ra} B=${rb})"

# ── 3) profiles + admin sign-in ──────────────────────────────────────────────
step "3/6 app profiles for A/B + admin sign-in"
UAID="$(mk_profile "${EA}" "${JA}")"
UBID="$(mk_profile "${EB}" "${JB}")"
[[ -n "${UAID}" && -n "${UBID}" ]] || fail "profile ids missing (A=${UAID} B=${UBID})"
ADMIN_JWT="$(curl -s -X POST "${KONG}/auth/v1/token?grant_type=password" \
  -H "apikey: ${ANON}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${VG_ADMIN_EMAIL}\",\"password\":\"${VG_ADMIN_PASSWORD}\"}" \
  -o "${TMP}/adm.json" >/dev/null 2>&1; jval "${TMP}/adm.json" access_token)"
[[ -n "${ADMIN_JWT}" ]] || fail "admin login failed: $(head -c 200 "${TMP}/adm.json")"
ok "profiles A=${UAID} B=${UBID}; admin signed in"

# ── 4) F2: owner-scoping + admin bypass on Order ─────────────────────────────
step "4/6 F2 owner-scoping: A's Order hidden from B, visible to admin"
ins="{\"op\":\"insert\",\"data\":{\"user_id\":${UAID},\"delivery_date\":\"2026-07-15\",\"person_number\":4,\"menu_price\":100,\"total_price\":120}}"
[[ "$(q Order "${ins}" "${JA}")" == "201" ]] || fail "A insert Order: $(head -c 200 "${TMP}/q.json")"
grep -q "\"owner_id\":\"user:${UA}\"" "${TMP}/q.json" || fail "inserted Order not owner-stamped to user A"
ONUM="$(jrow0 "${TMP}/q.json" order_number)"
OID="$(jrow0 "${TMP}/q.json" id)"
[[ "${ONUM}" == VG-* ]] || fail "order_number trigger did not fire (got '${ONUM}')"
q Order "{\"op\":\"list\",\"filter\":{\"id\":{\"\$eq\":${OID}}}}" "${JA}" >/dev/null
[[ "$(jrows "${TMP}/q.json")" -ge 1 ]] || fail "A cannot see own Order"
q Order "{\"op\":\"list\",\"filter\":{\"id\":{\"\$eq\":${OID}}}}" "${JB}" >/dev/null
[[ "$(jrows "${TMP}/q.json")" == "0" ]] || fail "B SEES A's Order — owner-scoping broken (F2a)"
ok "owner-scoped: A sees its Order (${ONUM}), B sees none"
q Order "{\"op\":\"list\",\"filter\":{\"id\":{\"\$eq\":${OID}}}}" "${ADMIN_JWT}" >/dev/null
[[ "$(jrows "${TMP}/q.json")" -ge 1 ]] || fail "admin does NOT see A's Order — admin bypass broken (F2b)"
ok "admin bypass: admin sees A's Order across owners"

# ── 5) T6 loyalty guard: over-redeem rejected ────────────────────────────────
step "5/6 T6 loyalty guard: redeem below zero rejected, balance unchanged"
[[ "$(q LoyaltyAccount "{\"op\":\"insert\",\"data\":{\"user_id\":${UAID},\"balance\":0}}" "${JA}")" == "201" ]] \
  || fail "LoyaltyAccount insert: $(head -c 200 "${TMP}/q.json")"
LAID="$(jrow0 "${TMP}/q.json" id)"
redeem="$(q LoyaltyTransaction "{\"op\":\"insert\",\"data\":{\"loyalty_account_id\":${LAID},\"points\":-99999,\"type\":\"redeem\"}}" "${JA}")"
[[ "${redeem}" != "201" && "${redeem}" != "200" ]] || fail "over-redeem SUCCEEDED (status ${redeem}) — T6 guard did not fire"
q LoyaltyAccount "{\"op\":\"list\",\"filter\":{\"id\":{\"\$eq\":${LAID}}}}" "${JA}" >/dev/null
[[ "$(jrow0 "${TMP}/q.json" balance)" == "0" ]] || fail "balance moved despite rejected redeem"
ok "loyalty guard rejected the over-redeem (status ${redeem}); balance still 0"

# ── 6) T1 order FSM: illegal transition rejected, legal one accepted ─────────
step "6/6 T1 order FSM: pending→delivered rejected, pending→confirmed accepted"
bad="$(q Order "{\"op\":\"update\",\"filter\":{\"id\":{\"\$eq\":${OID}}},\"data\":{\"status\":\"delivered\"}}" "${JA}")"
[[ "${bad}" != "201" && "${bad}" != "200" ]] || fail "illegal pending→delivered SUCCEEDED (status ${bad}) — T1 FSM did not fire"
good="$(q Order "{\"op\":\"update\",\"filter\":{\"id\":{\"\$eq\":${OID}}},\"data\":{\"status\":\"confirmed\"}}" "${JA}")"
[[ "${good}" == "200" || "${good}" == "201" ]] || fail "legal pending→confirmed rejected (status ${good}): $(head -c 200 "${TMP}/q.json")"
ok "FSM rejected pending→delivered (${bad}); accepted pending→confirmed (${good})"

# ── cleanup A/B test data (leave the permanent tenant + mount + catalog + demo users) ─
q LoyaltyTransaction "{\"op\":\"delete\",\"filter\":{\"loyalty_account_id\":{\"\$eq\":${LAID}}}}" "${ADMIN_JWT}" >/dev/null 2>&1 || true
q LoyaltyAccount "{\"op\":\"delete\",\"filter\":{\"id\":{\"\$eq\":${LAID}}}}" "${ADMIN_JWT}" >/dev/null 2>&1 || true
q Order "{\"op\":\"delete\",\"filter\":{\"id\":{\"\$eq\":${OID}}}}" "${ADMIN_JWT}" >/dev/null 2>&1 || true
q User "{\"op\":\"delete\",\"filter\":{\"id\":{\"\$in\":[${UAID},${UBID}]}}}" "${ADMIN_JWT}" >/dev/null 2>&1 || true

printf '\033[0;32m[M149] ALL GATES GREEN — vite-gourmand on Grobase: F1 shared Menu · F2a owner-scope · F2b admin bypass · T6 loyalty guard · T1 order FSM\033[0m\n'
