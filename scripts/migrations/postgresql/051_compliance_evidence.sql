-- File: scripts/migrations/postgresql/051_compliance_evidence.sql
-- Migration 051: SOC2-LITE compliance evidence store (Track-D D4.1).
--
-- ADDITIVE ONLY. Creates the durable, HASH-SEALED evidence store the flag-gated
-- compliance collector (SOC2_EVIDENCE_ENABLED, default OFF) snapshots into. Each
-- snapshot writes ONE row PER SECTION (ci | access | change_mgmt); every row is
-- sealed with a per-row hash:
--
--     hash = sha256( canonical(section, collected_at, payload) )
--
-- computed IN GO (engine-agnostic — the seal does not depend on any DB hashing
-- function, so the identical verify runs over rows exported from any engine). A
-- post-hoc edit of a stored payload, section, or collected_at no longer matches
-- the stored hash, so a verifier re-hashing the row detects the tamper at exactly
-- that row — that is the whole point, and the gate's load-bearing REJECT proves
-- it.
--
-- This is a PLATFORM-LEVEL store, NOT a per-tenant one: compliance evidence
-- (which CI gates passed, who has access, the change-management trail) is about
-- the GROBASE PLATFORM as a whole, not any single tenant. There is therefore no
-- tenant_id column and no per-tenant RLS policy. Instead the RLS posture is
-- SERVICE-ROLE-ONLY: RLS is enabled with NO permissive policy for
-- anon/authenticated, so those roles see ZERO rows; only the BYPASSRLS
-- service_role (the control-plane collector + read API) can read/write. An
-- auditor reads evidence THROUGH the control plane's authenticated read API, not
-- by direct table access.
--
-- ISOLATION: mirrors the 040/041/042/047 house style for grants + the
-- schema_migrations guard, but the policy shape is "deny-by-default to
-- non-service roles" rather than "scope to auth.current_tenant_id()" because the
-- subject is the platform, not a tenant.
--
-- Running this migration changes NO existing behavior (no ALTER/DROP of any
-- existing object). With SOC2_EVIDENCE_ENABLED OFF (the default) the
-- /v1/compliance* routes are never mounted and the collector is a no-op, so
-- nothing ever writes to this table, so it stays empty = byte-parity baseline
-- (same story as 040 / 041 / 042 / 047).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 51) THEN
    RAISE NOTICE 'Migration 051 already applied - skipping';
    RETURN;
  END IF;

  -- One row per (snapshot, section). `section` is the control family the row
  -- evidences: ci (the CI/gate posture — which mNN gates + CI jobs exist/passed),
  -- access (the platform access review — role grants), change_mgmt (the git
  -- change-management trail — recent commits + their authors as the change
  -- record). `payload` is the section's structured evidence (jsonb); it
  -- participates in canonical(row), so any post-hoc edit of it breaks `hash`.
  -- `collected_at` is the snapshot instant (truncated to microseconds in Go so
  -- the seal survives the timestamptz round-trip). `snapshot_id` groups the three
  -- rows of one collection run.
  CREATE TABLE IF NOT EXISTS public.compliance_evidence (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    snapshot_id  UUID        NOT NULL,                  -- groups the 3 sections of one run
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    section      TEXT        NOT NULL,                  -- ci | access | change_mgmt
    payload      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    hash         TEXT        NOT NULL,                  -- sha256(canonical(section,collected_at,payload)), lower-hex
    CONSTRAINT compliance_evidence_section_chk
      CHECK (section IN ('ci', 'access', 'change_mgmt')),
    -- one section row per snapshot — a snapshot has exactly one ci/access/change_mgmt.
    CONSTRAINT compliance_evidence_snapshot_section_uniq UNIQUE (snapshot_id, section)
  );

  -- Read API scans by collected_at DESC (latest snapshot) and by snapshot_id
  -- (fetch one run's three sections); section filter is cheap off the UNIQUE.
  CREATE INDEX IF NOT EXISTS compliance_evidence_collected_idx
    ON public.compliance_evidence (collected_at DESC);
  CREATE INDEX IF NOT EXISTS compliance_evidence_snapshot_idx
    ON public.compliance_evidence (snapshot_id);

  -- SERVICE-ROLE-ONLY posture: enable RLS but DO NOT create a permissive policy
  -- for anon/authenticated. With RLS on and no policy granting them rows, those
  -- roles read ZERO rows (deny-by-default). The BYPASSRLS service_role — the
  -- collector + the control-plane read API — is unaffected. This is the platform
  -- analogue of the per-tenant isolation on 040/041/042/047: there the wall is
  -- "your tenant only"; here it is "service role only", because compliance
  -- evidence is about the platform, not a tenant, and must never be readable by a
  -- tenant credential.
  ALTER TABLE public.compliance_evidence ENABLE ROW LEVEL SECURITY;
  -- FORCE so even the table owner is subject to RLS (defense in depth: the only
  -- legitimate reader is the BYPASSRLS service role, never an owner connection).
  ALTER TABLE public.compliance_evidence FORCE ROW LEVEL SECURITY;

  -- Grant the collector/read-API role its write+read; authenticated/anon get
  -- NOTHING (no GRANT) AND are denied by RLS — belt and braces. service_role is
  -- BYPASSRLS but we re-affirm its grants explicitly (the 001 blanket-grant
  -- story / 042 / 047).
  GRANT SELECT, INSERT ON public.compliance_evidence TO service_role;
  -- Deliberately NO grant to authenticated/anon: evidence is service-role-only.

  INSERT INTO public.schema_migrations (version, name)
  VALUES (51, '051_compliance_evidence')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- DROP TABLE IF EXISTS public.compliance_evidence;
-- DELETE FROM public.schema_migrations WHERE version = 51;
-- COMMIT;
