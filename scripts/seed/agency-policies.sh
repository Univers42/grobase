#!/usr/bin/env bash
# **************************************************************************** #
#  agency-policies.sh — ABAC roles + policies for the Binocle agency           #
#                                                                              #
#  Seeds the permission-engine store (migration 007 tables in the mini-baas   #
#  postgres) with the agency role model:                                      #
#    - 11 roles, slug-namespaced `agency:*` (Go EnsureRole discipline),       #
#      attributes (department / clearance / region) in roles.metadata         #
#    - user_roles for the owner + 20 employees from tools/seeds/              #
#      .agency-people.env                                                     #
#    - resource_policies per table with attribute-flavoured field masks:      #
#        analyst        → transactions.amount redacted '***'                  #
#        clearance < 3  → subjects.ssn hidden, cases.budget redacted          #
#        non-finance    → assignments.hourly_rate redacted '—'                #
#        guest          → explicit deny on evidence + communications          #
#                                                                              #
#  Idempotent: roles upsert on name; agency:* policies are replaced           #
#  wholesale each run (they are the only policies this script owns).          #
#                                                                              #
#  osionos AbacEngine note: workspace-level defaults ride on its built-in     #
#  role fallback (owner/admin/member/guest); explicit page rules are seeded   #
#  by the share-dialog workstream, not here.                                  #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
PEOPLE_ENV="${REPO_ROOT}/tools/seeds/.agency-people.env"
PG_CTN="mini-baas-postgres"

