-- File: scripts/migrations/postgresql/067_movieverse_like_counts.sql
-- Migration 067 (MovieVerse on Grobase): public like-count RPC.
--
-- public.likes is owner-scoped (066: a user SELECTs only their own rows), so the
-- detail page cannot read a GLOBAL like total directly. This SECURITY DEFINER
-- function returns the count across all users WITHOUT exposing who liked what —
-- the faithful port of the old MySQL `count(*)` while keeping like identity
-- private. Callable by anon + authenticated via PostgREST: POST
-- /rest/v1/rpc/like_count {"p_media_id":123,"p_media_type":"MOVIE"}.
--
-- ADDITIVE + idempotent (CREATE OR REPLACE / ON CONFLICT). The reusable pattern:
-- "public aggregate over a private table" = a SECURITY DEFINER counting function,
-- never a public-read policy that would leak the rows themselves.

BEGIN;

CREATE OR REPLACE FUNCTION public.like_count(p_media_id BIGINT, p_media_type TEXT)
RETURNS BIGINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT count(*) FROM public.likes
  WHERE media_id = p_media_id AND media_type = p_media_type;
$$;

GRANT EXECUTE ON FUNCTION public.like_count(BIGINT, TEXT) TO anon, authenticated, service_role;

INSERT INTO public.schema_migrations (version, name)
VALUES (67, '067_movieverse_like_counts')
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- DOWN (manual): DROP FUNCTION public.like_count(BIGINT, TEXT);
--                DELETE FROM public.schema_migrations WHERE version = 67;
