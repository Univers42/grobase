#!/usr/bin/env bash
# **************************************************************************** #
#  agency-tenant.sh — provision the PERMANENT "agency" live tenant             #
#                                                                              #
#  Unlike the scratch probes in scripts/verify, this provisions a stable      #
#  (tenant, API key, postgresql mount) triple for the Binocle Intelligence    #
#  Agency simulation and KEEPS it:                                            #
#    - dedicated Postgres database `agency` on the stack's own postgres       #
#    - tenant id `agency` via tenant-control (201/409 both fine)              #
#    - mbk_ API key (reused across runs when still valid)                     #
#    - adapter-registry mount `agency-db` through Kong /admin/v1/databases    #
#    - 10 case-file tables created through the REAL gateway DDL path          #
#      (POST /query/v1/<dbId>/schema/ddl) — owner_id is auto-appended         #
#    - FK constraints added via psql (the DDL contract has no FK support;     #
#      introspection picks them up so the graph gets fk_ref edges)            #
#                                                                              #
#  State lands in .agency-tenant.env next to the repo's mini-baas-infra root  #
#  so the data/policy seeders and verify gates can source it.                 #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# v1 HMAC service auth (audit O1) — signs tenant-control calls under hmac mode.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/service-auth.sh"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_ENV="${INFRA_ROOT}/.agency-tenant.env"
PG_CTN="mini-baas-postgres"
AGENCY_DB="agency"
MOUNT_NAME="agency-db"
TENANT_SLUG="agency"

