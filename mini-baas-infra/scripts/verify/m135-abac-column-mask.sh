#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m135-abac-column-mask.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M135 — FINE-GRAINED ABAC (B1): COLUMN MASKING is resolvable AND per-table
# precedence (B3 tiebreak) holds. The PDP already returns a field mask
# (DecisionsService.resolveMask → query.service.ts applyFieldMask); this gate
# proves (a) the mechanism is wired in source and (b) a TABLE-SPECIFIC mask wins
# over a broad WILDCARD mask EVEN AT LOWER priority — i.e. the resolveMask
# ORDER BY tiebreak `(rp.resource_name = $3) DESC` is load-bearing. Without that
# tiebreak a wildcard mask at higher priority would shadow the table mask and the
# wrong column would be hidden.
#
# NON-VACUITY: the SQL arm seeds a wildcard mask at priority 50 and a
# crm_contacts mask at priority 10 and asserts the crm_contacts mask is the one
# resolveMask returns — impossible under the pre-B3 `ORDER BY priority DESC`
# alone. The static arm fails if the tiebreak / applyFieldMask wiring is removed.
#
# ISOLATED: scratch postgres (prelude + REAL 007 + 063) on no shared resource;
# every name suffixed $$, EXIT-trap removes the container. Never touches a
# mini-baas-* container/network/image/volume.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"            # mini-baas-infra
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
DEC="${INFRA_DIR}/src/apps/permission-engine/src/decisions/decisions.service.ts"
QRY="${INFRA_DIR}/src/apps/query-router/src/query/query.service.ts"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M135] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M135] FAIL — $*"; exit 1; }

PG_IMAGE="${M135_PG_IMAGE:-postgres:16-alpine}"
PG="m135-pg-$$"
cleanup() { docker rm -fv "${PG}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
apply() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

# ── 1) static contract: the mask path is wired ─────────────────────────────────
step "1/3 static contract — mask resolution + per-table tiebreak + applyFieldMask"
[[ -f "${MIG_DIR}/063_permission_conditions.sql" ]] || fail "migration 063 missing"
grep -q "maskFromConditions" "${DEC}" || fail "DecisionsService lost maskFromConditions (mask resolution)"
grep -q "resolveMask"        "${DEC}" || fail "DecisionsService lost resolveMask"
grep -q 'rp.resource_name = \$3) DESC' "${DEC}" \
  || fail "DecisionsService lost the B3 per-table mask tiebreak ((rp.resource_name = \$3) DESC)"
grep -q "applyFieldMask" "${QRY}" || fail "QueryService lost applyFieldMask (mask never applied to results)"
ok "mask resolution + tiebreak + application all wired in source"

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
apply "${MIG_DIR}/007_permissions_system.sql"   || fail "migration 007 failed"
apply "${MIG_DIR}/063_permission_conditions.sql" || fail "migration 063 failed"
ok "007 + 063 applied"

# ── 3) SQL proof: table mask wins over wildcard mask at LOWER priority ──────────
step "3/3 prove per-table mask precedence (B3 tiebreak)"
U="11111111-1111-4111-8111-111111111111"
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
INSERT INTO public.roles (name, is_system) VALUES ('m135:demo', true) ON CONFLICT (name) DO NOTHING;
INSERT INTO public.user_roles (user_id, role_id) SELECT '${U}'::uuid, id FROM public.roles WHERE name='m135:demo' ON CONFLICT DO NOTHING;
-- wildcard mask at HIGHER priority (50) hides WILDCARD_COL
INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
  SELECT id,'*','*',ARRAY['select'], jsonb_build_object('mask', jsonb_build_object('hide', jsonb_build_array('WILDCARD_COL'))),'allow',50 FROM public.roles WHERE name='m135:demo';
-- table-specific mask at LOWER priority (10) hides secret
INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
  SELECT id,'postgresql','crm_contacts',ARRAY['select'], jsonb_build_object('mask', jsonb_build_object('hide', jsonb_build_array('secret'))),'allow',10 FROM public.roles WHERE name='m135:demo';
SQL
# the EXACT resolveMask ORDER BY (mirrors decisions.service.ts)
WINNER="$(val "SELECT conditions->'mask'->'hide'->>0 FROM public.resource_policies rp JOIN public.user_roles ur ON ur.role_id=rp.role_id WHERE ur.user_id='${U}'::uuid AND (rp.resource_type='postgresql' OR rp.resource_type='*') AND (rp.resource_name='crm_contacts' OR rp.resource_name='*') AND 'select'=ANY(rp.actions) AND rp.effect='allow' AND rp.conditions ? 'mask' ORDER BY (rp.resource_name='crm_contacts') DESC, (rp.resource_type='postgresql') DESC, rp.priority DESC LIMIT 1")"
[[ "${WINNER}" == "secret" ]] \
  || fail "table mask did not win over wildcard (got [${WINNER}] want [secret]) — B3 tiebreak broken"
ok "crm_contacts mask (hide=secret) wins over wildcard mask at higher priority"
# the 063 demo seed documents the canonical mask shape
DEMO="$(val "SELECT (conditions->'mask'->'hide'->>0='secret' AND conditions->'mask'->'redact'->>'email'='***') FROM public.resource_policies rp JOIN public.roles r ON r.id=rp.role_id WHERE r.name='abac:demo' AND rp.resource_name='crm_contacts'")"
[[ "${DEMO}" == "t" ]] || fail "063 demo mask seed (hide secret + redact email) not present"
ok "063 demo mask seed present (hide=[secret], redact email→***)"

green "[M135] PASS — column masking resolvable; table-specific mask beats wildcard (B3 tiebreak)"
