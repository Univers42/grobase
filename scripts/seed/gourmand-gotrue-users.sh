#!/usr/bin/env bash
# **************************************************************************** #
#  gourmand-gotrue-users.sh — GoTrue accounts for vite-gourmand's seed users  #
#                                                                              #
#  The app's seed `User` table (dylan=superadmin, …) has no GoTrue identities, #
#  so logging in as a seed user gives the wrong role and no admin access. This #
#  creates a GoTrue account for every seed user with its seed role in          #
#  app_metadata.role + a shared known password, and links User.auth_id +       #
#  owner_id so the data plane owner-scopes their rows. Idempotent. Run AFTER    #
#  gourmand-baas.sh.                                                            #
#                                                                              #
#  Password for ALL seeded accounts: Gourmand#2026                             #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_ENV="${REPO_ROOT}/.gourmand-baas.env"
PG_CTN="mini-baas-postgres"
GOURMAND_DB="gourmand"
PASSWORD="Gourmand#2026"

cyan() { printf '\033[0;36m[gourmand-users] %s\033[0m\n' "$*"; }
fail() { printf '\033[0;31m[gourmand-users] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "${STATE_ENV}" ]] || fail "run scripts/seed/gourmand-baas.sh first"
# shellcheck disable=SC1090
source "${STATE_ENV}"
KONG="${VG_KONG_URL}"; ANON="${VG_ANON_APIKEY}"; SVC="${VG_SERVICE_APIKEY}"
PG_USER="$(_lt_env "${PG_CTN}" POSTGRES_USER)"; PG_USER="${PG_USER:-postgres}"
PSQL() { docker exec -i "${PG_CTN}" psql -U "${PG_USER}" -d "${GOURMAND_DB}" -tAc "$1"; }

# seed role name → role string used in the JWT (frontend mapRole + data-plane is_admin)
norm_role() { case "$1" in superadmin) echo superadmin;; admin) echo admin;; employee) echo employee;; *) echo customer;; esac; }

cyan "creating a GoTrue identity for each seed User (password '${PASSWORD}')"
created=0; linked=0
while IFS='|' read -r email role; do
  [[ -n "${email}" ]] || continue
  jrole="$(norm_role "${role}")"
  code=$(curl -s -o /tmp/gu.json -w '%{http_code}' -X POST "${KONG}/auth/v1/admin/users" \
    -H "apikey: ${ANON}" -H "Authorization: Bearer ${SVC}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"${PASSWORD}\",\"role\":\"${jrole}\",\"email_confirm\":true}")
  sub=""
  if [[ "${code}" == "200" || "${code}" == "201" ]]; then
    sub="$(_lt_json_field id </tmp/gu.json)"; created=$((created+1))
  else
    curl -s -o /tmp/gul.json "${KONG}/auth/v1/admin/users?per_page=2000" \
      -H "apikey: ${ANON}" -H "Authorization: Bearer ${SVC}" || true
    sub="$(EMAIL="${email}" python3 -c '
import json,os
try:
  d=json.load(open("/tmp/gul.json"))
  print(next((u.get("id","") for u in d.get("users",[]) if u.get("email")==os.environ["EMAIL"]),""))
except Exception: print("")' 2>/dev/null)"
  fi
  if [[ -n "${sub}" ]]; then
    PSQL "UPDATE \"User\" SET auth_id='${sub}', owner_id='user:${sub}' WHERE email='${email//\'/\'\'}'" >/dev/null 2>&1 && linked=$((linked+1)) || true
  fi
done < <(PSQL "SELECT u.email, COALESCE(r.name,'utilisateur') FROM \"User\" u LEFT JOIN \"Role\" r ON r.id=u.role_id WHERE u.email IS NOT NULL ORDER BY u.id")

cyan "DONE: ${created} new GoTrue accounts, ${linked} User rows linked. Login as e.g. dylan@vitegourmand.dev / ${PASSWORD} (superadmin)."