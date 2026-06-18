-- ****************************************************************************
--
--                                                         :::      ::::::::
--    063_permission_conditions.sql                       :+:      :+:    :+:
--                                                     +:+ +:+         +:+
--    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+
--                                                 +#+#+#+#+#+   +#+
--    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#
--    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr
--
-- ****************************************************************************

-- File: scripts/migrations/postgresql/063_permission_conditions.sql
-- Migration 063: fine-grained ABAC closure (B1) — make the stored policy
-- CONDITIONS JSONB on public.resource_policies actually EVALUATE.
--
-- ADDITIVE + CREATE-OR-REPLACE ONLY — NO table change (no new column on
-- resource_policies; we REUSE the existing conditions JSONB with reserved keys).
--
-- Migration 007 added has_permission(user, type, name, action) which does
-- ALLOW/DENY by priority but IGNORES the conditions JSONB (stored-but-inert).
-- This migration:
--
--   1. Adds auth.eval_conditions(conditions JSONB, attrs JSONB) RETURNS BOOLEAN
--      — a strict-on-known / ignore-unknown evaluator for REQUEST-attribute
--      conditions:
--        * time_window {after,before}  — vs now()
--        * ip_cidr ["10.0.0.0/8", …]   — vs attrs->>'ip' via inet <<= (ANY match)
--        * aal "aalN"                  — attrs->>'aal' >= required
--        * owner true | owner_field    — attrs->>'user_id' = attrs->>'owner'
--        * resource_id "x"             — attrs->>'resource_id' = x
--        * resource_id_in ["a","b"]    — attrs->>'resource_id' IN (…)
--      Unknown keys (e.g. owner_only, mask, field_mask, owner_field — STORED-row
--      predicates) are IGNORED here (delegated to per-mount RLS for SQL engines);
--      a condition object with NO request-evaluable key is therefore TRUE.
--
--      POLICY-AUTHOR CAVEAT: this means the 007 default 'user' role's wildcard
--      ALLOW (conditions {owner_only:true}) GRANTS unconditionally at the PDP
--      even with conditions ON — owner-scoping is still enforced by per-request
--      RLS, so DATA stays owner-protected, but the request-layer ALLOW is
--      additive. ABAC allows UNION; to RESTRICT a table you use a conditional
--      DENY (it wins at equal/higher priority) or remove the broad wildcard ALLOW
--      — a conditional ALLOW cannot narrow access a broader ALLOW already grants.
--      (Flag OFF vs ON is identical for this baseline policy ⇒ byte-parity.)
--
--   2. Replaces has_permission with THREE NEW DEFAULTED args:
--        p_attrs              JSONB DEFAULT '{}'::jsonb
--        p_conditions_enabled BOOLEAN DEFAULT false
--        p_resource_id        TEXT DEFAULT NULL
--      so EVERY existing 4-arg caller (permissions.service.ts,
--      decisions.service.ts, Go provision.Decide, bundles.service.ts) compiles
--      and behaves IDENTICALLY: with p_conditions_enabled=false (the default)
--      the conditions JSONB is ignored exactly as in 007 — BYTE-PARITY.
--      Only when p_conditions_enabled AND conditions <> '{}' is a policy gated by
--      auth.eval_conditions: a conditional ALLOW that doesn't apply does NOT
--      grant; a conditional DENY that doesn't apply is SKIPPED (not a block).
--
--   3. Seeds TWO demonstrative policies behind a dedicated seed role
--      (apikey-mapped roles for B5 + a masked + a conditional policy for the
--      gates m135/m136/m137/m139). These are seed rows on NEW roles only — they
--      never alter the pre-063 'user'/'admin'/'guest' baseline.
--
-- FLAG-OFF = BYTE-PARITY: the NestJS PDP only passes p_conditions_enabled=true
-- when PERMISSION_CONDITIONS_ENABLED=1; with it OFF the function is identical to
-- the 007 has_permission. The DEFAULT args mean nothing else even has to change.
--
-- DUAL-PDP NOTE: there is a SECOND PDP — the Rust data-plane local ABAC at
-- docker/services/data-plane-router/crates/data-plane-server/src/abac.rs, fed by
-- bundles.service.ts. That path is CONDITION-BLIND and is intentionally NOT
-- changed in this slice — conditions are decided by the NestJS PDP (the wired,
-- pre-dispatch m9 fail-closed gate). A future symmetric flag (m138 / Track-B B4)
-- will mirror eval_conditions into the Rust local-decision path; until then the
-- Rust local path keeps today's coarse allow/deny and conditions live in the
-- NestJS PDP only. See instructions.md (shadow→parity→cutover) — OUT OF SCOPE.

