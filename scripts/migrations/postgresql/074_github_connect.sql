-- 074_github_connect.sql — Track-E GitHub App connect/sync LINKAGE (GITHUB_CONNECT_ENABLED).
--
-- Additive + idempotent. CONTROL-PLANE ONLY. ZERO GitHub-token columns: installation
-- tokens are minted just-in-time on the server (~1h) and NEVER persisted; the App
-- private key + client secret are runtime secrets, never DB. We store only the
-- org↔installation↔user LINKAGE (installation_id is a non-secret integer; the granted
-- permissions echo is non-secret, kept for a least-privilege proof). RLS-forced,
-- service_role-only (reached only via the control-plane admin pool).
--
-- FLAG-GATED OFF = PARITY: main mounts /v1/github* + /v1/orgs/{id}/github/* ONLY when
-- GITHUB_CONNECT_ENABLED is truthy. OFF (default) ⇒ no routes, no rows written here.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 74) THEN
    RAISE NOTICE 'Migration 074 already applied - skipping';
    RETURN;
  END IF;

  -- One GitHub App installation ↔ one GitHub org login (the non-secret identity).
  CREATE TABLE IF NOT EXISTS public.github_installations (
    installation_id  bigint      NOT NULL,
    github_org_login text        NOT NULL,
    github_org_id    bigint      NOT NULL,
    app_slug         text        NOT NULL DEFAULT '',
    permissions      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    suspended        boolean     NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (installation_id)
  );
  CREATE UNIQUE INDEX IF NOT EXISTS github_installations_org_login
    ON public.github_installations (lower(github_org_login));

  -- Which vault42 org owns which installation, linked by whom.
  CREATE TABLE IF NOT EXISTS public.github_links (
    org_id          uuid        NOT NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
    installation_id bigint      NOT NULL REFERENCES public.github_installations(installation_id) ON DELETE CASCADE,
    linked_by       text        NOT NULL,
    linked_at       timestamptz NOT NULL DEFAULT now(),
    last_synced_at  timestamptz NULL,
    PRIMARY KEY (org_id, installation_id)
  );
  CREATE INDEX IF NOT EXISTS github_links_install ON public.github_links (installation_id);

  -- Short-lived pending-connect handoff (nonce → installation), so the CLI poll resolves.
  CREATE TABLE IF NOT EXISTS public.github_connect_pending (
    nonce            text        NOT NULL,
    org_id           uuid        NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
    initiated_by     text        NOT NULL,
    installation_id  bigint      NULL,
    status           text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','ready','consumed','expired')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    expires_at       timestamptz NOT NULL,
    PRIMARY KEY (nonce)
  );
  CREATE INDEX IF NOT EXISTS github_connect_pending_exp ON public.github_connect_pending (expires_at);

  -- The user-identity link for `auth login --github` → GoTrue subject.
  CREATE TABLE IF NOT EXISTS public.github_user_links (
    github_user_id bigint      NOT NULL,
    github_login   text        NOT NULL,
    user_id        text        NOT NULL,
    linked_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (github_user_id)
  );

  ALTER TABLE public.github_installations   ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.github_installations   FORCE  ROW LEVEL SECURITY;
  ALTER TABLE public.github_links           ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.github_links           FORCE  ROW LEVEL SECURITY;
  ALTER TABLE public.github_connect_pending ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.github_connect_pending FORCE  ROW LEVEL SECURITY;
  ALTER TABLE public.github_user_links      ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.github_user_links      FORCE  ROW LEVEL SECURITY;
  REVOKE ALL ON public.github_installations, public.github_links,
                public.github_connect_pending, public.github_user_links
    FROM anon, authenticated;
  GRANT SELECT, INSERT, UPDATE, DELETE
    ON public.github_installations, public.github_links,
       public.github_connect_pending, public.github_user_links
    TO service_role;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (74, '074_github_connect') ON CONFLICT (version) DO NOTHING;
END $$;
COMMIT;
