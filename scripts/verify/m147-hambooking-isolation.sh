#!/usr/bin/env bash
# **************************************************************************** #
#  m147-hambooking-isolation.sh — HamBooking-on-Grobase isolation gate         #
#                                                                              #
#  Proves the two flag-gated data-plane features the HamBooking app relies on, #
#  end to end through Kong against the RUNNING stack (MariaDB engine):         #
#    F1  per-table isolation — the `services` catalog (a mount shared_resource) #
#        is readable by two DIFFERENT user JWTs (shared, not owner-scoped).     #
#    USR `users` is OWNER-SCOPED (NOT shared) — user B lists `users` and sees   #
#        exactly its own row (no PII firehose), cannot mutate A's row, and a    #
#        self-escalation `role=ADMIN` write is rejected by the role-lock trigger.#
#    F2a owner-scoping — a `reservations` row inserted under user A's JWT is    #
#        NOT visible to user B (each user owns their rows).                     #
#    F2b admin bypass — the SAME row IS visible to the admin JWT (role=admin).  #
#    CAPS the BEFORE INSERT trigger rejects a 3rd same-day client booking.      #
#                                                                              #
#  Requires DATA_PLANE_PER_TABLE_ISOLATION=1 + DATA_PLANE_ADMIN_BYPASS=1 on the #
#  data plane and the hambooking mount registered with                         #
#  shared_resources=[services,carvers] (users is owner-scoped). Provisioning is #
#  idempotent.                                                                  #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MYSQL_CTN="mini-baas-mysql"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M147] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M147] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

TMP="$(mktemp -d)"
USER_IDS=()
trap 'rm -rf "${TMP}"' EXIT

jval() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null || true; }
jsub() { python3 -c '
import sys,base64,json
p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p)).get("sub",""))' "$1" 2>/dev/null || true; }
jrows() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("rows",[])))' "$1" 2>/dev/null || echo 0; }
my_root_pw() {
  docker inspect "${MYSQL_CTN}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/^MYSQL_ROOT_PASSWORD=//p' | head -1
}
myq() { docker exec "${MYSQL_CTN}" mariadb -uroot -p"$(my_root_pw)" hambooking -N -e "$1" 2>/dev/null; }

# ── 1) provision (idempotent) ────────────────────────────────────────────────
step "1/5 provision the hambooking tenant (idempotent)"
bash "${BAAS_DIR}/scripts/seed/hambooking-tenant.sh" >"${TMP}/seed.log" 2>&1 \
  || fail "provisioning failed — $(tail -3 "${TMP}/seed.log")"
# shellcheck disable=SC1091
source "${BAAS_DIR}/.hambooking-tenant.env"
KONG="${HB_KONG_URL}"; ANON="${HB_ANON_APIKEY}"; AK="${HB_API_KEY}"; DB="${HB_DB_ID}"
SVC="${HB_SERVICE_APIKEY}"
[[ -n "${KONG}" && -n "${AK}" && -n "${DB}" && -n "${SVC}" ]] || fail "incomplete provisioning state"
ok "tenant=${HB_TENANT_SLUG} mount=${DB}"