cyan() { printf '\033[0;36m[agency-policies] %s\033[0m\n' "$*"; }
fail() { printf '\033[0;31m[agency-policies] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "${PEOPLE_ENV}" ]] || fail "missing ${PEOPLE_ENV} (run seed_agency_people.sh first)"
docker inspect "${PG_CTN}" >/dev/null 2>&1 || fail "${PG_CTN} not running"

PSQL() { docker exec -i "${PG_CTN}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }

# ── roles + metadata ──────────────────────────────────────────────────────────
cyan "upserting 11 agency:* roles"
PSQL <<'SQL'
INSERT INTO public.roles (name, description, is_system, metadata) VALUES
  ('agency:director',            'Agency director — full authority',                false, '{"department":"command","clearance":5,"org":"agency"}'),
  ('agency:deputy_director',     'Deputy director — full authority',                false, '{"department":"command","clearance":5,"org":"agency"}'),
  ('agency:case_manager',        'Case manager — runs case operations',             false, '{"department":"operations","clearance":4,"org":"agency"}'),
  ('agency:senior_investigator', 'Senior investigator — case work, no finance',     false, '{"department":"investigations","clearance":4,"org":"agency"}'),
  ('agency:field_agent',         'Field agent — collection, low clearance',         false, '{"department":"investigations","clearance":2,"org":"agency"}'),
  ('agency:analyst',             'Intelligence analyst — reads all, masked finance',false, '{"department":"analysis","clearance":3,"org":"agency"}'),
  ('agency:forensics',           'Forensics — evidence custody',                    false, '{"department":"forensics","clearance":3,"org":"agency"}'),
  ('agency:surveillance',        'Surveillance — comms & locations, low clearance', false, '{"department":"surveillance","clearance":2,"org":"agency"}'),
  ('agency:legal',               'Legal counsel — review access',                   false, '{"department":"legal","clearance":3,"org":"agency"}'),
  ('agency:accountant',          'Accountant — finance only',                       false, '{"department":"finance","clearance":3,"org":"agency"}'),
  ('agency:it_admin',            'IT admin — systems, least data access',           false, '{"department":"it","clearance":4,"org":"agency"}')
ON CONFLICT (name) DO UPDATE SET
  description = EXCLUDED.description, metadata = EXCLUDED.metadata, updated_at = now();
SQL

# ── user → role assignments from the roster ───────────────────────────────────
cyan "assigning roles to the 21 roster members"
{
  echo "BEGIN;"
  grep "^AGENCY_PERSON_[0-9]" "${PEOPLE_ENV}" | while IFS='=' read -r _key value; do
    IFS='|' read -r uuid _email _name role _dept _clr _region _ws_role <<<"${value}"
    cat <<SQL
INSERT INTO public.user_roles (user_id, role_id)
SELECT '${uuid}'::uuid, r.id FROM public.roles r WHERE r.name = 'agency:${role}'
ON CONFLICT (user_id, role_id) DO NOTHING;
SQL
  done
  echo "COMMIT;"
} | PSQL

# ── policy matrix (agency:* policies replaced wholesale — we own them) ───────
cyan "writing the resource policy matrix (+ field masks)"
PSQL >/dev/null <<'SQL'
BEGIN;
DELETE FROM public.resource_policies
 WHERE role_id IN (SELECT id FROM public.roles WHERE name LIKE 'agency:%');

CREATE FUNCTION pg_temp.pol(
  p_role TEXT, p_resource TEXT, p_actions TEXT[],
  p_effect TEXT, p_priority INT, p_conditions JSONB DEFAULT NULL
) RETURNS VOID AS $$
  INSERT INTO public.resource_policies
    (role_id, resource_type, resource_name, actions, conditions, effect, priority)
  SELECT r.id, 'table', p_resource, p_actions, p_conditions, p_effect, p_priority
    FROM public.roles r WHERE r.name = p_role;
$$ LANGUAGE SQL;

-- command: full authority on every table
SELECT pg_temp.pol('agency:director',        '*', ARRAY['select','insert','update','delete'], 'allow', 100);
SELECT pg_temp.pol('agency:deputy_director', '*', ARRAY['select','insert','update','delete'], 'allow', 100);

-- operations: everything except deleting evidence (custody integrity)
SELECT pg_temp.pol('agency:case_manager', '*',        ARRAY['select','insert','update','delete'], 'allow', 80);
SELECT pg_temp.pol('agency:case_manager', 'evidence', ARRAY['delete'],                            'deny',  90);

-- senior investigators: full case work, read-only finance, rates masked
SELECT pg_temp.pol('agency:senior_investigator', '*',            ARRAY['select','insert','update'], 'allow', 70);
SELECT pg_temp.pol('agency:senior_investigator', 'transactions', ARRAY['insert','update','delete'], 'deny',  80);
SELECT pg_temp.pol('agency:senior_investigator', 'assignments',  ARRAY['select'],                   'allow', 75,
  '{"mask":{"redact":{"hourly_rate":"—"}}}');

-- field agents (clearance 2): collection surfaces; no finance/comms;
-- subjects ssn hidden, case budgets redacted
SELECT pg_temp.pol('agency:field_agent', 'cases',     ARRAY['select'],                   'allow', 70,
  '{"mask":{"redact":{"budget":"***"}}}');
SELECT pg_temp.pol('agency:field_agent', 'subjects',  ARRAY['select'],                   'allow', 70,
  '{"mask":{"hide":["ssn"]}}');
SELECT pg_temp.pol('agency:field_agent', 'leads',     ARRAY['select','insert','update'], 'allow', 70);
SELECT pg_temp.pol('agency:field_agent', 'evidence',  ARRAY['select','insert'],          'allow', 70);
SELECT pg_temp.pol('agency:field_agent', 'locations', ARRAY['select','insert','update'], 'allow', 70);
SELECT pg_temp.pol('agency:field_agent', 'vehicles',  ARRAY['select','insert','update'], 'allow', 70);
SELECT pg_temp.pol('agency:field_agent', 'assignments',   ARRAY['select'], 'allow', 70,
  '{"mask":{"redact":{"hourly_rate":"—"}}}');
SELECT pg_temp.pol('agency:field_agent', 'transactions',   ARRAY['select','insert','update','delete'], 'deny', 90);
SELECT pg_temp.pol('agency:field_agent', 'communications', ARRAY['select','insert','update','delete'], 'deny', 90);

-- analysts (clearance 3): read everything, write reports/leads;
-- transaction amounts redacted, rates masked
SELECT pg_temp.pol('agency:analyst', '*',            ARRAY['select'],                   'allow', 70);
SELECT pg_temp.pol('agency:analyst', 'transactions', ARRAY['select'],                   'allow', 75,
  '{"mask":{"redact":{"amount":"***"}}}');
SELECT pg_temp.pol('agency:analyst', 'assignments',  ARRAY['select'],                   'allow', 75,
  '{"mask":{"redact":{"hourly_rate":"—"}}}');
SELECT pg_temp.pol('agency:analyst', 'reports',      ARRAY['insert','update'],          'allow', 70);
SELECT pg_temp.pol('agency:analyst', 'leads',        ARRAY['insert','update'],          'allow', 70);

-- forensics: evidence custody + case context
SELECT pg_temp.pol('agency:forensics', 'evidence', ARRAY['select','insert','update'], 'allow', 70);
SELECT pg_temp.pol('agency:forensics', 'cases',    ARRAY['select'],                   'allow', 70);
SELECT pg_temp.pol('agency:forensics', 'subjects', ARRAY['select'],                   'allow', 70);
SELECT pg_temp.pol('agency:forensics', 'reports',  ARRAY['select','insert','update'], 'allow', 70);
SELECT pg_temp.pol('agency:forensics', 'locations',ARRAY['select'],                   'allow', 70);
SELECT pg_temp.pol('agency:forensics', 'transactions', ARRAY['select','insert','update','delete'], 'deny', 90);

-- surveillance (clearance 2): comms + movement surfaces; no finance
SELECT pg_temp.pol('agency:surveillance', 'communications', ARRAY['select','insert'],          'allow', 70);
SELECT pg_temp.pol('agency:surveillance', 'locations',      ARRAY['select','insert','update'], 'allow', 70);
SELECT pg_temp.pol('agency:surveillance', 'vehicles',       ARRAY['select','insert','update'], 'allow', 70);
SELECT pg_temp.pol('agency:surveillance', 'subjects',       ARRAY['select'],                   'allow', 70,
  '{"mask":{"hide":["ssn"]}}');
SELECT pg_temp.pol('agency:surveillance', 'cases',          ARRAY['select'],                   'allow', 70,
  '{"mask":{"redact":{"budget":"***"}}}');
SELECT pg_temp.pol('agency:surveillance', 'transactions',   ARRAY['select','insert','update','delete'], 'deny', 90);

-- legal: review-only on the case record; privileged comms stay out of reach
SELECT pg_temp.pol('agency:legal', 'cases',       ARRAY['select'], 'allow', 70);
SELECT pg_temp.pol('agency:legal', 'subjects',    ARRAY['select'], 'allow', 70);
SELECT pg_temp.pol('agency:legal', 'evidence',    ARRAY['select'], 'allow', 70);
SELECT pg_temp.pol('agency:legal', 'reports',     ARRAY['select'], 'allow', 70);
SELECT pg_temp.pol('agency:legal', 'assignments', ARRAY['select'], 'allow', 70);
SELECT pg_temp.pol('agency:legal', 'communications', ARRAY['select','insert','update','delete'], 'deny', 90);
SELECT pg_temp.pol('agency:legal', 'transactions',   ARRAY['select','insert','update','delete'], 'deny', 90);

-- accountant: finance surfaces only (rates and amounts unmasked — their job)
SELECT pg_temp.pol('agency:accountant', 'transactions', ARRAY['select','insert','update'], 'allow', 70);
SELECT pg_temp.pol('agency:accountant', 'assignments',  ARRAY['select','insert','update'], 'allow', 70);
SELECT pg_temp.pol('agency:accountant', 'cases',        ARRAY['select'],                   'allow', 70);
SELECT pg_temp.pol('agency:accountant', 'subjects',       ARRAY['select','insert','update','delete'], 'deny', 90);
SELECT pg_temp.pol('agency:accountant', 'evidence',       ARRAY['select','insert','update','delete'], 'deny', 90);
SELECT pg_temp.pol('agency:accountant', 'communications', ARRAY['select','insert','update','delete'], 'deny', 90);

-- it_admin: least data access — case index + reports only
SELECT pg_temp.pol('agency:it_admin', 'cases',   ARRAY['select'], 'allow', 70);
SELECT pg_temp.pol('agency:it_admin', 'reports', ARRAY['select'], 'allow', 70);

COMMIT;
SQL

# ── guest deny demo (system role — additive, owned policies tagged by name) ──
cyan "ensuring guest deny policies on evidence + communications"
PSQL <<'SQL'
INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
SELECT r.id, 'table', t.tbl, ARRAY['select','insert','update','delete'], '{"org":"agency"}'::jsonb, 'deny', 100
  FROM public.roles r, (VALUES ('evidence'), ('communications')) AS t(tbl)
 WHERE r.name = 'guest'
   AND NOT EXISTS (
     SELECT 1 FROM public.resource_policies rp
      WHERE rp.role_id = r.id AND rp.resource_type = 'table'
        AND rp.resource_name = t.tbl AND rp.effect = 'deny');
SQL

ROLES=$(PSQL -At -c "SELECT count(*) FROM public.roles WHERE name LIKE 'agency:%'" </dev/null)
ASSIGNS=$(PSQL -At -c "SELECT count(*) FROM public.user_roles ur JOIN public.roles r ON r.id=ur.role_id WHERE r.name LIKE 'agency:%'" </dev/null)
POLS=$(PSQL -At -c "SELECT count(*) FROM public.resource_policies rp JOIN public.roles r ON r.id=rp.role_id WHERE r.name LIKE 'agency:%'" </dev/null)
cyan "DONE: ${ROLES} roles, ${ASSIGNS} assignments, ${POLS} agency policies"
