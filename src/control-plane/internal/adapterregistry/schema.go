/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:39:07 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:39:08 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import "context"

// ensureSchemaDDL creates public.tenant_databases idempotently. The live schema
// has tenant_id as TEXT (set by migration 005 + 030 in the TS days); we
// preserve that here since changing column type would require a destructive
// migration. The fresh-install shape uses TEXT to stay aligned.
//
// Tenant policy: M12 retired the pre-existing 'tenant_isolation' policy that
// compared `tenant_id` against `auth.current_user_id()` (i.e. treated every
// user as their own tenant). The corrected policy uses
// `auth.current_tenant_id()` and is named `tenant_databases_tenant_isolation`
// to avoid collision with the legacy name. We drop the old name on upgrade.
const ensureSchemaDDL = `
CREATE TABLE IF NOT EXISTS public.tenant_databases (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       TEXT NOT NULL,
  engine          TEXT NOT NULL CHECK (engine IN ('postgresql','cockroachdb','mongodb','mysql','mariadb','redis','sqlite','mssql','http','dynamodb','jdbc','cassandra','neo4j','elasticsearch','qdrant','influx')),
  name            TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 64),
  connection_enc  BYTEA NOT NULL,
  connection_iv   BYTEA NOT NULL,
  connection_tag  BYTEA NOT NULL,
  connection_salt BYTEA,
  created_at      TIMESTAMPTZ DEFAULT now(),
  last_healthy_at TIMESTAMPTZ,
  isolation       TEXT NOT NULL DEFAULT 'shared_rls' CHECK (isolation IN ('shared_rls','schema_per_tenant','db_per_tenant','tenant_owned')),
  UNIQUE (tenant_id, name)
);
-- Additive for pre-existing tables (the CHECK above only applies to fresh installs).
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS isolation TEXT NOT NULL DEFAULT 'shared_rls';
-- Idempotently widen the fresh-install CHECK on upgraded databases so
-- tenant_owned mounts register (older installs baked the 3-value list).
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_isolation_check;
ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_isolation_check
  CHECK (isolation IN ('shared_rls','schema_per_tenant','db_per_tenant','tenant_owned'));
-- Idempotently widen the engine CHECK so newer engine ids (mariadb,
-- cockroachdb, mssql, dynamodb) register on upgraded databases (older installs
-- baked a narrower engine list). The broad set stays at the DB layer;
-- control-plane allowedEngines is the honest ACCEPT gate (only engines with a
-- live Rust pool — dynamodb is further gated behind DYNAMODB_ENGINE_ENABLED).
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_engine_check;
ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_engine_check
  CHECK (engine IN ('postgresql','cockroachdb','mongodb','mysql','mariadb','redis','sqlite','mssql','http','dynamodb','jdbc','cassandra','neo4j','elasticsearch','qdrant','influx'));
-- S2 / G-Vault (migration 060, mirrored here so a FRESH EnsureSchema install
-- converges with a migrated one): a mount may carry a Vault credential REFERENCE
-- instead of an inline encrypted DSN. Add the three nullable cred_* columns,
-- make the inline-encrypted columns nullable, and enforce EXACTLY ONE of
-- {inline-encrypted, cred-ref} per row. All idempotent; existing inline rows are
-- untouched (they remain inline_complete).
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cred_provider  TEXT;
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cred_reference TEXT;
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cred_version   TEXT;
ALTER TABLE public.tenant_databases ALTER COLUMN connection_enc DROP NOT NULL;
ALTER TABLE public.tenant_databases ALTER COLUMN connection_iv  DROP NOT NULL;
ALTER TABLE public.tenant_databases ALTER COLUMN connection_tag DROP NOT NULL;
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_credential_xor_check;
ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_credential_xor_check CHECK (
  (connection_enc IS NOT NULL AND connection_iv IS NOT NULL AND connection_tag IS NOT NULL
     AND cred_provider IS NULL AND cred_reference IS NULL AND cred_version IS NULL)
  OR
  (cred_provider IS NOT NULL AND cred_reference IS NOT NULL
     AND connection_enc IS NULL AND connection_iv IS NULL AND connection_tag IS NULL
     AND connection_salt IS NULL)
);
-- CMEK / BYOK (migration 061, mirrored here so a FRESH EnsureSchema install
-- converges with a migrated one): add the two nullable cmek_* columns, DROP the
-- 060 two-way XOR check, and ADD a THREE-way check admitting a third mode —
-- cmek-envelope (enc/iv/tag + cmek_wrapped_dek + cmek_kms_key_id, cred_* NULL).
-- The cmek_* columns are NULL on every inline / cred-ref row, so the baseline is
-- untouched. With CMEK_ENABLED OFF (default) mode (iii) is never written.
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cmek_wrapped_dek BYTEA;
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS cmek_kms_key_id  TEXT;
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_credential_xor_check;
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_credential_mode_check;
ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_credential_mode_check CHECK (
  (connection_enc IS NOT NULL AND connection_iv IS NOT NULL AND connection_tag IS NOT NULL
     AND cred_provider IS NULL AND cred_reference IS NULL AND cred_version IS NULL
     AND cmek_wrapped_dek IS NULL AND cmek_kms_key_id IS NULL)
  OR
  (cred_provider IS NOT NULL AND cred_reference IS NOT NULL
     AND connection_enc IS NULL AND connection_iv IS NULL AND connection_tag IS NULL
     AND connection_salt IS NULL
     AND cmek_wrapped_dek IS NULL AND cmek_kms_key_id IS NULL)
  OR
  (connection_enc IS NOT NULL AND connection_iv IS NOT NULL AND connection_tag IS NOT NULL
     AND cmek_wrapped_dek IS NOT NULL AND cmek_kms_key_id IS NOT NULL
     AND cred_provider IS NULL AND cred_reference IS NULL AND cred_version IS NULL)
);
-- Per-mount shared resources (migration 068, mirrored here so a FRESH
-- EnsureSchema install converges with a migrated one): a JSONB array of table
-- names the data plane reads as the mount's NON-owner-scoped catalog. NULL on
-- every existing/inline/cred-ref/cmek row ⇒ no opt-in ⇒ byte-parity.
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS shared_resources JSONB;
-- Per-mount read_scoped (migration 070, mirrored here so a FRESH EnsureSchema
-- install converges with a migrated one): a boolean opting THIS mount into
-- predicate-based read owner-scoping independent of DATA_PLANE_PG_READ_PREDICATE.
-- false on every existing/inline/cred-ref/cmek row ⇒ no opt-in ⇒ reads follow the
-- global flag alone ⇒ byte-parity.
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS read_scoped boolean NOT NULL DEFAULT false;
ALTER TABLE public.tenant_databases ENABLE ROW LEVEL SECURITY;
-- Retire the pre-M12 broken policy on upgrade.
DROP POLICY IF EXISTS tenant_isolation ON public.tenant_databases;
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'tenant_databases' AND policyname = 'tenant_databases_tenant_isolation'
  ) THEN
    CREATE POLICY tenant_databases_tenant_isolation ON public.tenant_databases
      FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
      WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
  END IF;
END $$;`

// EnsureSchema creates public.tenant_databases idempotently (DDL in ensureSchemaDDL).
func (s *Service) EnsureSchema(ctx context.Context) error {
	return s.db.AdminExec(ctx, ensureSchemaDDL)
}
