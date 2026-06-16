/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   graphql.test.mjs                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// A5 unit tests for the GraphQL domain (`client.graphql`) — run against the
// BUILT output (`npm run build` first):
//
//   npm test          # = node --test tests/
//
// Transport is mocked via the public `fetch` client option — no network.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createClient, GraphqlClient, MiniBaasError } from '../dist/index.js';
import { routes } from '../dist/core/routes.js';

const BASE_URL = 'https://baas.test';

/** Recording fetch mock: captures every call, answers via `handler`. */
function mockTransport(handler = () => ({})) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), init });
    const { status = 200, body = {} } = handler(String(url), init);
    return new Response(JSON.stringify(body), {
      status,
      headers: { 'Content-Type': 'application/json' },
    });
  };
  return { calls, fetchImpl };
}

function makeClient(transport) {
  return createClient({
    url: BASE_URL,
    anonKey: 'anon-key',
    persistSession: false,
    fetch: transport.fetchImpl,
  });
}

test('client.graphql is a GraphqlClient wired into the main client', () => {
  const client = makeClient(mockTransport());
  assert.ok(client.graphql instanceof GraphqlClient);
});

test('routes.graphql.root is /graphql/v1', () => {
  assert.equal(routes.graphql.root, '/graphql/v1');
});

test('graphql.query() POSTs { query } to /graphql/v1 and returns the envelope', async () => {
  const payload = { data: { todosCollection: { edges: [{ node: { id: '1', title: 'a' } }] } } };
  const transport = mockTransport(() => ({ body: payload }));
  const client = makeClient(transport);

  const doc = 'query { todosCollection { edges { node { id title } } } }';
  const res = await client.graphql.query(doc);

  assert.deepEqual(res, payload);
  assert.equal(transport.calls.length, 1);
  assert.equal(transport.calls[0].url, `${BASE_URL}/graphql/v1`);
  assert.equal(transport.calls[0].init.method, 'POST');
  assert.deepEqual(JSON.parse(transport.calls[0].init.body), { query: doc });
});

test('graphql.query() includes variables and operationName when provided', async () => {
  const transport = mockTransport(() => ({ body: { data: {} } }));
  const client = makeClient(transport);

  const doc = 'query Q($first: Int!) { todosCollection(first: $first) { edges { node { id } } } }';
  await client.graphql.query(doc, { first: 5 }, { operationName: 'Q' });

  const sent = JSON.parse(transport.calls[0].init.body);
  assert.deepEqual(sent, { query: doc, variables: { first: 5 }, operationName: 'Q' });
});

test('graphql.query() omits variables/operationName when not provided', async () => {
  const transport = mockTransport(() => ({ body: { data: {} } }));
  const client = makeClient(transport);

  await client.graphql.query('query { __typename }');
  const sent = JSON.parse(transport.calls[0].init.body);
  assert.deepEqual(Object.keys(sent), ['query'], 'only `query` key is sent');
});

test('graphql.query() sends the apikey header (REST-style auth posture)', async () => {
  const transport = mockTransport(() => ({ body: { data: {} } }));
  const client = makeClient(transport);

  await client.graphql.query('query { __typename }');
  const headers = new Headers(transport.calls[0].init.headers);
  assert.equal(headers.get('apikey'), 'anon-key');
  assert.equal(headers.get('content-type'), 'application/json');
});

test('graphql.query() does NOT throw on GraphQL-level errors in a 200 response', async () => {
  const body = { errors: [{ message: 'field "nope" does not exist' }] };
  const transport = mockTransport(() => ({ status: 200, body }));
  const client = makeClient(transport);

  const res = await client.graphql.query('query { nope }');
  assert.equal(res.data, undefined);
  assert.equal(res.errors?.length, 1);
  assert.match(res.errors[0].message, /does not exist/);
});

test('graphql.query() surfaces a non-2xx transport status as MiniBaasError', async () => {
  const transport = mockTransport(() => ({
    status: 503,
    body: { message: 'pg_graphql extension not installed' },
  }));
  const client = makeClient(transport);

  await assert.rejects(
    client.graphql.query('query { __typename }'),
    (err) => err instanceof MiniBaasError && err.status === 503,
  );
});
