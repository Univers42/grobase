#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m136-abac-conditions.sh                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M136 — FINE-GRAINED ABAC (B2): the stored policy CONDITIONS JSONB actually
# EVALUATES. Migration 063 adds auth.eval_conditions + a has_permission overload
# with DEFAULTed (p_attrs, p_conditions_enabled, p_resource_id). This gate proves:
#
#   1. BYTE-PARITY / the ambiguity fix — there is EXACTLY ONE has_permission
#      overload after 063 (063 DROPs the 007 4-arg version) and a 4-arg call
#      RESOLVES (not "function ... is not unique") and returns the 007 result.
#      Leaving both overloads would make every existing 4-arg caller ambiguous —
#      flag-OFF would be BROKEN, not parity. This arm is the regression guard.
#   2. conditions OFF (default) ⇒ the conditions JSONB is IGNORED (007 behavior).
#   3. conditions ON, a conditional ALLOW whose ip_cidr does NOT match ⇒ no grant.
#   4. conditions ON, ip_cidr matches ⇒ grant.
#   5. a conditional DENY that does NOT apply is SKIPPED (does not block); one
#      that DOES apply blocks (deny-wins among applicable policies).
#
# NON-VACUITY: arms 2 vs 3 use the SAME policy and user, flipping only
# p_conditions_enabled — the flag is the only difference, so a no-op evaluator
# can't pass both. Arm 1 fails on the pre-fix migration (two overloads).
#
# ISOLATED: scratch postgres (prelude + REAL 007 + 063); name suffixed $$,
# EXIT-trap removes it. Never touches a mini-baas-* resource.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
DEC="${INFRA_DIR}/src/apps/permission-engine/src/decisions/decisions.service.ts"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M136] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M136] FAIL — $*"
  exit 1
}

PG_IMAGE="${M136_PG_IMAGE:-postgres:16-alpine}"
PG="m136-pg-$$"
cleanup() { docker rm -fv "${PG}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
hp() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>&1 | tr -d '[:space:]'; } # keeps errors visible
apply() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

# ── 1) static contract ─────────────────────────────────────────────────────────
step "1/4 static contract — PDP passes p_conditions_enabled gated by the flag"
[[ -f "${MIG_DIR}/063_permission_conditions.sql" ]] || fail "migration 063 missing"
grep -q "auth.eval_conditions" "${MIG_DIR}/063_permission_conditions.sql" || fail "063 missing auth.eval_conditions"
grep -q "DROP FUNCTION IF EXISTS public.has_permission(UUID, TEXT, TEXT, TEXT)" "${MIG_DIR}/063_permission_conditions.sql" ||
  fail "063 does not DROP the 4-arg has_permission — 4-arg callers would be AMBIGUOUS (flag-OFF broken, not parity)"
grep -q "PERMISSION_CONDITIONS_ENABLED" "${DEC}" || fail "DecisionsService never reads PERMISSION_CONDITIONS_ENABLED"
grep -q "p_conditions_enabled\|conditionsEnabled" "${DEC}" || fail "DecisionsService never passes the conditions flag to has_permission"
ok "eval_conditions + 4-arg DROP + flag wiring present"

# ── 2) boot scratch postgres + REAL 007 + 063 ──────────────────────────────────
step "2/4 boot scratch postgres + apply REAL 007 + 063"
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

# ── 3) ambiguity fix / byte-parity ─────────────────────────────────────────────
step "3/4 4-arg has_permission resolves (regression guard for the overload-drop)"
N="$(val "SELECT count(*) FROM pg_proc WHERE proname='has_permission'")"
[[ "${N}" == "1" ]] || fail "expected exactly 1 has_permission overload, got ${N} — 4-arg callers would be ambiguous"
U="22222222-2222-4222-8222-222222222222"
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
INSERT INTO public.roles (name, is_system) VALUES ('m136:demo', true) ON CONFLICT (name) DO NOTHING;
INSERT INTO public.user_roles (user_id, role_id) SELECT '${U}'::uuid, id FROM public.roles WHERE name='m136:demo' ON CONFLICT DO NOTHING;
-- conditional ALLOW on audit_events: only from 10.0.0.0/8
INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
  SELECT id,'postgresql','audit_events',ARRAY['select'], jsonb_build_object('ip_cidr', jsonb_build_array('10.0.0.0/8')),'allow',10 FROM public.roles WHERE name='m136:demo';
SQL
R4="$(hp "SELECT public.has_permission('${U}'::uuid,'postgresql','audit_events','select')")"
[[ "${R4}" == "t" ]] || fail "4-arg call did not resolve to the 007 result (got [${R4}]) — ambiguity not fixed"
ok "exactly 1 overload; 4-arg call resolves + allows (byte-parity with 007)"

# ── 4) conditions evaluate (the new behavior) ──────────────────────────────────
step "4/4 conditions OFF=parity; ON gates allow/deny; conditional deny skip"
P() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (got [$2] want [$3])"; }
P "conditions OFF ⇒ ALLOW (ignores ip_cidr, 007 parity)" \
  "$(val "SELECT public.has_permission('${U}'::uuid,'postgresql','audit_events','select','{}'::jsonb,false)")" "t"
P "conditions ON, ip 8.8.8.8 OUT of cidr ⇒ DENY" \
  "$(val "SELECT public.has_permission('${U}'::uuid,'postgresql','audit_events','select','{\"ip\":\"8.8.8.8\"}'::jsonb,true)")" "f"
P "conditions ON, ip 10.1.2.3 IN cidr ⇒ ALLOW" \
  "$(val "SELECT public.has_permission('${U}'::uuid,'postgresql','audit_events','select','{\"ip\":\"10.1.2.3\"}'::jsonb,true)")" "t"

D="33333333-3333-4333-8333-333333333333"
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
INSERT INTO public.roles (name, is_system) VALUES ('m136:deny', true) ON CONFLICT (name) DO NOTHING;
INSERT INTO public.user_roles (user_id, role_id) SELECT '${D}'::uuid, id FROM public.roles WHERE name='m136:deny' ON CONFLICT DO NOTHING;
INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
  SELECT id,'postgresql','docs',ARRAY['select'],'{}'::jsonb,'allow',0 FROM public.roles WHERE name='m136:deny';
INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
  SELECT id,'postgresql','docs',ARRAY['select'], jsonb_build_object('ip_cidr', jsonb_build_array('192.168.0.0/16')),'deny',100 FROM public.roles WHERE name='m136:deny';
SQL
P "conditional DENY not applicable (ip outside) ⇒ SKIPPED ⇒ ALLOW" \
  "$(val "SELECT public.has_permission('${D}'::uuid,'postgresql','docs','select','{\"ip\":\"10.1.2.3\"}'::jsonb,true)")" "t"
P "conditional DENY applicable (ip inside) ⇒ DENY wins" \
  "$(val "SELECT public.has_permission('${D}'::uuid,'postgresql','docs','select','{\"ip\":\"192.168.1.1\"}'::jsonb,true)")" "f"

green "[M136] PASS — stored conditions evaluate (ip_cidr); flag OFF=parity; conditional deny skip; ambiguity fixed"
