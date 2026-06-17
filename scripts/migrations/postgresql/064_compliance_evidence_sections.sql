-- 064_compliance_evidence_sections.sql
-- Widen the compliance_evidence section CHECK for the broader SOC2-lite evidence
-- surface added for active SOC 2 / ISO 27001 pursuit.
--
-- Migration 051 pinned `section IN ('ci','access','change_mgmt')`. The evidence
-- collector (internal/compliance) now also seals three OBSERVED-fact sections —
-- gdpr_rights, crypto_posture, backup_posture — each hashed/sealed identically.
-- Without this widening, an ENABLED collect run hits constraint
-- compliance_evidence_section_chk (SQLSTATE 23514).
--
-- Forward-only + idempotent (drop-then-add). ADDITIVE / byte-parity: the table is
-- empty in any deploy where SOC2_EVIDENCE_ENABLED has never been turned on (the
-- default), so this only enlarges what a future ENABLED run MAY insert — it
-- changes no existing row and no default behavior.

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.compliance_evidence') IS NOT NULL THEN
    ALTER TABLE public.compliance_evidence
      DROP CONSTRAINT IF EXISTS compliance_evidence_section_chk;
    ALTER TABLE public.compliance_evidence
      ADD CONSTRAINT compliance_evidence_section_chk
      CHECK (section IN ('ci', 'access', 'change_mgmt',
                         'gdpr_rights', 'crypto_posture', 'backup_posture'));
  END IF;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (64, '064_compliance_evidence_sections')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- ALTER TABLE public.compliance_evidence DROP CONSTRAINT IF EXISTS compliance_evidence_section_chk;
-- ALTER TABLE public.compliance_evidence ADD CONSTRAINT compliance_evidence_section_chk
--   CHECK (section IN ('ci', 'access', 'change_mgmt'));
-- DELETE FROM public.schema_migrations WHERE version = 64;
-- COMMIT;
