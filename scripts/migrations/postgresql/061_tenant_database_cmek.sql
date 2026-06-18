-- File: scripts/migrations/postgresql/061_tenant_database_cmek.sql
-- Migration 061: CMEK / BYOK (D4.8) — let a tenant's external DB mount be
-- ENVELOPE-encrypted with a Data-Encryption-Key (DEK) that is WRAPPED by a
-- Key-Encryption-Key (KEK) held in an EXTERNAL KMS the customer controls. The
-- platform stores ONLY the wrapped DEK + the DEK-encrypted DSN ciphertext, and
-- cannot decrypt without asking the KMS to UNWRAP the DEK. Revoke/delete the KMS
-- key => crypto-shred (the DSN becomes permanently undecryptable).
--
-- ADDITIVE + REVERSIBLE-IN-INTENT. EXTENDS migration 060 (cred-ref / S2):
--   * adds two NULLABLE columns:
--       cmek_wrapped_dek BYTEA  -- the KMS-wrapped DEK (e.g. Vault "vault:v1:...")
--       cmek_kms_key_id  TEXT   -- the external KMS KEK id used to wrap/unwrap
--   * DROPS the 060 two-way XOR check (tenant_databases_credential_xor_check)
--   * ADDS a THREE-way check enforcing EXACTLY ONE storage mode per row.
--
-- CMEK REUSES the existing connection_enc/connection_iv/connection_tag columns
-- for the DEK-encrypted DSN (so no new ciphertext columns); the presence of a
-- non-NULL cmek_wrapped_dek is the MODE DISCRIMINATOR that tells GetConnection to
-- unwrap via the KMS instead of the inline master key. The three modes:
--
--   (i)  inline-platform : enc/iv/tag NOT NULL · cred_* NULL · cmek_* NULL
--        (today's encrypted-at-rest path under the platform VAULT_ENC_KEY)
--   (ii) cred-ref        : cred_provider/cred_reference NOT NULL · enc/iv/tag NULL · cmek_* NULL
--        (060/S2: the data plane resolves the DSN from Vault at query time)
--   (iii)cmek-envelope   : enc/iv/tag NOT NULL AND cmek_wrapped_dek NOT NULL
--        AND cmek_kms_key_id NOT NULL · cred_* NULL
--        (this migration: DEK-encrypted DSN + KMS-wrapped DEK)
--
-- An INLINE row (mode i) is byte-identical to every pre-061 inline row — both
-- cmek_* columns are NULL — so the live baseline is UNTOUCHED. With CMEK_ENABLED
-- OFF (the default) the control plane never writes mode (iii), so this changes
-- NOTHING on a request path = byte-parity baseline (the same story as 040–060).
--
-- Migration number 061 follows 060 in the reserved G-Vault/CMEK band.
--
-- Idempotent: every column add is IF NOT EXISTS; the CHECK is dropped-then-added
-- by a stable name; re-running converges. The 060 XOR check is dropped
-- CONDITIONALLY by name (IF EXISTS) so re-applying or applying on a base that
-- never had 060 both work. 060 MUST be applied before 061 (this widens its
-- check); the schema_migrations guard short-circuits a double-apply.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 61) THEN
    RAISE NOTICE 'Migration 061 already applied - skipping';
    RETURN;
  END IF;

  -- ── 1) CMEK columns (both NULLABLE; absent = not a CMEK row = today's row) ───
  -- cmek_wrapped_dek holds the KMS-wrapped DEK verbatim (for Vault Transit this
  -- is the "vault:vN:..." string as bytes, which embeds the key version so a
  -- rotated key still decrypts old rows and a DELETED key decrypts nothing).
  -- cmek_kms_key_id names the external KEK the platform asks the KMS to unwrap
  -- under at GetConnection time.
  ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cmek_wrapped_dek BYTEA;
  ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cmek_kms_key_id  TEXT;

  -- ── 2) drop the 060 two-way XOR check (conditional, by name) ────────────────
  -- 060 installed tenant_databases_credential_xor_check enforcing EXACTLY ONE of
  -- {inline, cred-ref}. We widen it to three modes below, so drop it first. IF
  -- EXISTS keeps this safe when 060 was never applied or 061 is re-run.
  ALTER TABLE public.tenant_databases
    DROP CONSTRAINT IF EXISTS tenant_databases_credential_xor_check;

  -- ── 3) THREE-way CHECK: EXACTLY ONE of {inline, cred-ref, cmek-envelope} ────
  -- Drop-by-name first so re-running re-installs cleanly (idempotent). The CHECK
  -- only bites NEW inserts/updates; every pre-061 row is mode (i) or (ii) already
  -- (cmek_* are NULL on those), so it admits them unchanged.
  ALTER TABLE public.tenant_databases
    DROP CONSTRAINT IF EXISTS tenant_databases_credential_mode_check;
  ALTER TABLE public.tenant_databases
    ADD CONSTRAINT tenant_databases_credential_mode_check CHECK (
      (
        -- (i) inline-platform: encrypted-at-rest under the platform master key.
        connection_enc IS NOT NULL AND connection_iv IS NOT NULL
          AND connection_tag IS NOT NULL
          AND cred_provider IS NULL AND cred_reference IS NULL AND cred_version IS NULL
          AND cmek_wrapped_dek IS NULL AND cmek_kms_key_id IS NULL
      )
      OR
      (
        -- (ii) cred-ref: no ciphertext; the data plane resolves the DSN itself.
        cred_provider IS NOT NULL AND cred_reference IS NOT NULL
          AND connection_enc IS NULL AND connection_iv IS NULL
          AND connection_tag IS NULL AND connection_salt IS NULL
          AND cmek_wrapped_dek IS NULL AND cmek_kms_key_id IS NULL
      )
      OR
      (
        -- (iii) cmek-envelope: DEK-encrypted DSN (reuses enc/iv/tag) + wrapped DEK
        --       + KMS key id. cred_* must be NULL.
        connection_enc IS NOT NULL AND connection_iv IS NOT NULL
          AND connection_tag IS NOT NULL
          AND cmek_wrapped_dek IS NOT NULL AND cmek_kms_key_id IS NOT NULL
          AND cred_provider IS NULL AND cred_reference IS NULL AND cred_version IS NULL
      )
    );

  INSERT INTO public.schema_migrations (version, name)
  VALUES (61, '061_tenant_database_cmek')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;

-- DOWN (manual, gated):
-- BEGIN;
-- ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_credential_mode_check;
-- -- restore the 060 two-way XOR check:
-- ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_credential_xor_check CHECK (
--   (connection_enc IS NOT NULL AND connection_iv IS NOT NULL AND connection_tag IS NOT NULL
--      AND cred_provider IS NULL AND cred_reference IS NULL AND cred_version IS NULL)
--   OR
--   (cred_provider IS NOT NULL AND cred_reference IS NOT NULL
--      AND connection_enc IS NULL AND connection_iv IS NULL AND connection_tag IS NULL
--      AND connection_salt IS NULL)
-- );
-- ALTER TABLE public.tenant_databases DROP COLUMN IF EXISTS cmek_wrapped_dek;
-- ALTER TABLE public.tenant_databases DROP COLUMN IF EXISTS cmek_kms_key_id;
-- DELETE FROM public.schema_migrations WHERE version = 61;
-- COMMIT;
