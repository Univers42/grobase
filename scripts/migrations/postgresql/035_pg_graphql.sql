# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    035_pg_graphql.sql                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/035_pg_graphql.sql
-- Migration: A5 — enable pg_graphql for the /graphql/v1 (PostgREST) endpoint.
-- UP
--
-- PostgREST serves a GraphQL API at /graphql when the `pg_graphql` extension
-- is installed and the `graphql` schema is exposed. Kong's `graphql` service
-- maps /graphql/v1 → postgrest:3000/graphql (see kong.yml).
--
-- HONEST STATUS: the vendored `postgres:16-alpine` image does NOT bundle
-- pg_graphql (it is a Supabase / community extension, not in core/contrib).
-- This migration is therefore AVAILABILITY-GATED: it creates the extension and
-- grants only IF the control files are present in the running image, and emits
-- a NOTICE (never an error) otherwise — so it is safe to run on every stack and
-- becomes a no-op until an image that ships pg_graphql is used.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_graphql') THEN
    CREATE EXTENSION IF NOT EXISTS pg_graphql;

    -- Expose the resolver schema to the API roles so PostgREST can call
    -- graphql.resolve() under the caller's role + RLS. NOTE the real signature
    -- is (query text, variables jsonb, "operationName" text, extensions jsonb)
    -- — the 4th arg is jsonb, not boolean (pg_graphql 1.6.x).
    GRANT USAGE ON SCHEMA graphql TO anon, authenticated, service_role;
    GRANT ALL ON FUNCTION graphql.resolve(text, jsonb, text, jsonb)
      TO anon, authenticated, service_role;

    -- PostgREST has NO native /graphql route. The Supabase-standard bridge is a
    -- `graphql_public.graphql(...)` RPC that wraps graphql.resolve(); PostgREST
    -- exposes it as POST /rpc/graphql (Kong maps /graphql/v1 → /rpc/graphql).
    -- The arg NAMES must match the SDK's JSON body keys (query/variables/
    -- operationName) so PostgREST binds them positionally-by-name.
    CREATE SCHEMA IF NOT EXISTS graphql_public;
    CREATE OR REPLACE FUNCTION graphql_public.graphql(
      "operationName" text DEFAULT NULL,
      query text DEFAULT NULL,
      variables jsonb DEFAULT NULL,
      extensions jsonb DEFAULT NULL
    ) RETURNS jsonb
      LANGUAGE sql
      VOLATILE
    AS $func$
      SELECT graphql.resolve(
        query := query,
        variables := COALESCE(variables, '{}'),
        "operationName" := "operationName",
        extensions := extensions
      );
    $func$;
    GRANT USAGE ON SCHEMA graphql_public TO anon, authenticated, service_role;
    GRANT EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb)
      TO anon, authenticated, service_role;

    RAISE NOTICE 'pg_graphql enabled: /graphql/v1 → /rpc/graphql is live.';
  ELSE
    RAISE NOTICE
      'pg_graphql NOT available in this Postgres image (postgres:16-alpine '
      'does not ship it). /graphql/v1 is wired in Kong but will error until an '
      'image bundling pg_graphql is used. This migration is a no-op for now.';
  END IF;
END
$$;

-- DOWN
-- DROP EXTENSION IF EXISTS pg_graphql;
