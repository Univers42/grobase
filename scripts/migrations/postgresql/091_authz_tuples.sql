-- Migration 091: authz relationship tuples, source-owned (P1 store).
--
-- authz.tuples holds "subject has relation on object" facts for one app. Every row is OWNED by
-- the `source` that derived it (a page row, a share rule, a membership row), and `source` is in
-- the primary key. Two sources that derive the same grant therefore own two rows, never one
-- shared row. With a shared row, READ COMMITTED lets two concurrent removals each keep the grant
-- because each still sees the other source (stale, fail-open), and two concurrent adds collide
-- on the key (23505) or deadlock through the index (40P01). Devil round 2, N1a-N1d; reproduced
-- and fixed in scripts/verify/m233-authz-source-races.sh. The PK is a one-way door once rows
-- exist, which is why `source` ships in this first version. The evaluator reads DISTINCT subjects.
--
-- authz.replace_source_tuples replaces the tuple set of one (app, object, source) pair, diffing
-- desired against current: an unchanged set writes 0 rows, '[]' removes the pair. It never reads
-- authz.models and sends no pg_notify (N2: a commit-time NOTIFY serializes on a cluster-wide
-- lock, measured -25% tps; P5 reintroduces it with its consumer).
--
-- Access (C1): anon and authenticated lose everything, directly and through PostgREST RPC.
-- service_role may read the tables and run the primitive. tenant-control connects as the
-- database owner (DATABASE_URL user "postgres", scripts/env/generate-env.sh:68,98), which
-- already reads tuples and writes models, so no extra grant exists for it.
--
-- Caveat: the primitive's inserts are ON CONFLICT DO NOTHING, so two transactions replacing the
-- SAME (object, source) at once can both report a change for one row. The count is advisory;
-- the stored set is correct. Domain-row locks normally serialize those writers anyway.
-- Idempotent; re-runs on every boot.
--
-- DOWN (manual, destroys every tuple): DROP SCHEMA authz CASCADE;
BEGIN;

CREATE SCHEMA IF NOT EXISTS authz;

CREATE TABLE IF NOT EXISTS authz.tuples (
  app              text        NOT NULL,
  object_type      text        NOT NULL,
  object_id        text        NOT NULL,
  relation         text        NOT NULL,
  subject_type     text        NOT NULL,
  subject_id       text        NOT NULL,
  subject_relation text        NOT NULL DEFAULT '',
  source           text        NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (app, object_type, object_id, relation, subject_type, subject_id, subject_relation, source)
);

-- Forward lookups (app, object_type, object_id, relation) are the PK prefix: a second index would
-- only add write cost. The reverse lookup (which objects a subject reaches) has no prefix.
CREATE INDEX IF NOT EXISTS tuples_subject_idx ON authz.tuples (app, subject_type, subject_id);

