#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    osionos-collaborators.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/25 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/25 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Seed a shared "work" (an osionos workspace) plus collaborators that AUTO-CONNECT
# to its databases through workspace membership — the multi-engine access model:
# members of the shared workspace see its associated mounts (commerce/ops/activity
# + any extra engine ids passed in); a non-member sees nothing. Idempotent.
#
# WHO  = gotrue users (alice/bob/carol = members; dave = non-member control).
# WORK = workspace 'Acme Operations' (deterministic uuid), owned by dev.pro.photo.
# WHICH= osionos_workspace_databases rows linking the work to each mount.
#
# Usage: bash osionos-collaborators.sh [PG_DB_ID] [MY_DB_ID] [MG_DB_ID] [extra dbId:engine:label:tables,csv ...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

cyan() { printf '\033[0;36m[collab] %s\033[0m\n' "$*"; }
pass() { printf '\033[0;32m[collab] %s\033[0m\n' "$*"; }
fail() { printf '\033[0;31m[collab] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

KONG_PORT="$(_lt_host_port mini-baas-kong 8000/tcp)"
[[ -n "${KONG_PORT}" ]] || fail "mini-baas-kong not mapped — bring the stack up"
KONG_URL="http://127.0.0.1:${KONG_PORT}"
ANON="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
SVC="$(_lt_env mini-baas-kong KONG_SERVICE_API_KEY)"
[[ -n "${ANON}" && -n "${SVC}" ]] || fail "kong anon/service keys not found"

PG_CTN="mini-baas-postgres"
PSQL() { docker exec -i "${PG_CTN}" psql -U postgres -d postgres -tAc "$1"; }

SHARED_WS="ac3e0000-0000-4000-a000-000000000001"   # "Acme Operations" (deterministic)
OWNER_USER="5cc30a3f-87e4-471d-b795-c936723081ee"  # dev.pro.photo owns the work
PASSWORD="${COLLAB_PASSWORD:-Acme#2026}"
PG_DB_ID="${1:-59939f19-7e8d-4876-a57f-61b3e7bb37be}"
MY_DB_ID="${2:-028b32b2-78f2-405f-81e3-fa690c4649dc}"
MG_DB_ID="${3:-42c85133-c805-40c5-a260-04251834a337}"

# A gotrue identity per collaborator (idempotent: create, else find by email).
mk_user() { # $1 email → echoes gotrue id
  local code
  code=$(curl -s -o /tmp/oc.json -w '%{http_code}' -X POST "${KONG_URL}/auth/v1/admin/users" \
    -H "apikey: ${ANON}" -H "Authorization: Bearer ${SVC}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"${PASSWORD}\",\"email_confirm\":true}")
  if [[ "${code}" == "200" || "${code}" == "201" ]]; then
    _lt_json_field id </tmp/oc.json
  else
    curl -s -o /tmp/ocl.json "${KONG_URL}/auth/v1/admin/users?per_page=2000" \
      -H "apikey: ${ANON}" -H "Authorization: Bearer ${SVC}" || true
    EMAIL="$1" python3 -c 'import json,os;d=json.load(open("/tmp/ocl.json"));print(next((u["id"] for u in d.get("users",[]) if u.get("email")==os.environ["EMAIL"]),""))' 2>/dev/null
  fi
}

cyan "creating collaborator identities (password '${PASSWORD}')"
ALICE="$(mk_user alice@acme.test)"
BOB="$(mk_user bob@acme.test)"
CAROL="$(mk_user carol@acme.test)"
DAVE="$(mk_user dave@acme.test)"
[[ -n "${ALICE}" && -n "${BOB}" && -n "${CAROL}" && -n "${DAVE}" ]] || fail "gotrue user creation failed"
pass "alice=${ALICE} bob=${BOB} carol=${CAROL} dave=${DAVE} (dave = non-member control)"

cyan "creating the shared work 'Acme Operations' (${SHARED_WS})"
PSQL "INSERT INTO public.osionos_workspaces (id, owner_id, name, slug, visibility)
      VALUES ('${SHARED_WS}','${OWNER_USER}','Acme Operations','acme-operations','confidential')
      ON CONFLICT (id) DO NOTHING" >/dev/null

cyan "adding members (owner + alice/bob/carol; NOT dave)"
for uid in "${OWNER_USER}" "${ALICE}" "${BOB}" "${CAROL}"; do
  PSQL "INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions)
        VALUES ('${SHARED_WS}','${uid}','editor', ARRAY['read','write'])
        ON CONFLICT (workspace_id, user_id) DO NOTHING" >/dev/null
done

cyan "associating the work with its databases (a member joining the work auto-connects)"
PSQL "INSERT INTO public.osionos_workspace_databases (workspace_id, db_id, engine, tables, edges_table, label) VALUES
   ('${SHARED_WS}','${PG_DB_ID}','postgresql', ARRAY['customers','products','employees','inventory','orders','order_items'], 'edges', 'Commerce · Postgres'),
   ('${SHARED_WS}','${MY_DB_ID}','mysql', ARRAY['projects','tasks','tickets','time_entries'], NULL, 'Ops · MySQL'),
   ('${SHARED_WS}','${MG_DB_ID}','mongodb', ARRAY['events','product_reviews','notes'], NULL, 'Activity · Mongo')
   ON CONFLICT (workspace_id, db_id) DO UPDATE SET tables=excluded.tables, edges_table=excluded.edges_table, engine=excluded.engine, label=excluded.label, updated_at=now()" >/dev/null

# Extra engines (SQLite/MSSQL/DynamoDB) passed as dbId:engine:label:t1,t2,...
shift 3 2>/dev/null || true
for spec in "$@"; do
  IFS=':' read -r xid xengine xlabel xtables <<<"${spec}"
  [[ -n "${xid}" && -n "${xengine}" ]] || continue
  arr="ARRAY[$(echo "${xtables}" | sed "s/,/','/g; s/^/'/; s/$/'/")]"
  PSQL "INSERT INTO public.osionos_workspace_databases (workspace_id, db_id, engine, tables, label)
        VALUES ('${SHARED_WS}','${xid}','${xengine}', ${arr}, '${xlabel}')
        ON CONFLICT (workspace_id, db_id) DO UPDATE SET tables=excluded.tables, engine=excluded.engine, label=excluded.label, updated_at=now()" >/dev/null
  cyan "  + associated extra mount ${xlabel} (${xengine})"
done

NDB="$(PSQL "SELECT count(*) FROM public.osionos_workspace_databases WHERE workspace_id='${SHARED_WS}'" | tr -d '[:space:]')"
NMEM="$(PSQL "SELECT count(*) FROM public.osionos_workspace_members WHERE workspace_id='${SHARED_WS}'" | tr -d '[:space:]')"
pass "DONE: work has ${NMEM} members + ${NDB} databases. Members: dev.pro.photo + alice/bob/carol. Control: dave (none)."
echo "COLLAB_ALICE=${ALICE}"
echo "COLLAB_DAVE=${DAVE}"
echo "COLLAB_SHARED_WS=${SHARED_WS}"
