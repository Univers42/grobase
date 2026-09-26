-- Migration 087: GraphQL through PostgREST, the Supabase way.
--
-- Kong's /graphql/v1 route forwards to PostgREST's /rpc/graphql with
-- Content-Profile: graphql_public, and PostgREST now exposes that schema.
-- Nothing served it: pg_graphql was not in the server image and no
-- graphql_public.graphql() existed, so every query got 406 PGRST106.
-- The server image builds pg_graphql (Dockerfile); this creates the
-- extension, the public wrapper the route calls, and the grants.
--
-- Guarded: a server without the extension (an older image) applies this
-- migration as a no-op instead of failing the whole batch.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_graphql') THEN
    RAISE NOTICE 'pg_graphql is not available on this server: /graphql/v1 stays off';
    RETURN;
  END IF;

  CREATE EXTENSION IF NOT EXISTS pg_graphql;
  CREATE SCHEMA IF NOT EXISTS graphql_public;

  -- The RPC PostgREST calls for POST /rpc/graphql with {query, variables, ...}
  CREATE OR REPLACE FUNCTION graphql_public.graphql(
      "operationName" text DEFAULT NULL,
      query           text DEFAULT NULL,
      variables       jsonb DEFAULT NULL,
      extensions      jsonb DEFAULT NULL)
  RETURNS jsonb
  LANGUAGE sql
  AS $fn$
    SELECT graphql.resolve(
      query    := query,
      variables := coalesce(variables, '{}'::jsonb),
      "operationName" := "operationName",
      extensions := extensions);
  $fn$;

  GRANT USAGE ON SCHEMA graphql_public TO anon, authenticated, service_role;
  GRANT USAGE ON SCHEMA graphql TO anon, authenticated, service_role;
  GRANT EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) TO anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA graphql GRANT ALL ON TABLES TO anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA graphql GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA graphql GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
END
$$;

-- PostgREST: pick up the new schema without a restart
NOTIFY pgrst, 'reload schema';

-- Record it (the body above re-runs on every boot; this keeps migrate-status honest).
INSERT INTO public.schema_migrations (version, name)
SELECT 87, '087_graphql_public'
WHERE NOT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 87);
