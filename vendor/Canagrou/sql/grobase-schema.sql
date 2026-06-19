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
