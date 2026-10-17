-- A COPY of the schema contract in .groot-collab/2026-10-17/p1-contract.md, so the
-- authz tests and the m231/m232 gates run against a bare postgres before unit A's
-- scripts/migrations/postgresql/091_authz_tuples.sql lands. At merge the gates apply 091
-- instead (AUTHZ_SCHEMA_SQL) and this file is deleted.
-- Caveat: a copy, not the migration; if 091 differs from the contract (index set, grants,
-- primitive body) these tests prove the contract, not 091. Re-run them against 091.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;
END $$;

CREATE SCHEMA IF NOT EXISTS authz;

CREATE TABLE IF NOT EXISTS authz.tuples (
  app text NOT NULL, object_type text NOT NULL, object_id text NOT NULL, relation text NOT NULL,
  subject_type text NOT NULL, subject_id text NOT NULL, subject_relation text NOT NULL DEFAULT '',
  source text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (app, object_type, object_id, relation, subject_type, subject_id, subject_relation, source)
);
CREATE INDEX IF NOT EXISTS tuples_subject_idx ON authz.tuples (app, subject_type, subject_id);
CREATE TABLE IF NOT EXISTS authz.models (
  app text PRIMARY KEY, model jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION authz.replace_source_tuples(
  p_app text, p_object_type text, p_object_id text, p_source text, p_tuples jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, authz AS $$
DECLARE n integer := 0; k integer;
BEGIN
  IF coalesce(p_app, '') = '' OR coalesce(p_object_type, '') = '' OR coalesce(p_object_id, '') = ''
     OR coalesce(p_source, '') = '' OR jsonb_typeof(p_tuples) IS DISTINCT FROM 'array'
     OR length(p_object_id) > 256 THEN
    RAISE EXCEPTION 'invalid replace_source_tuples input' USING ERRCODE = '22023';
  END IF;
  CREATE TEMP TABLE want ON COMMIT DROP AS
    SELECT DISTINCT t->>'relation' AS relation, t->>'subject_type' AS subject_type,
           t->>'subject_id' AS subject_id, coalesce(t->>'subject_relation', '') AS subject_relation
      FROM jsonb_array_elements(p_tuples) t;
  DELETE FROM authz.tuples x
   WHERE x.app = p_app AND x.object_type = p_object_type AND x.object_id = p_object_id
     AND x.source = p_source
     AND NOT EXISTS (SELECT 1 FROM want w WHERE w.relation = x.relation AND w.subject_type = x.subject_type
                       AND w.subject_id = x.subject_id AND w.subject_relation = x.subject_relation);
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  INSERT INTO authz.tuples (app, object_type, object_id, relation, subject_type, subject_id, subject_relation, source)
    SELECT p_app, p_object_type, p_object_id, w.relation, w.subject_type, w.subject_id, w.subject_relation, p_source
      FROM want w
    ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  DROP TABLE want;
  RETURN n;
END $$;

REVOKE ALL ON SCHEMA authz FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA authz FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION authz.replace_source_tuples(text, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA authz TO service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA authz TO service_role;
GRANT EXECUTE ON FUNCTION authz.replace_source_tuples(text, text, text, text, jsonb) TO service_role;
