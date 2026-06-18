-- File: scripts/migrations/postgresql/066_movieverse_schema.sql
-- Migration 066 (MovieVerse on Grobase): the data model + RLS that replaces the
-- dropped Spring Boot / MySQL backend of vendor/MovieVerse.
--
-- ADDITIVE + idempotent (CREATE … IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY
-- IF EXISTS + CREATE / ON CONFLICT), in the style of 016_unify_rls.sql. Reuses the
-- existing identity helpers auth.current_user_id()/auth.uid() (016) and the
-- anon/authenticated/service_role/authenticator roles (001, 065).
--
-- Identity = GoTrue auth.users. The app's per-user content (reviews/likes/watch
-- status/lists) is owner-scoped by RLS via auth.current_user_id(). Cross-user
-- MODERATION (a moderator reads/deletes anyone's review, triages reports) is
-- granted by auth.is_moderator()/auth.is_admin(), which read the MovieVerse role
-- from the JWT's app_metadata.role claim — GoTrue copies app_metadata into the
-- token and PostgREST verifies it independently into request.jwt.claims (the same
-- mechanism as auth.aal() in 007). The top-level `role` claim is NOT touched: it
-- is PostgREST's SET ROLE switch (authenticated/anon) and must stay that.
--
-- New tables FORCE ROW LEVEL SECURITY explicitly (065's one-time pg_class walk
-- does not re-run for tables added later). public.movieverse_profiles is the role/
-- status source of truth; it is NOT public.profiles (which no migration creates).

BEGIN;

-- ─── Identity-claim helpers (MovieVerse role from app_metadata.role) ──────────

CREATE OR REPLACE FUNCTION auth.movieverse_role() RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT upper(COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::json
      -> 'app_metadata' ->> 'role',
    'STANDARD'
  ));
$$;

CREATE OR REPLACE FUNCTION auth.is_moderator() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT auth.movieverse_role() IN ('MODERATOR', 'ADMIN');
$$;

CREATE OR REPLACE FUNCTION auth.is_admin() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT auth.movieverse_role() = 'ADMIN';
$$;

GRANT EXECUTE ON FUNCTION auth.movieverse_role() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.is_moderator()   TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.is_admin()        TO anon, authenticated, service_role;

-- ─── Tables ───────────────────────────────────────────────────────────────────

