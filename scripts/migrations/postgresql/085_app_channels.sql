-- 085_app_channels.sql — cross-app secure MESSAGING channels between two app-tenants.
--
-- A channel is a consented, bidirectional realtime link between two distinct app-tenants
-- (each app = its own isolated database). One tenant OPENS a pending channel to another; the
-- other ACCEPTS it (pending→accepted in one atomic UPDATE). Once accepted, either side mints a
-- short-lived realtime JWT carrying the protected namespace `xapp:<channel_id>` — the only grant
-- that reaches that topic (REALTIME_PROTECTED_NAMESPACES=...,xapp: makes a wildcard token
-- insufficient). The channel_id is the opaque namespace suffix; it never leaks a tenant slug.
--
-- CONTROL-PLANE ONLY (served by internal/appchannels over the admin pool; never an RLS GUC / the
-- data plane). Mirrors the 080_invites token/atomic-accept discipline.
--
-- FLAG-GATED OFF = PARITY: APP_CHANNELS_ENABLED gates open/accept/list/mint-token. OFF (default)
-- ⇒ no routes, no rows. The table is inert without the flag.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 85) THEN
    RAISE NOTICE 'Migration 085 already applied - skipping';
    RETURN;
  END IF;

  CREATE TABLE IF NOT EXISTS public.app_channels (
    id          uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_a    text        NOT NULL,
    tenant_b    text        NOT NULL,
    channel_id  text        NOT NULL DEFAULT gen_random_uuid()::text,
    status      text        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','accepted')),
    opened_by   text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    accepted_at timestamptz,
    PRIMARY KEY (id),
    CONSTRAINT app_channels_distinct_tenants CHECK (tenant_a <> tenant_b)
  );
  -- the namespace suffix is globally unique (xapp:<channel_id> addresses exactly one channel).
  CREATE UNIQUE INDEX IF NOT EXISTS app_channels_channel_id_key ON public.app_channels (channel_id);
  -- at most ONE channel per unordered tenant pair (open A→B then B→A collapses to the same row).
  CREATE UNIQUE INDEX IF NOT EXISTS app_channels_pair_key
    ON public.app_channels (least(tenant_a, tenant_b), greatest(tenant_a, tenant_b));
  CREATE INDEX IF NOT EXISTS app_channels_tenant_a_idx ON public.app_channels (tenant_a);
  CREATE INDEX IF NOT EXISTS app_channels_tenant_b_idx ON public.app_channels (tenant_b);

  -- Control-plane-only: rows are reached solely through the admin pool (BYPASSRLS). RLS is on with
  -- no permissive policy + a service_role grant, so a tenant-scoped data-plane role can never read a
  -- channel row (deny-by-default); the data plane never touches this table.
  ALTER TABLE public.app_channels ENABLE ROW LEVEL SECURITY;
  GRANT SELECT, INSERT, UPDATE, DELETE ON public.app_channels TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (85, '085_app_channels') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
