-- ════════════════════════════════════════════════════════════════
-- grobase-bind-author.sql — server-side authorship binding for Canagrou
--
-- Idempotent (CREATE OR REPLACE FUNCTION + DROP/CREATE TRIGGER → converges on
-- re-run). Apply to the dedicated `canagrou` Postgres database. This is the
-- live-apply slice of the same triggers embedded in grobase-schema.sql, so the
-- orchestrator can harden an already-seeded DB without re-running the full seed.
--
-- The data plane stamps owner_id from the VERIFIED identity: `user:<sub>` when a
-- GoTrue Bearer JWT rides the request, else `api-key:<keyId>` (anonymous app
-- key). These BEFORE INSERT triggers overwrite the social author column from
-- owner_id whenever it carries the `user:` prefix — so a forged client user_id
-- is coerced to the real authenticated sub, server-side. A write WITHOUT a user
-- identity (owner_id NOT `user:%`, i.e. the public app key alone) is REJECTED:
-- authorship cannot be claimed without authentication, so the public key can no
-- longer impersonate any user. READS stay app-key/anonymous (the public wall is
-- unaffected — only authored WRITES require a JWT).
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