-- Role/status source of truth (mirrors the dropped MySQL `users`; password is
-- GoTrue's job). id == auth.users.id.
CREATE TABLE IF NOT EXISTS public.movieverse_profiles (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username   TEXT UNIQUE NOT NULL,
  email      TEXT,
  role       TEXT NOT NULL DEFAULT 'STANDARD' CHECK (role   IN ('ADMIN','MODERATOR','STANDARD')),
  status     TEXT NOT NULL DEFAULT 'ACTIVE'   CHECK (status IN ('ACTIVE','BANNED','DISABLED')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.reviews (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  media_id    BIGINT NOT NULL,
  media_type  TEXT NOT NULL CHECK (media_type IN ('MOVIE','SERIE')),
  title       TEXT NOT NULL,
  poster_path TEXT,
  rating      INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 10),
  comment     TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, media_id, media_type)
);
CREATE INDEX IF NOT EXISTS idx_reviews_media     ON public.reviews (media_id, media_type);
CREATE INDEX IF NOT EXISTS idx_reviews_user_time ON public.reviews (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.likes (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  media_id     BIGINT NOT NULL,
  media_type   TEXT NOT NULL CHECK (media_type IN ('MOVIE','SERIE')),
  title        TEXT,
  poster_path  TEXT,
  vote_average DOUBLE PRECISION,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, media_id, media_type)
);
CREATE INDEX IF NOT EXISTS idx_likes_media     ON public.likes (media_id, media_type);
CREATE INDEX IF NOT EXISTS idx_likes_user_time ON public.likes (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.user_media_status (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  media_id     BIGINT NOT NULL,
  media_type   TEXT NOT NULL CHECK (media_type IN ('MOVIE','SERIE')),
  title        TEXT,
  poster_path  TEXT,
  vote_average DOUBLE PRECISION,
  status       TEXT NOT NULL CHECK (status IN ('WATCHED','WATCHLIST')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, media_id, media_type)
);
CREATE INDEX IF NOT EXISTS idx_status_user_time ON public.user_media_status (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.media_lists (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  type       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_media_lists_user ON public.media_lists (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.list_items (
  id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  list_id  UUID NOT NULL REFERENCES public.media_lists(id) ON DELETE CASCADE,
  media_id BIGINT NOT NULL,
  added_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_list_items_list ON public.list_items (list_id);

CREATE TABLE IF NOT EXISTS public.reports (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  review_id        UUID REFERENCES public.reviews(id) ON DELETE SET NULL,
  reported_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  reason           TEXT,
  status           TEXT NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING','UNDER_REVIEW','RESOLVED','REJECTED')),
  moderator_id     UUID,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_reports_status ON public.reports (status, created_at DESC);

CREATE TABLE IF NOT EXISTS public.moderation_actions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  moderator_id     UUID NOT NULL,
  target_user_id   UUID,
  target_review_id UUID,
  action_type      TEXT NOT NULL CHECK (action_type IN
                     ('DELETE_REVIEW','BAN_USER','DISABLE_ACCOUNT','REMOVE_MODERATOR_ROLE')),
  reason           TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.audit_logs (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  moderator_id UUID NOT NULL,
  action       TEXT,
  report_id    UUID REFERENCES public.reports(id) ON DELETE SET NULL,
  details      TEXT,
  "timestamp"  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ─── RLS: enable + FORCE on every new table ─────────────────────────────────

DO $rls$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'movieverse_profiles','reviews','likes','user_media_status',
    'media_lists','list_items','reports','moderation_actions','audit_logs'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY;',  t);
  END LOOP;
END $rls$;

-- ─── Policies ───────────────────────────────────────────────────────────────

-- profiles: usernames are public; a user edits only their own row; role/status
-- are NOT writable by `authenticated` (no policy grants it) — only service_role
-- or an admin (auth.is_admin()) may change them.
DROP POLICY IF EXISTS mv_profiles_select        ON public.movieverse_profiles;
CREATE POLICY mv_profiles_select ON public.movieverse_profiles
  FOR SELECT USING (true);
DROP POLICY IF EXISTS mv_profiles_update_self   ON public.movieverse_profiles;
CREATE POLICY mv_profiles_update_self ON public.movieverse_profiles
  FOR UPDATE TO authenticated
  USING (auth.current_user_id() = id) WITH CHECK (auth.current_user_id() = id);
DROP POLICY IF EXISTS mv_profiles_admin_all     ON public.movieverse_profiles;
CREATE POLICY mv_profiles_admin_all ON public.movieverse_profiles
  FOR ALL USING (auth.is_admin()) WITH CHECK (auth.is_admin());

-- reviews: world-readable (shown on every movie page), owner-writable, moderator
-- (or owner) deletable.
DROP POLICY IF EXISTS reviews_select ON public.reviews;
CREATE POLICY reviews_select ON public.reviews FOR SELECT USING (true);
DROP POLICY IF EXISTS reviews_insert ON public.reviews;
CREATE POLICY reviews_insert ON public.reviews
  FOR INSERT TO authenticated WITH CHECK (auth.current_user_id() = user_id);
DROP POLICY IF EXISTS reviews_update ON public.reviews;
CREATE POLICY reviews_update ON public.reviews
  FOR UPDATE TO authenticated
  USING (auth.current_user_id() = user_id) WITH CHECK (auth.current_user_id() = user_id);
DROP POLICY IF EXISTS reviews_delete ON public.reviews;
CREATE POLICY reviews_delete ON public.reviews
  FOR DELETE TO authenticated
  USING (auth.current_user_id() = user_id OR auth.is_moderator());

-- likes / user_media_status / media_lists: strictly owner-scoped CRUD.
DO $own$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['likes','user_media_status','media_lists'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I_owner_all ON public.%I;', t, t);
    EXECUTE format($p$CREATE POLICY %I_owner_all ON public.%I
      FOR ALL TO authenticated
      USING (auth.current_user_id() = user_id)
      WITH CHECK (auth.current_user_id() = user_id);$p$, t, t);
  END LOOP;
END $own$;

-- list_items: owned via the parent list.
DROP POLICY IF EXISTS list_items_owner_all ON public.list_items;
CREATE POLICY list_items_owner_all ON public.list_items
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.media_lists l
                  WHERE l.id = list_id AND l.user_id = auth.current_user_id()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.media_lists l
                  WHERE l.id = list_id AND l.user_id = auth.current_user_id()));

-- reports: a user files their own; moderators see + triage all.
DROP POLICY IF EXISTS reports_insert ON public.reports;
CREATE POLICY reports_insert ON public.reports
  FOR INSERT TO authenticated WITH CHECK (auth.current_user_id() = reporter_id);
DROP POLICY IF EXISTS reports_select ON public.reports;
CREATE POLICY reports_select ON public.reports
  FOR SELECT TO authenticated
  USING (auth.current_user_id() = reporter_id OR auth.is_moderator());
DROP POLICY IF EXISTS reports_update ON public.reports;
CREATE POLICY reports_update ON public.reports
  FOR UPDATE TO authenticated USING (auth.is_moderator()) WITH CHECK (auth.is_moderator());

-- moderation_actions: only moderators, only as themselves.
DROP POLICY IF EXISTS mod_actions_mod ON public.moderation_actions;
CREATE POLICY mod_actions_mod ON public.moderation_actions
  FOR ALL TO authenticated
  USING (auth.is_moderator())
  WITH CHECK (auth.is_moderator() AND auth.current_user_id() = moderator_id);

-- audit_logs: moderators read; rows are written only by the SECURITY DEFINER
-- trigger below (no direct INSERT policy).
DROP POLICY IF EXISTS audit_logs_mod_read ON public.audit_logs;
CREATE POLICY audit_logs_mod_read ON public.audit_logs
  FOR SELECT TO authenticated USING (auth.is_moderator());

-- ─── Triggers ───────────────────────────────────────────────────────────────

-- Provision a movieverse_profiles row on GoTrue signup (own trigger; coexists
-- with 008's handle_new_user). Username from raw_user_meta_data, email-localpart
-- fallback, de-duplicated with a short suffix on collision.
CREATE OR REPLACE FUNCTION public.mv_handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
DECLARE base TEXT; uname TEXT;
BEGIN
  base := COALESCE(
    NULLIF(NEW.raw_user_meta_data->>'username', ''),
    NULLIF(NEW.raw_user_meta_data->>'display_name', ''),
    split_part(COALESCE(NEW.email, 'user'), '@', 1)
  );
  uname := base;
  IF EXISTS (SELECT 1 FROM public.movieverse_profiles WHERE username = uname) THEN
    uname := base || '_' || substr(NEW.id::text, 1, 6);
  END IF;
  INSERT INTO public.movieverse_profiles (id, username, email)
  VALUES (NEW.id, uname, NEW.email)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_mv_handle_new_user ON auth.users;
CREATE TRIGGER trg_mv_handle_new_user
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.mv_handle_new_user();

-- Audit moderation: on a report transitioning to RESOLVED/REJECTED, log it
-- (ports the old trg_audit_moderation). SECURITY DEFINER so it can write
-- audit_logs regardless of the moderator's row grants.
CREATE OR REPLACE FUNCTION public.mv_audit_moderation()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
DECLARE mod_username TEXT;
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status IN ('RESOLVED','REJECTED') THEN
    SELECT username INTO mod_username FROM public.movieverse_profiles WHERE id = NEW.moderator_id;
    INSERT INTO public.audit_logs (moderator_id, action, report_id, details)
    VALUES (NEW.moderator_id, NEW.status, NEW.id,
      'Report ' || NEW.id || ' marked ' ||
      CASE NEW.status WHEN 'RESOLVED' THEN 'accepted' ELSE 'rejected' END ||
      ' by ' || COALESCE(mod_username, NEW.moderator_id::text));
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_mv_audit_moderation ON public.reports;
CREATE TRIGGER trg_mv_audit_moderation
  AFTER UPDATE ON public.reports
  FOR EACH ROW EXECUTE FUNCTION public.mv_audit_moderation();

-- ─── Grants (verb-level; RLS still gates the rows) ───────────────────────────

GRANT SELECT ON public.reviews, public.movieverse_profiles TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON
  public.movieverse_profiles, public.reviews, public.likes, public.user_media_status,
  public.media_lists, public.list_items, public.reports, public.moderation_actions
  TO authenticated;
GRANT SELECT ON public.audit_logs TO authenticated;

INSERT INTO public.schema_migrations (version, name)
VALUES (66, '066_movieverse_schema')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- DOWN (manual, gated): DROP the movieverse tables + helpers + triggers, then
-- DELETE FROM public.schema_migrations WHERE version = 66;