cyan() { printf '\033[0;36m[agency-tenant] %s\033[0m\n' "$*"; }
fail() { printf '\033[0;31m[agency-tenant] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# shellcheck source=../verify/lib-live-tenant.sh
source "${SCRIPT_DIR}/../verify/lib-live-tenant.sh"

# ── 0) endpoints + secrets from the running stack ────────────────────────────
kong_port="$(_lt_host_port mini-baas-kong 8000/tcp)"
tc_port="$(_lt_host_port mini-baas-tenant-control 3022/tcp)"
[[ -n "${kong_port}" && -n "${tc_port}" ]] || fail "mini-baas stack not running (kong/tenant-control ports)"
KONG_URL="http://127.0.0.1:${kong_port}"
TC_URL="http://127.0.0.1:${tc_port}"
SERVICE_TOKEN="$(_lt_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
ANON_KEY="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
SERVICE_KEY="$(_lt_env mini-baas-kong KONG_SERVICE_API_KEY)"
[[ -n "${SERVICE_TOKEN}" && -n "${ANON_KEY}" && -n "${SERVICE_KEY}" ]] || fail "stack secrets not found"
PG_USER="$(_lt_env "${PG_CTN}" POSTGRES_USER)"; PG_USER="${PG_USER:-postgres}"
PG_PASS="$(_lt_env "${PG_CTN}" POSTGRES_PASSWORD)"; PG_PASS="${PG_PASS:-postgres}"

# ── 1) dedicated database ─────────────────────────────────────────────────────
cyan "ensuring database '${AGENCY_DB}' on ${PG_CTN}"
docker exec "${PG_CTN}" psql -U "${PG_USER}" -d postgres -tc \
  "SELECT 1 FROM pg_database WHERE datname='${AGENCY_DB}'" | grep -q 1 \
  || docker exec "${PG_CTN}" psql -U "${PG_USER}" -d postgres -c "CREATE DATABASE ${AGENCY_DB}" >/dev/null

# ── 2) tenant ─────────────────────────────────────────────────────────────────
cyan "ensuring tenant '${TENANT_SLUG}'"
atbody="{\"id\":\"${TENANT_SLUG}\",\"name\":\"Binocle Intelligence Agency\"}"
svc_auth POST /v1/tenants "${atbody}"
code=$(curl -s -o /tmp/agency-tenant.json -w '%{http_code}' -X POST "${TC_URL}/v1/tenants" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' \
  -d "${atbody}")
[[ "${code}" == "201" || "${code}" == "409" ]] || fail "tenant create (${code}): $(cat /tmp/agency-tenant.json)"

# ── 3) API key — reuse a still-valid key from a previous run ─────────────────
API_KEY=""; KEY_ID=""; DB_ID=""
if [[ -f "${STATE_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_ENV}"
  API_KEY="${AGENCY_API_KEY:-}"; KEY_ID="${AGENCY_KEY_ID:-}"; DB_ID="${AGENCY_DB_ID:-}"
fi
key_ok=0
if [[ -n "${API_KEY}" && -n "${DB_ID}" ]]; then
  probe=$(curl -s -o /dev/null -w '%{http_code}' "${KONG_URL}/query/v1/${DB_ID}/schema" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}")
  [[ "${probe}" == "200" ]] && key_ok=1
fi
if [[ "${key_ok}" == "1" ]]; then
  cyan "reusing existing key + mount (${DB_ID})"
else
  cyan "minting API key"
  akbody='{"name":"agency-app","scopes":["read","write"]}'
  svc_auth POST "/v1/tenants/${TENANT_SLUG}/keys" "${akbody}"
  code=$(curl -s -o /tmp/agency-key.json -w '%{http_code}' -X POST \
    "${TC_URL}/v1/tenants/${TENANT_SLUG}/keys" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' \
    -d "${akbody}")
  [[ "${code}" == "201" ]] || fail "key mint (${code}): $(cat /tmp/agency-key.json)"
  API_KEY="$(_lt_json_field key < /tmp/agency-key.json)"
  KEY_ID="$(_lt_json_field id < /tmp/agency-key.json)"
  [[ "${API_KEY}" == mbk_* ]] || fail "minted key has unexpected shape"

  cyan "registering mount '${MOUNT_NAME}' → ${AGENCY_DB} database"
  code=$(curl -s -o /tmp/agency-mount.json -w '%{http_code}' -X POST \
    "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT_SLUG}" \
    -H 'Content-Type: application/json' \
    -d "{\"engine\":\"postgresql\",\"name\":\"${MOUNT_NAME}\",\"connection_string\":\"postgres://${PG_USER}:${PG_PASS}@postgres:5432/${AGENCY_DB}\"}")
  if [[ "${code}" == "201" ]]; then
    DB_ID="$(_lt_json_field id < /tmp/agency-mount.json)"
  elif [[ "${code}" == "409" && -n "${DB_ID}" ]]; then
    cyan "mount already registered, keeping ${DB_ID}"
  else
    fail "mount register (${code}): $(cat /tmp/agency-mount.json)"
  fi
  [[ -n "${DB_ID}" ]] || fail "no mount id"
fi

# ── 4) tables through the REAL gateway DDL path ──────────────────────────────
# col helper: name:type[:nullable] — nullable defaults true, id cols false
ddl_create() { # $1 table, $2.. cols "name:type[:notnull]"
  local table="$1"; shift
  local cols="" col name type notnull
  for col in "$@"; do
    IFS=':' read -r name type notnull <<<"${col}"
    [[ -n "${cols}" ]] && cols+=","
    cols+="{\"name\":\"${name}\",\"normalized_type\":\"${type}\",\"nullable\":$([[ "${notnull:-}" == "notnull" ]] && echo false || echo true),\"default\":null,\"enum_values\":null}"
  done
  curl -s -o /tmp/agency-ddl.json -w '%{http_code}' -X POST \
    "${KONG_URL}/query/v1/${DB_ID}/schema/ddl" \
    -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "{\"op\":\"create_table\",\"table\":\"${table}\",\"columns\":[${cols}],\"primary_key\":[\"id\"]}"
}

existing="$(curl -fsS "${KONG_URL}/query/v1/${DB_ID}/schema" \
  -H "apikey: ${ANON_KEY}" -H "X-Baas-Api-Key: ${API_KEY}")" || fail "schema introspection failed"

ensure_table() { # $1 table, rest cols
  local table="$1"; shift
  if echo "${existing}" | grep -q "\"name\":\"${table}\""; then
    cyan "table ${table} already exists"
    return 0
  fi
  cyan "DDL create_table ${table}"
  local code
  code=$(ddl_create "${table}" "$@")
  [[ "${code}" == "200" || "${code}" == "201" ]] || fail "create_table ${table} (${code}): $(cat /tmp/agency-ddl.json)"
  grep -q '"status":"applied"' /tmp/agency-ddl.json || fail "create_table ${table} not applied"
}

ensure_table cases \
  id:integer:notnull code:text:notnull title:text:notnull status:text:notnull \
  priority:text classification:text budget:decimal lead_investigator:text \
  client:text opened_at:datetime closed_at:datetime summary:text
ensure_table subjects \
  id:integer:notnull case_id:integer full_name:text:notnull alias:text \
  ssn:text nationality:text risk_level:text occupation:text \
  date_of_birth:date notes:text
ensure_table locations \
  id:integer:notnull label:text:notnull kind:text address:text city:text \
  country:text lat:float lng:float surveillance_active:boolean
ensure_table evidence \
  id:integer:notnull case_id:integer:notnull kind:text:notnull description:text \
  chain_of_custody:text storage_location_id:integer collected_by:text \
  collected_at:datetime integrity_verified:boolean
ensure_table leads \
  id:integer:notnull case_id:integer:notnull subject_id:integer source:text \
  credibility:text status:text detail:text received_at:datetime
ensure_table transactions \
  id:integer:notnull subject_id:integer:notnull amount:decimal:notnull currency:text \
  counterparty:text account_ref:text flagged:boolean executed_at:datetime method:text
ensure_table vehicles \
  id:integer:notnull owner_subject_id:integer plate:text:notnull make:text \
  model:text color:text year:integer last_seen_location_id:integer
ensure_table communications \
  id:integer:notnull subject_id:integer:notnull channel:text:notnull \
  counterparty:text intercepted_at:datetime summary:text classification:text \
  case_id:integer
ensure_table reports \
  id:integer:notnull case_id:integer:notnull title:text:notnull author:text \
  status:text classification:text published_at:datetime body:text
ensure_table assignments \
  id:integer:notnull case_id:integer:notnull employee_email:text:notnull \
  role_on_case:text hours:float hourly_rate:decimal started_at:date active:boolean

# ── 5) edges table via psql ("from"/"to" are SQL keywords the DDL path would
#       mangle; the graph service's PRIMARY edge source reads these columns) ──
cyan "ensuring edges table (graph primary edge source)"
docker exec -i "${PG_CTN}" psql -U "${PG_USER}" -d "${AGENCY_DB}" -v ON_ERROR_STOP=1 -q <<'SQL'
CREATE TABLE IF NOT EXISTS public.edges (
  id        INTEGER PRIMARY KEY,
  "from"    TEXT NOT NULL,
  "to"      TEXT NOT NULL,
  type      TEXT NOT NULL DEFAULT 'linked',
  label     TEXT,
  directed  BOOLEAN NOT NULL DEFAULT TRUE,
  owner_id  TEXT
);
SQL

# ── 6) FK constraints via psql (DDL contract carries no FK clauses) ──────────
cyan "adding FK constraints (introspection → graph fk_ref edges)"
docker exec -i "${PG_CTN}" psql -U "${PG_USER}" -d "${AGENCY_DB}" -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
DECLARE
  fk RECORD;
BEGIN
  FOR fk IN
    SELECT * FROM (VALUES
      ('subjects',       'subjects_case_fk',        'case_id',              'cases'),
      ('evidence',       'evidence_case_fk',        'case_id',              'cases'),
      ('evidence',       'evidence_location_fk',    'storage_location_id',  'locations'),
      ('leads',          'leads_case_fk',           'case_id',              'cases'),
      ('leads',          'leads_subject_fk',        'subject_id',           'subjects'),
      ('transactions',   'transactions_subject_fk', 'subject_id',           'subjects'),
      ('vehicles',       'vehicles_subject_fk',     'owner_subject_id',     'subjects'),
      ('vehicles',       'vehicles_location_fk',    'last_seen_location_id','locations'),
      ('communications', 'communications_subject_fk','subject_id',          'subjects'),
      ('communications', 'communications_case_fk',  'case_id',              'cases'),
      ('reports',        'reports_case_fk',         'case_id',              'cases'),
      ('assignments',    'assignments_case_fk',     'case_id',              'cases')
    ) AS t(tbl, conname, col, reftbl)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = fk.conname) THEN
      EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES public.%I(id)',
                     fk.tbl, fk.conname, fk.col, fk.reftbl);
    END IF;
  END LOOP;
END $$;
SQL

# ── 7) persist state ──────────────────────────────────────────────────────────
cat > "${STATE_ENV}" <<EOF
# generated by scripts/seed/agency-tenant.sh — $(date -Iseconds)
AGENCY_TENANT_SLUG=${TENANT_SLUG}
AGENCY_API_KEY=${API_KEY}
AGENCY_KEY_ID=${KEY_ID}
AGENCY_DB_ID=${DB_ID}
AGENCY_DB_NAME=${AGENCY_DB}
AGENCY_KONG_URL=${KONG_URL}
AGENCY_ANON_APIKEY=${ANON_KEY}
AGENCY_SERVICE_APIKEY=${SERVICE_KEY}
EOF
cyan "DONE: tenant=${TENANT_SLUG} mount=${DB_ID} (state → ${STATE_ENV})"