CREATE TABLE IF NOT EXISTS authz.models (
  app        text        PRIMARY KEY,
  model      jsonb       NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION authz.replace_source_tuples(
  p_app text, p_object_type text, p_object_id text, p_source text, p_tuples jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, authz
AS $fn$
DECLARE
  el        jsonb;
  n_deleted integer;
  n_added   integer;
BEGIN
  IF p_app IS NULL OR p_app = '' OR length(p_app) > 128 THEN
    RAISE EXCEPTION 'authz: app must be 1-128 characters' USING ERRCODE = '22023';
  END IF;
  IF p_object_type IS NULL OR p_object_type !~ '^[a-z][a-z0-9_]{0,62}$' THEN
    RAISE EXCEPTION 'authz: object_type must match ^[a-z][a-z0-9_]{0,62}$' USING ERRCODE = '22023';
  END IF;
  IF p_object_id IS NULL OR p_object_id = '' OR length(p_object_id) > 256 OR position('#' IN p_object_id) > 0 THEN
    RAISE EXCEPTION 'authz: object_id must be 1-256 characters without #' USING ERRCODE = '22023';
  END IF;
  IF p_source IS NULL OR p_source = '' OR length(p_source) > 256 THEN
    RAISE EXCEPTION 'authz: source must be 1-256 characters' USING ERRCODE = '22023';
  END IF;
  IF p_tuples IS NULL OR jsonb_typeof(p_tuples) <> 'array' OR jsonb_array_length(p_tuples) > 10000 THEN
    RAISE EXCEPTION 'authz: tuples must be a JSON array of at most 10000 entries' USING ERRCODE = '22023';
  END IF;

  FOR el IN SELECT value FROM jsonb_array_elements(p_tuples) LOOP
    IF jsonb_typeof(el) <> 'object'
       OR jsonb_typeof(el->'relation') IS DISTINCT FROM 'string'
       OR jsonb_typeof(el->'subject_type') IS DISTINCT FROM 'string'
       OR jsonb_typeof(el->'subject_id') IS DISTINCT FROM 'string'
       OR coalesce(jsonb_typeof(el->'subject_relation'), 'string') <> 'string'
       OR el->>'relation' !~ '^[a-z][a-z0-9_]{0,62}$'
       OR el->>'subject_type' !~ '^[a-z][a-z0-9_]{0,62}$'
       OR coalesce(el->>'subject_relation', '') !~ '^([a-z][a-z0-9_]{0,62})?$'
       OR el->>'subject_id' = '' OR length(el->>'subject_id') > 256
       OR position('#' IN el->>'subject_id') > 0 THEN
      RAISE EXCEPTION 'authz: malformed tuple %', left(el::text, 200) USING ERRCODE = '22023';
    END IF;
  END LOOP;

  WITH desired AS (
    SELECT DISTINCT t->>'relation' AS relation, t->>'subject_type' AS subject_type,
           t->>'subject_id' AS subject_id, coalesce(t->>'subject_relation', '') AS subject_relation
      FROM jsonb_array_elements(p_tuples) t
  ), removed AS (
    DELETE FROM authz.tuples x
     WHERE x.app = p_app AND x.object_type = p_object_type AND x.object_id = p_object_id
       AND x.source = p_source
       AND NOT EXISTS (SELECT 1 FROM desired d
                        WHERE d.relation = x.relation AND d.subject_type = x.subject_type
                          AND d.subject_id = x.subject_id AND d.subject_relation = x.subject_relation)
    RETURNING 1
  ), added AS (
    INSERT INTO authz.tuples (app, object_type, object_id, relation, subject_type, subject_id,
                              subject_relation, source)
    SELECT p_app, p_object_type, p_object_id, d.relation, d.subject_type, d.subject_id,
           d.subject_relation, p_source
      FROM desired d
     WHERE NOT EXISTS (SELECT 1 FROM authz.tuples x
                        WHERE x.app = p_app AND x.object_type = p_object_type
                          AND x.object_id = p_object_id AND x.source = p_source
                          AND x.relation = d.relation AND x.subject_type = d.subject_type
                          AND x.subject_id = d.subject_id AND x.subject_relation = d.subject_relation)
    ON CONFLICT DO NOTHING
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM removed), (SELECT count(*) FROM added) INTO n_deleted, n_added;

  RETURN n_deleted + n_added;
END
$fn$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC by default; the roles may not exist in a per-app DB.
REVOKE ALL ON SCHEMA authz FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA authz FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA authz FROM PUBLIC;
DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA authz FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA authz FROM %I', r);
      EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA authz FROM %I', r);
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT USAGE ON SCHEMA authz TO service_role;
    GRANT SELECT ON authz.tuples, authz.models TO service_role;
    GRANT EXECUTE ON FUNCTION authz.replace_source_tuples(text, text, text, text, jsonb) TO service_role;
  END IF;
END
$$;

-- Record it (the body above re-runs on every boot; this keeps migrate-status honest).
INSERT INTO public.schema_migrations (version, name)
SELECT 91, '091_authz_tuples'
WHERE NOT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 91);
COMMIT;
