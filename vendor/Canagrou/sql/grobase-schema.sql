-- ════════════════════════════════════════════════════════════════
-- CANAGRU — Grobase data-plane schema (PostgreSQL)
--
-- Applied by scripts/seed/canagrou-tenant.sh into the DEDICATED `canagrou`
-- database on the stack's own postgres (NOT the shared `postgres` DB — its
-- public schema already holds unrelated posts/likes tables from another
-- playground). A dedicated DB keeps Canagrou's `public` schema clean; realtime
-- still fires via the query-router app-publish path (topic table:<dbId>:<tbl>),
-- which is mount-agnostic, so writes through /query/v1 reflect live.
--
-- Identity is split: GoTrue's auth.users (in the shared postgres DB) owns
-- email / password / confirmation / recovery; `profiles` here owns the app
-- fields (username, notify_comments) and is keyed by the GoTrue user id (sub).
--
-- owner_id is the data-plane scope column the gateway DDL path would auto-add;
-- created here explicitly. With a single app API key every row carries the same
-- owner_id (api-key:<key_id>) — correct for a PUBLIC photo wall (all posts
-- visible to the app). Per-user identity is carried by user_id, not owner_id.
-- ════════════════════════════════════════════════════════════════

-- ── profiles: app-side identity, 1:1 with GoTrue auth.users ─────────
CREATE TABLE IF NOT EXISTS public.profiles (
    id              text PRIMARY KEY,                    -- = auth.users.id (GoTrue sub uuid)
    username        varchar(30)  NOT NULL UNIQUE,
    notify_comments boolean      NOT NULL DEFAULT true,
    owner_id        text,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now()
);

-- ── posts: a LinkedIn-style feed entry — text (≤500), optional media, reposts ──
CREATE TABLE IF NOT EXISTS public.posts (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id        text         NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    content        text         CONSTRAINT posts_content_len CHECK (content IS NULL OR char_length(content) <= 500),
    image_key      text,                                 -- storage object key; NULL for text-only posts
    shared_post_id bigint       REFERENCES public.posts(id) ON DELETE SET NULL,  -- repost/share of another post
    owner_id       text,
    created_at     timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_posts_user ON public.posts (user_id);
CREATE INDEX IF NOT EXISTS idx_posts_date ON public.posts (created_at DESC);

-- ── likes (one per user per post) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS public.likes (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id   text   NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    post_id   bigint NOT NULL REFERENCES public.posts(id)    ON DELETE CASCADE,
    owner_id  text,
    CONSTRAINT uq_likes_user_post UNIQUE (user_id, post_id)
);
CREATE INDEX IF NOT EXISTS idx_likes_post ON public.likes (post_id);

-- ── comments ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.comments (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    text         NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    post_id    bigint       NOT NULL REFERENCES public.posts(id)    ON DELETE CASCADE,
    content    text         NOT NULL,
    owner_id   text,
    created_at timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_comments_post ON public.comments (post_id);

-- ════════════════════════════════════════════════════════════════
-- SERVER-SIDE AUTHORSHIP BINDING (anti-impersonation)
--
-- The data plane stamps owner_id from the VERIFIED identity: `user:<sub>` when a
-- GoTrue Bearer JWT rides the request, else `api-key:<keyId>` (anonymous app
-- key). The social `user_id`/`id` column is client-supplied and would otherwise
-- let any holder of the public app key forge another user's authorship.
--
-- These BEFORE INSERT triggers overwrite the author column from owner_id whenever
-- owner_id carries the `user:` prefix — so a forged client user_id is coerced to
-- the real authenticated sub, SERVER-SIDE, before the row lands. When owner_id is
-- NOT a user principal (anonymous app-key writes, e.g. the m146 gate's seeded
-- rows), the client value passes through unchanged: the public wall stays public
-- and owner-scoping is unaffected (reads remain unscoped; only authorship binds).
-- Idempotent: CREATE OR REPLACE FUNCTION + DROP/CREATE TRIGGER converge on re-run.
-- ════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.bind_author_from_owner()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.owner_id LIKE 'user:%' THEN
        NEW.user_id := substring(NEW.owner_id FROM 6);
    ELSE
        RAISE EXCEPTION 'authorship requires authentication: no user identity on the request'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.bind_profile_id_from_owner()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.owner_id LIKE 'user:%' THEN
        NEW.id := substring(NEW.owner_id FROM 6);
    ELSE
        RAISE EXCEPTION 'profile creation requires authentication: no user identity on the request'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_bind_author_posts ON public.posts;
CREATE TRIGGER trg_bind_author_posts
    BEFORE INSERT ON public.posts
    FOR EACH ROW EXECUTE FUNCTION public.bind_author_from_owner();

DROP TRIGGER IF EXISTS trg_bind_author_likes ON public.likes;
CREATE TRIGGER trg_bind_author_likes
    BEFORE INSERT ON public.likes
    FOR EACH ROW EXECUTE FUNCTION public.bind_author_from_owner();

DROP TRIGGER IF EXISTS trg_bind_author_comments ON public.comments;
CREATE TRIGGER trg_bind_author_comments
    BEFORE INSERT ON public.comments
    FOR EACH ROW EXECUTE FUNCTION public.bind_author_from_owner();

DROP TRIGGER IF EXISTS trg_bind_profile_id ON public.profiles;
CREATE TRIGGER trg_bind_profile_id
    BEFORE INSERT ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.bind_profile_id_from_owner();