# /query CRUD helper (optional user Bearer as $3) → /tmp result, echoes status.
q() {
  local hdr=(-H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" -H 'Content-Type: application/json')
  [[ -n "${3:-}" ]] && hdr+=(-H "Authorization: Bearer $3")
  curl -s -o "${TMP}/q.json" -w '%{http_code}' -X POST "${KONG}/query/v1/${DB}/tables/$1" "${hdr[@]}" -d "$2"
}
# Create a confirmed GoTrue user with role $2 → echoes "<sub> <jwt>".
mk_user() {
  local email="m147_$1_$(date +%s)$$@hambooking.com" role="$2"
  curl -s -o "${TMP}/au.json" -X POST "${KONG}/auth/v1/admin/users" \
    -H "apikey: ${ANON}" -H "Authorization: Bearer ${SVC}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"M147pass!secret\",\"role\":\"${role}\",\"email_confirm\":true}" >/dev/null
  curl -s -o "${TMP}/tk.json" -X POST "${KONG}/auth/v1/token?grant_type=password" \
    -H "apikey: ${ANON}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"M147pass!secret\"}"
  local jwt sub
  jwt="$(jval "${TMP}/tk.json" access_token)"
  sub="$(jsub "${jwt}")"
  [[ -n "${jwt}" && -n "${sub}" ]] || fail "mk_user $1 returned no JWT/sub: $(head -c 200 "${TMP}/tk.json")"
  echo "${sub} ${jwt}"
}

# ── 2) F1: shared `services` readable by two different users ──────────────────
step "2/5 F1 shared catalog: services readable by two different user JWTs"
read -r UA JA <<<"$(mk_user a client)"
read -r UB JB <<<"$(mk_user b client)"
USER_IDS+=("${UA}" "${UB}")
[[ "$(q services '{"op":"list"}' "${JA}")" == "201" ]] || fail "A cannot read services: $(head -c 200 "${TMP}/q.json")"
[[ "$(jrows "${TMP}/q.json")" -ge 3 ]] || fail "A sees <3 services (shared read broken)"
[[ "$(q services '{"op":"list"}' "${JB}")" == "201" ]] || fail "B cannot read services"
[[ "$(jrows "${TMP}/q.json")" -ge 3 ]] || fail "B sees <3 services"
ok "services (shared_resource) readable across two owners"

# ── 2b) users is OWNER-SCOPED: B reads only its own profile; no self-escalation ─
step "2b/5 owner-scoped users: B reads only its own row, cannot escalate role"
# B registers its own profile via /query → data plane owner-stamps user:UB.
breg="{\"op\":\"insert\",\"data\":{\"auth_id\":\"${UB}\",\"dni\":\"22222222B\",\"first_name\":\"M147\",\"last_name\":\"ClientB\",\"email\":\"m147bp_$$@hb.com\",\"phone\":\"622\",\"role\":\"CLIENT\"}}"
[[ "$(q users "${breg}" "${JB}")" == "201" ]] || fail "B cannot register own users profile: $(head -c 200 "${TMP}/q.json")"
grep -q "\"owner_id\":\"user:${UB}\"" "${TMP}/q.json" || fail "B's users row not owner-stamped to user B"
# Seed A's profile too (owner user:UA) so the DB holds >1 user row.
myq "INSERT IGNORE INTO users (owner_id,auth_id,dni,first_name,last_name,email,phone,role)
     VALUES ('user:${UA}','${UA}','11111111A','M147','ClientA','m147ap_$$@hb.com','611','CLIENT');" >/dev/null || true
# B lists users → exactly its OWN row (count==1, auth_id==UB) — NOT a PII firehose.
q users '{"op":"list"}' "${JB}" >/dev/null
[[ "$(jrows "${TMP}/q.json")" == "1" ]] || fail "B sees $(jrows "${TMP}/q.json") user rows — users not owner-scoped (PII leak)"
seen_auth="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])).get("rows",[]); print(r[0].get("auth_id","") if r else "")' "${TMP}/q.json" 2>/dev/null)"
[[ "${seen_auth}" == "${UB}" ]] || fail "B's single users row is not B's own (auth_id=${seen_auth})"
ok "users owner-scoped: B sees exactly its own row"
# B attempts to escalate its OWN row to ADMIN → must be rejected (role-lock trigger).
esc="$(q users "{\"op\":\"update\",\"filter\":{\"auth_id\":\"${UB}\"},\"data\":{\"role\":\"ADMIN\"}}" "${JB}")"
[[ "${esc}" != "201" && "${esc}" != "200" ]] || fail "B escalated own role to ADMIN (status ${esc}) — role-lock broken"
db_role="$(myq "SELECT role FROM users WHERE auth_id='${UB}'")"
[[ "${db_role}" == "CLIENT" ]] || fail "B's role is now ${db_role} in the DB — self-escalation succeeded"
ok "self-escalation rejected (status ${esc}); B stays CLIENT"
# B cannot reach A's row at all (owner-scoped update touches 0 rows).
q users "{\"op\":\"update\",\"filter\":{\"auth_id\":\"${UA}\"},\"data\":{\"phone\":\"999\"}}" "${JB}" >/dev/null 2>&1 || true
a_phone="$(myq "SELECT phone FROM users WHERE auth_id='${UA}'")"
[[ "${a_phone}" != "999" ]] || fail "B mutated A's users row — owner-scoping broken"
ok "B cannot touch A's row (cross-user write owner-scoped)"

# ── 3) admin sign-in + FK seed rows ──────────────────────────────────────────
step "3/5 admin sign-in + FK seed rows"
ADMIN_JWT="$(curl -s -X POST "${KONG}/auth/v1/token?grant_type=password" \
  -H "apikey: ${ANON}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${HB_ADMIN_EMAIL}\",\"password\":\"${HB_ADMIN_PASSWORD}\"}" \
  -o "${TMP}/adm.json" >/dev/null 2>&1; jval "${TMP}/adm.json" access_token)"
[[ -n "${ADMIN_JWT}" ]] || fail "admin login failed: $(head -c 200 "${TMP}/adm.json")"
[[ "$(jsub "${ADMIN_JWT}")" == "${HB_ADMIN_SUB}" ]] || fail "admin sub mismatch"
# client + carver profile rows (FK targets) via root; users is owner-scoped now,
# so the FK profile rows are owner-stamped to user A / the carver (user:<sub>).
myq "INSERT IGNORE INTO users (owner_id,auth_id,dni,first_name,last_name,email,phone,role)
     VALUES ('user:${UA}','${UA}','77777777G','M147','ClientA','m147a_$$@hb.com','677','CLIENT');
     INSERT IGNORE INTO users (owner_id,auth_id,dni,first_name,last_name,email,phone,role)
     VALUES ('user:m147carv-$$','m147carv-$$','88888888H','M147','Carver','m147c_$$@hb.com','688','CLIENT');
     INSERT IGNORE INTO carvers (user_id,specialty)
     SELECT id,'jamon' FROM users WHERE email='m147c_$$@hb.com';" >/dev/null || true
