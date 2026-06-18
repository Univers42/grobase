#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m137-abac-per-instance.sh                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M137 — FINE-GRAINED ABAC (B3): PER-TABLE and PER-INSTANCE granularity.
# Per-table already works via exact resource_name matching (proven in m135's
# mask tiebreak). This gate proves PER-INSTANCE: a policy whose conditions carry
# resource_id / resource_id_in decides on the specific row id the caller acts on
# (query.service.ts resourceIdFromFilter(dto.filter) → DecidePermissionDto
# .resource_id → has_permission p_resource_id, folded into attrs).
#
#   resource_id 'row-42' allow  +  p_resource_id='row-42' ⇒ ALLOW
#                                    p_resource_id='row-99' ⇒ DENY
#   resource_id_in [a,b]        +  'b' ⇒ ALLOW ; 'c' ⇒ DENY
#   resource_id passed via attrs (not the column arg) ⇒ ALLOW (the fold)
#
# NON-VACUITY: same policy/user, only the resource_id changes between the ALLOW
# and DENY arms — a no-op evaluator cannot pass both. Static arm fails if the
# resource_id plumbing (dto field / resourceIdFromFilter) is removed.
#
# ISOLATED: scratch postgres (prelude + REAL 007 + 063); $$ suffix + EXIT-trap.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
DTO="${INFRA_DIR}/src/apps/permission-engine/src/decisions/dto/decision.dto.ts"
QRY="${INFRA_DIR}/src/apps/query-router/src/query/query.service.ts"
DEC="${INFRA_DIR}/src/apps/permission-engine/src/decisions/decisions.service.ts"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M137] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M137] FAIL — $*"
  exit 1
}

PG_IMAGE="${M137_PG_IMAGE:-postgres:16-alpine}"
PG="m137-pg-$$"
cleanup() { docker rm -fv "${PG}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
apply() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

# ── 1) static contract: per-instance plumbing ──────────────────────────────────
step "1/3 static contract — resource_id dto field + resourceIdFromFilter + fold"
[[ -f "${MIG_DIR}/063_permission_conditions.sql" ]] || fail "migration 063 missing"
grep -q "resource_id" "${DTO}" || fail "DecidePermissionDto lost the resource_id field"
grep -q "resourceIdFromFilter" "${QRY}" || fail "QueryService lost resourceIdFromFilter (per-instance subject)"
grep -q "p_resource_id\|resource_id" "${DEC}" || fail "DecisionsService never forwards resource_id to has_permission"
grep -q "p_resource_id" "${MIG_DIR}/063_permission_conditions.sql" || fail "063 has_permission missing p_resource_id arg"
ok "resource_id plumbed dto → query-router → PDP → has_permission"

# ── 2) boot scratch postgres + REAL 007 + 063 ──────────────────────────────────
step "2/3 boot scratch postgres + apply REAL 007 + 063"
docker run -d --name "${PG}" -e POSTGRES_PASSWORD=postgres "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state"
  sleep 0.5
done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), email text);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT NULLIF(current_setting('app.current_user_id', true),'')::uuid $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $r$;
SQL
apply "${MIG_DIR}/007_permissions_system.sql" || fail "migration 007 failed"
apply "${MIG_DIR}/063_permission_conditions.sql" || fail "migration 063 failed"
ok "007 + 063 applied"

# ── 3) per-instance proof ──────────────────────────────────────────────────────
step "3/3 prove per-instance resource_id / resource_id_in gating"
U="44444444-4444-4444-8444-444444444444"
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
INSERT INTO public.roles (name, is_system) VALUES ('m137:single', true), ('m137:in', true) ON CONFLICT (name) DO NOTHING;
INSERT INTO public.user_roles (user_id, role_id) SELECT '${U}'::uuid, id FROM public.roles WHERE name IN ('m137:single','m137:in') ON CONFLICT DO NOTHING;
-- exact single-instance allow
INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
  SELECT id,'postgresql','widgets',ARRAY['select'], jsonb_build_object('resource_id','row-42'),'allow',10 FROM public.roles WHERE name='m137:single';
-- instance-set allow
INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
  SELECT id,'postgresql','gadgets',ARRAY['select'], jsonb_build_object('resource_id_in', jsonb_build_array('a','b')),'allow',10 FROM public.roles WHERE name='m137:in';
SQL
P() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got [$2] want [$3])"; }
P "resource_id 'row-42' via column arg ⇒ ALLOW" \
  "$(val "SELECT public.has_permission('${U}'::uuid,'postgresql','widgets','select','{}'::jsonb,true,'row-42')")" "t"
P "resource_id 'row-99' (mismatch) ⇒ DENY" \
  "$(val "SELECT public.has_permission('${U}'::uuid,'postgresql','widgets','select','{}'::jsonb,true,'row-99')")" "f"
P "resource_id 'row-42' via attrs (the fold) ⇒ ALLOW" \
  "$(val "SELECT public.has_permission('${U}'::uuid,'postgresql','widgets','select','{\"resource_id\":\"row-42\"}'::jsonb,true)")" "t"
P "resource_id_in member 'b' ⇒ ALLOW" \
  "$(val "SELECT public.has_permission('${U}'::uuid,'postgresql','gadgets','select','{}'::jsonb,true,'b')")" "t"
P "resource_id_in non-member 'c' ⇒ DENY" \
  "$(val "SELECT public.has_permission('${U}'::uuid,'postgresql','gadgets','select','{}'::jsonb,true,'c')")" "f"
P "per-instance OFF (conditions off) ⇒ table-level ALLOW (parity)" \
  "$(val "SELECT public.has_permission('${U}'::uuid,'postgresql','widgets','select')")" "t"

green "[M137] PASS — per-instance resource_id / resource_id_in gating (table granularity via m135)"
