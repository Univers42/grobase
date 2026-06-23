-- red-tetris competitive platform schema — applied into the DEDICATED `red-tetris`
-- database by the generic provisioner (scripts/provision-contract.sh). Self-contained
-- + idempotent (IF NOT EXISTS / CREATE OR REPLACE everywhere). Mirrors the vault42
-- RLS discipline: ENABLE + FORCE ROW LEVEL SECURITY, owner_id text, REVOKE from
-- anon/authenticated, GRANT to service_role. The live data-plane path runs as a
-- BYPASSRLS superuser and appends an owner-scope predicate per request (read_scoped);
-- the RLS here is DEFENSE-IN-DEPTH. World-readable tables (leaderboard / profiles /
-- standings) use a permissive USING(true) SELECT and are additionally exposed to
-- cross-owner reads by the mount's `shared_resources` (set in the seed script).
-- anon/authenticated/service_role roles are cluster-wide (grobase db-bootstrap).

-- ─── helper: owner-only policy is repeated; world-readable adds USING(true) read ───

-- profiles: one row per GoTrue user. WORLD-READABLE (any player's profile page),
-- own-row writable. id = auth.users(id) = the JWT `sub`.
CREATE TABLE IF NOT EXISTS public.profiles (
  id          uuid PRIMARY KEY,
  owner_id    text NOT NULL,
  username    text NOT NULL,
  first_name  text,
  last_name   text,
  avatar_url  text,
  country     text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS profiles_username_key ON public.profiles (lower(username));
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS profiles_read ON public.profiles;
CREATE POLICY profiles_read ON public.profiles FOR SELECT USING (true);
DROP POLICY IF EXISTS profiles_write ON public.profiles;
CREATE POLICY profiles_write ON public.profiles FOR ALL
  USING      (owner_id = NULLIF(current_setting('app.current_user_id', true), ''))
  WITH CHECK (owner_id = NULLIF(current_setting('app.current_user_id', true), ''));
REVOKE ALL ON public.profiles FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO service_role;

-- games: one row per finished game. OWNER-SCOPED (a player lists only their own
-- raw games). Posting a game row via /query/v1 publishes row_changed → live boards.
CREATE TABLE IF NOT EXISTS public.games (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id    text NOT NULL,
  player_id   uuid NOT NULL,
  room        text,
  mode        text NOT NULL DEFAULT 'solo',
  score       integer NOT NULL DEFAULT 0,
  lines       integer NOT NULL DEFAULT 0,
  level       integer NOT NULL DEFAULT 1,
  duration_s  integer NOT NULL DEFAULT 0,
  won         boolean NOT NULL DEFAULT false,
  started_at  timestamptz,
  ended_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS games_player_idx ON public.games (player_id, ended_at DESC);
ALTER TABLE public.games ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.games FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS games_owner ON public.games;
CREATE POLICY games_owner ON public.games FOR ALL
  USING      (owner_id = NULLIF(current_setting('app.current_user_id', true), ''))
  WITH CHECK (owner_id = NULLIF(current_setting('app.current_user_id', true), ''));
REVOKE ALL ON public.games FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.games TO service_role;

-- player_stats: derived per-player aggregates (max_score etc.). WORLD-READABLE
-- leaderboard source. Maintained by the apply_game_result trigger on games.
CREATE TABLE IF NOT EXISTS public.player_stats (
  player_id      uuid PRIMARY KEY,
  owner_id       text NOT NULL,
  max_score      integer NOT NULL DEFAULT 0,
  total_games    integer NOT NULL DEFAULT 0,
  total_lines    integer NOT NULL DEFAULT 0,
  total_score    bigint  NOT NULL DEFAULT 0,
  wins           integer NOT NULL DEFAULT 0,
  last_played_at timestamptz
);
ALTER TABLE public.player_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_stats FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS player_stats_read ON public.player_stats;
CREATE POLICY player_stats_read ON public.player_stats FOR SELECT USING (true);
DROP POLICY IF EXISTS player_stats_write ON public.player_stats;
CREATE POLICY player_stats_write ON public.player_stats FOR ALL
  USING      (owner_id = NULLIF(current_setting('app.current_user_id', true), ''))
  WITH CHECK (owner_id = NULLIF(current_setting('app.current_user_id', true), ''));
REVOKE ALL ON public.player_stats FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.player_stats TO service_role;

-- league_tiers: static reference (Bronze..Diamond by rating band). WORLD-READABLE.
CREATE TABLE IF NOT EXISTS public.league_tiers (
  tier       text PRIMARY KEY,
  min_rating integer NOT NULL,
  max_rating integer NOT NULL,
  rank_order integer NOT NULL,
  color      text
);
ALTER TABLE public.league_tiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.league_tiers FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS league_tiers_read ON public.league_tiers;
CREATE POLICY league_tiers_read ON public.league_tiers FOR SELECT USING (true);
REVOKE ALL ON public.league_tiers FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.league_tiers TO service_role;

-- seasons: competitive season lifecycle. WORLD-READABLE.
CREATE TABLE IF NOT EXISTS public.seasons (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  ended_at   timestamptz,
  active     boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX IF NOT EXISTS seasons_one_active ON public.seasons (active) WHERE active;
ALTER TABLE public.seasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seasons FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS seasons_read ON public.seasons;
CREATE POLICY seasons_read ON public.seasons FOR SELECT USING (true);
REVOKE ALL ON public.seasons FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.seasons TO service_role;

-- ratings: per-player ELO rating + current tier for the active season. WORLD-READABLE.
CREATE TABLE IF NOT EXISTS public.ratings (
  player_id   uuid PRIMARY KEY,
  owner_id    text NOT NULL,
  rating      integer NOT NULL DEFAULT 1000,
  league_tier text NOT NULL DEFAULT 'Bronze',
  season_id   uuid,
  games_rated integer NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ratings FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ratings_read ON public.ratings;
CREATE POLICY ratings_read ON public.ratings FOR SELECT USING (true);
DROP POLICY IF EXISTS ratings_write ON public.ratings;
CREATE POLICY ratings_write ON public.ratings FOR ALL
  USING      (owner_id = NULLIF(current_setting('app.current_user_id', true), ''))
  WITH CHECK (owner_id = NULLIF(current_setting('app.current_user_id', true), ''));
REVOKE ALL ON public.ratings FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ratings TO service_role;

-- standings: classement (rank within tier + global) per season. WORLD-READABLE.
-- Rewritten by the scheduled league_recompute function via /query/v1 (→ row_changed
-- → live classement).
CREATE TABLE IF NOT EXISTS public.standings (
  season_id   uuid NOT NULL,
  player_id   uuid NOT NULL,
  owner_id    text NOT NULL,
  league_tier text NOT NULL,
  rank        integer NOT NULL,
  global_rank integer NOT NULL,
  rating      integer NOT NULL,
  points      integer NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, player_id)
);
CREATE INDEX IF NOT EXISTS standings_global_idx ON public.standings (season_id, global_rank);
ALTER TABLE public.standings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.standings FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS standings_read ON public.standings;
CREATE POLICY standings_read ON public.standings FOR SELECT USING (true);
DROP POLICY IF EXISTS standings_write ON public.standings;
CREATE POLICY standings_write ON public.standings FOR ALL
  USING      (owner_id = NULLIF(current_setting('app.current_user_id', true), ''))
  WITH CHECK (owner_id = NULLIF(current_setting('app.current_user_id', true), ''));
REVOKE ALL ON public.standings FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.standings TO service_role;

-- games_leaderboard: the cross-owner read surface (player_stats joined to profiles).
CREATE OR REPLACE VIEW public.games_leaderboard AS
  SELECT s.player_id, p.username, p.country, p.avatar_url,
         s.max_score, s.total_games, s.total_lines, s.wins, s.last_played_at,
         r.rating, r.league_tier
  FROM public.player_stats s
  JOIN public.profiles p ON p.id = s.player_id
  LEFT JOIN public.ratings r ON r.player_id = s.player_id;
GRANT SELECT ON public.games_leaderboard TO service_role;

-- tier_for_rating: map a rating to a league tier name (Bronze..Diamond).
CREATE OR REPLACE FUNCTION public.tier_for_rating(p_rating integer)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT tier FROM public.league_tiers
  WHERE p_rating >= min_rating AND p_rating <= max_rating
  ORDER BY rank_order DESC LIMIT 1
$$;

-- apply_game_result: AFTER INSERT trigger on games. Upserts player_stats and updates
-- the player's ELO rating + tier. Score-anchored ELO (no opponent rating needed):
--   expected = 0.5 (vs an even field); actual = won ? 1.0 : least(0.9, score/5000)
--   K = 32 (<30 games) | 16 (Diamond) | 24 (else); rating floored at 100.
-- SECURITY DEFINER so the derived writes bypass RLS regardless of caller scope.
CREATE OR REPLACE FUNCTION public.apply_game_result()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_rating   integer;
  v_games    integer;
  v_tier     text;
  v_season   uuid;
  k          integer;
  expected   numeric := 0.5;
  actual     numeric;
  delta      integer;
BEGIN
  INSERT INTO public.player_stats (player_id, owner_id, max_score, total_games,
              total_lines, total_score, wins, last_played_at)
  VALUES (NEW.player_id, NEW.owner_id, NEW.score, 1, NEW.lines, NEW.score,
          CASE WHEN NEW.won THEN 1 ELSE 0 END, NEW.ended_at)
  ON CONFLICT (player_id) DO UPDATE SET
    max_score      = GREATEST(public.player_stats.max_score, EXCLUDED.max_score),
    total_games    = public.player_stats.total_games + 1,
    total_lines    = public.player_stats.total_lines + EXCLUDED.total_lines,
    total_score    = public.player_stats.total_score + EXCLUDED.total_score,
    wins           = public.player_stats.wins + (CASE WHEN NEW.won THEN 1 ELSE 0 END),
    last_played_at = EXCLUDED.last_played_at;

  SELECT id INTO v_season FROM public.seasons WHERE active LIMIT 1;
  SELECT rating, games_rated, league_tier INTO v_rating, v_games, v_tier
    FROM public.ratings WHERE player_id = NEW.player_id;
  IF v_rating IS NULL THEN v_rating := 1000; v_games := 0; v_tier := 'Bronze'; END IF;

  k := CASE WHEN v_games < 30 THEN 32 WHEN v_tier = 'Diamond' THEN 16 ELSE 24 END;
  actual := CASE WHEN NEW.won THEN 1.0 ELSE LEAST(0.9, NEW.score::numeric / 5000.0) END;
  delta := round(k * (actual - expected));
  v_rating := GREATEST(100, v_rating + delta);
  v_tier := COALESCE(public.tier_for_rating(v_rating), 'Bronze');

  INSERT INTO public.ratings (player_id, owner_id, rating, league_tier, season_id, games_rated, updated_at)
  VALUES (NEW.player_id, NEW.owner_id, v_rating, v_tier, v_season, 1, now())
  ON CONFLICT (player_id) DO UPDATE SET
    rating = v_rating, league_tier = v_tier, season_id = v_season,
    games_rated = public.ratings.games_rated + 1, updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS games_apply_result ON public.games;
CREATE TRIGGER games_apply_result AFTER INSERT ON public.games
  FOR EACH ROW EXECUTE FUNCTION public.apply_game_result();