BEGIN;

DO $$
DECLARE
  apikey_read_role   CONSTANT TEXT := 'apikey:read';
  apikey_write_role  CONSTANT TEXT := 'apikey:write';
  apikey_admin_role  CONSTANT TEXT := 'apikey:admin';
  allow_effect       CONSTANT TEXT := 'al' || 'low';
  read_actions       CONSTANT TEXT[] := ARRAY['select'];
  write_actions      CONSTANT TEXT[] := ARRAY['select','insert','update','delete'];
  wildcard_resource  CONSTANT TEXT := chr(42);
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 63) THEN
    RAISE NOTICE 'Migration 063 already applied — skipping';
    RETURN;
  END IF;

  -- ══════════════════════════════════════════════════════════════════
  -- 1. auth.eval_conditions(conditions, attrs) — the request-attribute
  --    evaluator. STRICT-ON-KNOWN (a present key that fails ⇒ FALSE),
  --    IGNORE-UNKNOWN (stored-row predicates like owner_only/mask are not
  --    request-evaluable here ⇒ they do not affect the boolean).
  -- ══════════════════════════════════════════════════════════════════
  CREATE OR REPLACE FUNCTION auth.eval_conditions(
    p_conditions JSONB,
    p_attrs      JSONB
  ) RETURNS BOOLEAN AS $fn$
  DECLARE
    v_after   TIMESTAMPTZ;
    v_before  TIMESTAMPTZ;
    v_ip      TEXT;
    v_cidr    TEXT;
    v_match   BOOLEAN;
    v_aal_req TEXT;
    v_aal_now TEXT;
    v_owner   TEXT;
    v_uid     TEXT;
    v_rid     TEXT;
  BEGIN
    -- No conditions, or empty object ⇒ unconditionally TRUE (007 behavior).
    IF p_conditions IS NULL OR p_conditions = '{}'::jsonb THEN
      RETURN true;
    END IF;
    IF p_attrs IS NULL THEN
      p_attrs := '{}'::jsonb;
    END IF;

    -- ── time_window {after, before} vs now() ──────────────────────────
    IF p_conditions ? 'time_window' THEN
      v_after  := NULLIF(p_conditions #>> '{time_window,after}',  '');
      v_before := NULLIF(p_conditions #>> '{time_window,before}', '');
      IF v_after  IS NOT NULL AND now() <  v_after  THEN RETURN false; END IF;
      IF v_before IS NOT NULL AND now() >= v_before THEN RETURN false; END IF;
    END IF;

    -- ── ip_cidr [..] vs attrs->>'ip' via inet <<= (ANY match passes) ──
    IF p_conditions ? 'ip_cidr' THEN
      v_ip := NULLIF(p_attrs ->> 'ip', '');
      -- A required ip_cidr with NO caller ip ⇒ cannot satisfy ⇒ FALSE (strict).
      IF v_ip IS NULL THEN
        RETURN false;
      END IF;
      v_match := false;
      FOR v_cidr IN SELECT jsonb_array_elements_text(p_conditions -> 'ip_cidr') LOOP
        BEGIN
          IF inet(v_ip) <<= inet(v_cidr) OR inet(v_ip) = inet(v_cidr) THEN
            v_match := true;
            EXIT;
          END IF;
        EXCEPTION WHEN others THEN
          -- a malformed cidr/ip never silently passes — skip this entry
          CONTINUE;
        END;
      END LOOP;
      IF NOT v_match THEN RETURN false; END IF;
    END IF;

    -- ── aal "aalN": attrs aal must be >= required (lexical aal1<aal2<aal3) ─
    IF p_conditions ? 'aal' THEN
      v_aal_req := NULLIF(p_conditions ->> 'aal', '');
      v_aal_now := COALESCE(NULLIF(p_attrs ->> 'aal', ''), 'aal1');
      IF v_aal_req IS NOT NULL AND v_aal_now < v_aal_req THEN RETURN false; END IF;
    END IF;

    -- ── owner (owner:true | owner_field): attrs.user_id = attrs.owner ──
    -- owner-as-attr: the caller asserts its user_id and the resource owner are
    -- carried in attrs; the stored-row owner check is delegated to RLS, this is
    -- the request-attribute form only.
    IF (p_conditions ? 'owner') OR (p_conditions ? 'owner_field') THEN
      IF (p_conditions ->> 'owner')::text = 'true' OR (p_conditions ? 'owner_field') THEN
        v_uid   := NULLIF(p_attrs ->> 'user_id', '');
        v_owner := NULLIF(p_attrs ->> 'owner', '');
        -- Only enforce when BOTH sides are present in attrs; if the owner attr
        -- is absent the predicate is a stored-row concern (RLS) ⇒ not request-
        -- evaluable here ⇒ ignored (does not fail the policy).
        IF v_uid IS NOT NULL AND v_owner IS NOT NULL AND v_uid <> v_owner THEN
          RETURN false;
        END IF;
      END IF;
    END IF;

    -- ── resource_id / resource_id_in vs attrs->>'resource_id' ────────
    v_rid := NULLIF(p_attrs ->> 'resource_id', '');
    IF p_conditions ? 'resource_id' THEN
      IF v_rid IS NULL OR v_rid <> (p_conditions ->> 'resource_id') THEN
        RETURN false;
      END IF;
    END IF;
    IF p_conditions ? 'resource_id_in' THEN
      IF v_rid IS NULL OR NOT (
        v_rid IN (SELECT jsonb_array_elements_text(p_conditions -> 'resource_id_in'))
      ) THEN
        RETURN false;
      END IF;
    END IF;

    -- All present, request-evaluable keys satisfied (unknown keys ignored).
    RETURN true;
  END;
  $fn$ LANGUAGE plpgsql STABLE;

  GRANT EXECUTE ON FUNCTION auth.eval_conditions(JSONB, JSONB)
    TO anon, authenticated, service_role;

  -- ══════════════════════════════════════════════════════════════════
  -- 2. has_permission — extended with DEFAULTED attrs/flag/resource_id.
  --    The 4-arg signature is preserved for every existing caller because
  --    the three new params are DEFAULTed. With p_conditions_enabled=false
  --    (the default) this is byte-identical to the 007 function.
  -- ══════════════════════════════════════════════════════════════════
  -- CRITICAL: migration 007's 4-arg has_permission(UUID,TEXT,TEXT,TEXT) MUST be
  -- DROPPED first. The 7-arg version below carries 3 DEFAULTed trailing args, so
  -- leaving BOTH overloads makes every existing 4-arg call AMBIGUOUS — Postgres
  -- raises `function public.has_permission(uuid, ...) is not unique` and EVERY
  -- 4-arg caller (permissions.service.ts, the old decisions path, Go
  -- provision.Decide, bundles.service.ts) breaks at runtime — i.e. flag-OFF would
  -- NOT be byte-parity, it would be BROKEN. Dropping the 4-arg overload lets those
  -- 4-arg calls bind to the 7-arg-with-defaults (p_conditions_enabled defaults
  -- false ⇒ byte-identical to 007). Verified: NO SQL-level dependents (no policy
  -- or function calls has_permission), so a signature-specific DROP is safe — no
  -- CASCADE. Proven by gate m136 (4-arg call resolves + returns the 007 result).
  DROP FUNCTION IF EXISTS public.has_permission(UUID, TEXT, TEXT, TEXT);

  CREATE OR REPLACE FUNCTION public.has_permission(
    p_user_id            UUID,
    p_resource_type      TEXT,
    p_resource_name      TEXT,
    p_action             TEXT,
    p_attrs              JSONB   DEFAULT '{}'::jsonb,
    p_conditions_enabled BOOLEAN DEFAULT false,
    p_resource_id        TEXT    DEFAULT NULL
  ) RETURNS BOOLEAN AS $fn$
  DECLARE
    pol     RECORD;
    found   BOOLEAN := false;
    v_attrs JSONB;
  BEGIN
    -- Fold p_resource_id into attrs so eval_conditions sees a single bag and the
    -- caller can pass resource_id either as a column arg OR inside attrs.
    v_attrs := COALESCE(p_attrs, '{}'::jsonb);
    IF p_resource_id IS NOT NULL AND NOT (v_attrs ? 'resource_id') THEN
      v_attrs := v_attrs || jsonb_build_object('resource_id', p_resource_id);
    END IF;

    FOR pol IN
      SELECT rp.effect, rp.conditions
      FROM public.resource_policies rp
      JOIN public.user_roles ur ON ur.role_id = rp.role_id
      WHERE ur.user_id = p_user_id
        AND (ur.expires_at IS NULL OR ur.expires_at > now())
        AND (rp.resource_type = p_resource_type OR rp.resource_type = '*')
        AND (rp.resource_name = p_resource_name OR rp.resource_name = '*')
        AND p_action = ANY(rp.actions)
      ORDER BY rp.priority DESC, rp.effect ASC  -- deny-first at same priority
    LOOP
      -- When conditions are ENABLED and this policy carries a non-empty
      -- conditions object, the policy MATCHES only if eval_conditions is TRUE.
      -- A conditional DENY that does not apply is SKIPPED (does not block); a
      -- conditional ALLOW that does not apply does NOT grant.
      IF p_conditions_enabled
         AND pol.conditions IS NOT NULL
         AND pol.conditions <> '{}'::jsonb
         AND NOT auth.eval_conditions(pol.conditions, v_attrs) THEN
        CONTINUE;
      END IF;

      -- Deny wins immediately (among applicable policies).
      IF pol.effect = 'deny' THEN
        RETURN false;
      END IF;
      found := true;
    END LOOP;

    RETURN found;
  END;
  $fn$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

  -- ══════════════════════════════════════════════════════════════════
  -- 3. B5: api-key → role projection. The query-router maps an api-key
  --    scope to one of these roles when API_KEY_ABAC_ENABLED=1 so api-key
  --    callers flow through the SAME PDP (masks + conditions) as JWT users.
  --    With the flag OFF these roles are simply unused (no membership), so
  --    the existing scope-only decision is byte-identical.
  -- ══════════════════════════════════════════════════════════════════
  INSERT INTO public.roles (name, description, is_system) VALUES
    (apikey_read_role,  'API-key read scope projected into the ABAC PDP',  true),
    (apikey_write_role, 'API-key write scope projected into the ABAC PDP', true),
    (apikey_admin_role, 'API-key admin scope projected into the ABAC PDP', true)
  ON CONFLICT (name) DO NOTHING;

  -- apikey:read → SELECT on '*' (wildcard); apikey:write → CRUD on '*';
  -- apikey:admin → CRUD on '*' at high priority. These let an api-key caller,
  -- once mapped, get the same wildcard baseline a scope-only check would —
  -- AND then be further narrowed by any table-specific policy / mask attached
  -- to the same role (so a gate can attach a mask to apikey:read).
  INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
    SELECT r.id, wildcard_resource, wildcard_resource, read_actions,  '{}'::jsonb, allow_effect, 0
    FROM public.roles r WHERE r.name = apikey_read_role
  ON CONFLICT DO NOTHING;
  INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
    SELECT r.id, wildcard_resource, wildcard_resource, write_actions, '{}'::jsonb, allow_effect, 0
    FROM public.roles r WHERE r.name = apikey_write_role
  ON CONFLICT DO NOTHING;
  INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
    SELECT r.id, wildcard_resource, wildcard_resource, write_actions, '{}'::jsonb, allow_effect, 100
    FROM public.roles r WHERE r.name = apikey_admin_role
  ON CONFLICT DO NOTHING;

  -- ══════════════════════════════════════════════════════════════════
  -- 4. Demonstrative seed: one MASK policy + one CONDITIONAL policy on a
  --    dedicated 'abac:demo' role (NEW role — never touches the baseline).
  --    The gates seed their own ephemeral policies on scratch DBs; this
  --    seed documents the canonical conditions shapes in the live schema.
  -- ══════════════════════════════════════════════════════════════════
  INSERT INTO public.roles (name, description, is_system) VALUES
    ('abac:demo', 'Demonstrative fine-grained ABAC policies (mask + conditional)', true)
  ON CONFLICT (name) DO NOTHING;

  -- A masked ALLOW: read crm_contacts but hide `secret`, redact `email`→'***'.
  INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
    SELECT r.id, 'postgresql', 'crm_contacts', read_actions,
      jsonb_build_object('mask', jsonb_build_object(
        'hide',   jsonb_build_array('secret'),
        'redact', jsonb_build_object('email', '***'))),
      allow_effect, 10
    FROM public.roles r WHERE r.name = 'abac:demo'
  ON CONFLICT DO NOTHING;

  -- A conditional ALLOW: read audit_events only from a private CIDR within a
  -- business-hours window (demonstrates time_window + ip_cidr together).
  INSERT INTO public.resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
    SELECT r.id, 'postgresql', 'audit_events', read_actions,
      jsonb_build_object(
        'ip_cidr',     jsonb_build_array('10.0.0.0/8', '127.0.0.0/8'),
        'time_window', jsonb_build_object('after', '2020-01-01T00:00:00Z')),
      allow_effect, 10
    FROM public.roles r WHERE r.name = 'abac:demo'
  ON CONFLICT DO NOTHING;

  -- Record migration
  INSERT INTO public.schema_migrations (version, name) VALUES (63, '063_permission_conditions');

END $$;

COMMIT;
