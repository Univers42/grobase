-- grobase-website portal per-user data — applied into the dedicated website
-- database by the generic provisioner. Auth itself is grobase GoTrue; this is the
-- small owner-scoped app-data the portal owns (profiles/preferences). Owner-scoping
-- on the data-plane path comes from the mount's read_scoped=true (owner_id column).
CREATE TABLE IF NOT EXISTS public.profiles (
  id           bigserial PRIMARY KEY,
  owner_id     text NOT NULL,
  display_name text,
  preferences  jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS profiles_owner ON public.profiles (owner_id);