CID="$(myq "SELECT id FROM users WHERE auth_id='${UA}'")"
CVID="$(myq "SELECT id FROM carvers WHERE user_id=(SELECT id FROM users WHERE email='m147c_$$@hb.com')")"
[[ -n "${CID}" && -n "${CVID}" ]] || fail "FK seed rows missing (client=${CID} carver=${CVID})"
ok "admin role=admin; client=${CID} carver=${CVID}"

# ── 4) F2: owner-scoping + admin bypass ──────────────────────────────────────
step "4/5 F2 owner-scoping: A's reservation hidden from B, visible to admin"
ins="{\"op\":\"insert\",\"data\":{\"client_id\":${CID},\"carver_id\":${CVID},\"service_id\":3,\"reservation_date\":\"2026-06-29\",\"start_time\":\"10:00:00\",\"end_time\":\"10:30:00\"}}"
[[ "$(q reservations "${ins}" "${JA}")" == "201" ]] || fail "A insert reservation: $(head -c 200 "${TMP}/q.json")"
grep -q "\"owner_id\":\"user:${UA}\"" "${TMP}/q.json" || fail "inserted row not owner-stamped to user A"
q reservations '{"op":"list"}' "${JA}" >/dev/null
[[ "$(jrows "${TMP}/q.json")" -ge 1 ]] || fail "A cannot see own reservation"
q reservations '{"op":"list"}' "${JB}" >/dev/null
[[ "$(jrows "${TMP}/q.json")" == "0" ]] || fail "B SEES A's reservation — owner-scoping broken (F2a)"
ok "owner-scoped: A sees its row, B sees none"
q reservations '{"op":"list"}' "${ADMIN_JWT}" >/dev/null
[[ "$(jrows "${TMP}/q.json")" -ge 1 ]] || fail "admin does NOT see A's reservation — admin bypass broken (F2b)"
ok "admin bypass: admin sees A's row across owners"

# ── 5) caps trigger: 3rd same-day client booking rejected ────────────────────
step "5/5 caps trigger: 3rd same-day client booking rejected"
mkres() {
  q reservations "{\"op\":\"insert\",\"data\":{\"client_id\":${CID},\"carver_id\":${CVID},\"service_id\":3,\"reservation_date\":\"2026-06-30\",\"start_time\":\"$1\",\"end_time\":\"$2\"}}" "${JA}"
}
[[ "$(mkres 10:00:00 10:30:00)" == "201" ]] || fail "1st booking should succeed"
[[ "$(mkres 11:00:00 11:30:00)" == "201" ]] || fail "2nd booking should succeed"
third="$(mkres 12:00:00 12:30:00)"
[[ "${third}" != "201" && "${third}" != "200" ]] || fail "3rd same-day booking SUCCEEDED — caps trigger did not fire"
persisted="$(myq "SELECT COUNT(*) FROM reservations WHERE reservation_date='2026-06-30' AND owner_id='user:${UA}'")"
[[ "${persisted}" == "2" ]] || fail "expected 2 persisted bookings on 2026-06-30, got ${persisted} (trigger leaked)"
ok "trigger rejected the 3rd booking (status ${third}); only 2 rows persisted"

# ── cleanup test data (leave the permanent tenant + schema + admin + services) ─
for uid in "${USER_IDS[@]}"; do
  q reservations "{\"op\":\"delete\",\"filter\":{\"owner_id\":{\"\$eq\":\"user:${uid}\"}}}" >/dev/null 2>&1 || true
done
myq "DELETE FROM reservations WHERE owner_id='user:${UA}';
     DELETE FROM carvers WHERE user_id IN (SELECT id FROM users WHERE email LIKE 'm147%@hb.com');
     DELETE FROM users WHERE email LIKE 'm147%@hb.com';" >/dev/null 2>&1 || true

# re-confirm services stays shared after all the users-table changes.
[[ "$(q services '{"op":"list"}' "${JB}")" == "201" && "$(jrows "${TMP}/q.json")" -ge 3 ]] \
  || fail "services no longer shared after the run — F1 regressed"
ok "services still shared (F1 intact)"

printf '\033[0;32m[M147] ALL GATES GREEN — HamBooking isolation: F1 shared services · users owner-scope + role-lock · F2a owner-scope · F2b admin bypass · caps trigger\033[0m\n'
