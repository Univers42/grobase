/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   graphql.ts                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// A5 — GraphQL passthrough to PostgREST's pg_graphql endpoint.
//
// Wire :  SDK  →  Kong (`/graphql/v1`)  →  postgrest:3000/graphql
//
// PostgREST serves a GraphQL API at `/graphql` when the `pg_graphql` Postgres
// extension is installed. The Kong `graphql` service strips `/graphql/v1` to
// `/graphql` and applies the same key-auth + JWT + rate-limit posture as REST,
// so queries execute under the caller's PostgREST role and RLS.
//
// IMPORTANT (honest status): the vendored `postgres:16-alpine` image does NOT
// ship pg_graphql. This client + the Kong route are wired and correct, but the
// endpoint returns an error until Postgres has the extension (see
// `scripts/migrations/postgresql/035_pg_graphql.sql`, gated on availability).

import { routes } from '../core/routes.js';
import type { HttpClient } from '../core/http.js';
import type {
  GraphqlQueryOptions,
  GraphqlRequest,
  GraphqlResponse,
} from '../types.js';

/**
 * GraphQL client (`/graphql/v1`).
 *
 * Posts a GraphQL document + variables and returns the full
 * {@link GraphqlResponse} envelope (`data` and/or `errors`). The SDK does NOT
 * throw on GraphQL-level `errors` (those are part of a 200 response per the
 * GraphQL-over-HTTP spec); it only throws a {@link MiniBaasError} on a non-2xx
 * transport/auth status. Inspect `result.errors` yourself.
 */
export class GraphqlClient {
  constructor(private readonly http: HttpClient) {}

  /**
   * Execute a GraphQL `query` or `mutation` document.
   *
   * @example
   *   const res = await client.graphql.query<{ todosCollection: { edges: [] } }>(
   *     `query($first: Int!) { todosCollection(first: $first) { edges { node { id title } } } }`,
   *     { first: 10 },
   *   );
   *   if (res.errors) console.warn(res.errors);
   *   console.log(res.data?.todosCollection.edges);
   */
  query<Data = Record<string, unknown>, Variables = Record<string, unknown>>(
    document: string,
    variables?: Variables,
    options: GraphqlQueryOptions = {},
  ): Promise<GraphqlResponse<Data>> {
    const body: GraphqlRequest<Variables> = { query: document };
    if (variables !== undefined) body.variables = variables;
    if (options.operationName !== undefined) body.operationName = options.operationName;

    return this.http.request<GraphqlResponse<Data>>(routes.graphql.root, {
      method: 'POST',
      headers: options.headers,
      body,
    });
  }
}
