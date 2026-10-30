# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    095_audit_log_retention.sql                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/30 14:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 14:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/095_audit_log_retention.sql
-- Migration 095 (grobase#83, ADR 0022): audit_log retention and GDPR erasure.
--
-- Two functions the orchestrator's gdpr sub-service calls (gdprsvc/audit.go):
--   audit_log_erase_actor(uuid)  anonymises an erased user's rows: actor_id, ip,
--     user_agent and payload become NULL, resource loses its query string, and the
--     user's UUID text is replaced in every row's resource (other actors' too).
--     request_id, action and created_at stay as the security trail. Returns the
--     rows changed; a second call returns 0.
--   audit_log_purge(interval, int)  deletes at most p_batch rows older than
--     p_older_than, oldest id first. Refuses an interval under 30 days or NULL,
--     and a batch that is NULL or outside 1..50000, so a typo cannot empty the table.
-- Both are SECURITY INVOKER: they run with the caller's rights. EXECUTE is for
-- service_role only; PUBLIC, anon and authenticated lose it on every boot, over
-- every public.audit_log_% function, so an old overload cannot stay callable.
-- The created_at index takes a SHARE lock (inserts wait) while it builds, once.
--
-- Caveat: the UUID is matched as text, case-insensitively, in its canonical
-- 8-4-4-4-12 form. A percent-encoded, dash-less or base64 copy of it in resource
-- is not found, nor an email or name in a query string of another actor's row.
--
-- No version guard: the body re-runs on every boot (CREATE OR REPLACE, REVOKE,
-- GRANT, IF NOT EXISTS). A no-op on a database without public.audit_log.
--
-- DOWN (manual, loses retention and erasure):
-- DROP FUNCTION IF EXISTS public.audit_log_erase_actor(uuid);
-- DROP FUNCTION IF EXISTS public.audit_log_purge(interval, integer);
-- DROP INDEX IF EXISTS public.audit_log_created_idx;
-- DELETE FROM public.schema_migrations WHERE version = 95;
DO $$
DECLARE
  f regprocedure;
BEGIN
  IF to_regclass('public.audit_log') IS NULL THEN
    RAISE NOTICE '095: public.audit_log does not exist, nothing to do';
    RETURN;
  END IF;

  CREATE INDEX IF NOT EXISTS audit_log_created_idx ON public.audit_log (created_at);

  CREATE OR REPLACE FUNCTION public.audit_log_erase_actor(p_actor uuid)
  RETURNS bigint LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $fn$
  DECLARE
    v_text constant text := p_actor::text;
    v_own bigint;
    v_other bigint;
  BEGIN
    IF p_actor IS NULL THEN
      RAISE EXCEPTION 'audit_log_erase_actor: p_actor is NULL' USING ERRCODE = '22004';
    END IF;
    UPDATE public.audit_log
       SET actor_id = NULL, ip = NULL, user_agent = NULL, payload = NULL,
           resource = regexp_replace(split_part(resource, '?', 1), v_text, '<erased>', 'gi')
     WHERE actor_id = p_actor;
    GET DIAGNOSTICS v_own = ROW_COUNT;
    -- v_text is hex and dashes only, so it is safe as a pattern and in ILIKE.
    UPDATE public.audit_log
       SET resource = regexp_replace(resource, v_text, '<erased>', 'gi')
     WHERE resource ILIKE '%' || v_text || '%';
    GET DIAGNOSTICS v_other = ROW_COUNT;
    RETURN v_own + v_other;
  END;
  $fn$;

  CREATE OR REPLACE FUNCTION public.audit_log_purge(p_older_than interval, p_batch integer DEFAULT 10000)
  RETURNS bigint LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $fn$
  DECLARE
    v_deleted bigint;
  BEGIN
    IF p_older_than IS NULL THEN
      RAISE EXCEPTION 'audit_log_purge: p_older_than is NULL' USING ERRCODE = '22004';
    END IF;
    IF p_older_than < interval '30 days' THEN
      RAISE EXCEPTION 'audit_log_purge: p_older_than % is under the 30-day floor', p_older_than
        USING ERRCODE = '22023';
    END IF;
    IF p_batch IS NULL THEN
      RAISE EXCEPTION 'audit_log_purge: p_batch is NULL' USING ERRCODE = '22004';
    END IF;
    IF p_batch < 1 OR p_batch > 50000 THEN
      RAISE EXCEPTION 'audit_log_purge: p_batch % is outside 1..50000', p_batch USING ERRCODE = '22023';
    END IF;
    DELETE FROM public.audit_log
     WHERE id IN (SELECT id FROM public.audit_log
                   WHERE created_at < now() - p_older_than
                   ORDER BY id LIMIT p_batch);
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
  END;
  $fn$;

  FOR f IN
    SELECT p.oid::regprocedure FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'audit\_log\_%'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
  GRANT EXECUTE ON FUNCTION public.audit_log_erase_actor(uuid) TO service_role;
  GRANT EXECUTE ON FUNCTION public.audit_log_purge(interval, integer) TO service_role;

  INSERT INTO public.schema_migrations (version, name) VALUES (95, '095_audit_log_retention')
  ON CONFLICT (version) DO NOTHING;
END $$;
