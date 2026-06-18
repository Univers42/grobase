/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema.test.mjs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/09 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/09 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// Unit tests for the M22 schema domain (`client.schema`) — run with the Node
// built-in test runner against the BUILT output (`npm run build` first):
//
//   npm test          # = node --test tests/
//
// Docker-first (no host node):
//   docker run --rm -v "$PWD":/work -w /work node:20-alpine \
//     sh -lc 'npm run build && npm test'
//
// The transport is mocked through the public `fetch` client option — no
// network, no servers. Compile-time contracts live in
// `src/__type_tests__/schema.test-d.ts` (npm run typecheck).

import test from 'node:test';
import assert from 'node:assert/strict';
import { createClient, MiniBaasError, SchemaClient } from '../dist/index.js';
import { routes } from '../dist/core/routes.js';

const BASE_URL = 'https://baas.test';
const DB_ID = '4ee63a30-0000-4000-8000-000000000000';

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

test('client.schema is a SchemaClient wired into the main client', () => {
  const client = makeClient(mockTransport());
  assert.ok(client.schema instanceof SchemaClient);
});

test('schema.describe() GETs /query/v1/:dbId/schema and returns the wire payload', async () => {
  const payload = {
    dbId: DB_ID,
    engine: 'postgresql',
    capabilities: { read: true, write: true, upsert: false, introspect: true, schema_ddl: true, stream: false, ddl: true, transactions: true },
    tables: [
      {
        name: 'todos',
        primary_key: ['id'],
        columns: [
          { name: 'id', native_type: 'uuid', normalized_type: 'uuid', nullable: false, default: 'gen_random_uuid()', enum_values: null, references: null, inferred: false },
        ],
      },
    ],
  };
  const transport = mockTransport(() => ({ body: payload }));
  const client = makeClient(transport);

  const schema = await client.schema.describe(DB_ID);

  assert.deepEqual(schema, payload);
  assert.equal(transport.calls.length, 1);
  assert.equal(transport.calls[0].url, `${BASE_URL}/query/v1/${DB_ID}/schema`);
  assert.equal(transport.calls[0].init.method, 'GET');
});

test('schema.ddl() refuses drop_table without confirm BEFORE any network call', () => {
  const transport = mockTransport();
  const client = makeClient(transport);

  assert.throws(
    () => client.schema.ddl(DB_ID, { op: 'drop_table', table: 'notes' }),
    /destructive.*"confirm": true/,
  );
  assert.equal(transport.calls.length, 0, 'no request must be sent');
});

test('schema.ddl() refuses drop_column with confirm:false BEFORE any network call', () => {
  const transport = mockTransport();
  const client = makeClient(transport);

  assert.throws(
    () => client.schema.ddl(DB_ID, { op: 'drop_column', table: 'todos', column_name: 'done', confirm: false }),
    /destructive/,
  );
  assert.equal(transport.calls.length, 0, 'no request must be sent');
});

test('schema.ddl() POSTs the op to /query/v1/:dbId/schema/ddl and returns the result', async () => {
  const result = { op: 'drop_table', table: 'notes', status: 'applied', dbId: DB_ID };
  const transport = mockTransport(() => ({ body: result }));
  const client = makeClient(transport);

  const input = { op: 'drop_table', table: 'notes', confirm: true };
  const out = await client.schema.ddl(DB_ID, input);

  assert.deepEqual(out, result);
  assert.equal(transport.calls.length, 1);
  assert.equal(transport.calls[0].url, `${BASE_URL}/query/v1/${DB_ID}/schema/ddl`);
  assert.equal(transport.calls[0].init.method, 'POST');
  assert.deepEqual(JSON.parse(transport.calls[0].init.body), input);
});

test('schema.ddl() forwards non-destructive ops without a confirm gate', async () => {
  const transport = mockTransport(() => ({ body: { op: 'add_column', table: 'todos', status: 'applied', dbId: DB_ID } }));
  const client = makeClient(transport);

  const input = { op: 'add_column', table: 'todos', column: { name: 'done', normalized_type: 'boolean', nullable: false, default: 'false' } };
  await client.schema.ddl(DB_ID, input);

  assert.equal(transport.calls.length, 1);
  assert.deepEqual(JSON.parse(transport.calls[0].init.body), input);
});

test('schema errors surface as MiniBaasError with the gateway status', async () => {
  const transport = mockTransport(() => ({
    status: 422,
    body: { error: 'unsupported_capability', message: "engine 'redis' does not support introspect" },
  }));
  const client = makeClient(transport);

  await assert.rejects(
    client.schema.describe(DB_ID),
    (err) => err instanceof MiniBaasError && err.status === 422,
  );
});

test('routes.realtime.tableChannel() composes with client.realtimeUrl()', () => {
  const client = makeClient(mockTransport());

  const topic = routes.realtime.tableChannel(DB_ID, 'todos');
  assert.equal(topic, `table:${DB_ID}:todos`);

  const url = new URL(client.realtimeUrl(topic));
  assert.equal(url.protocol, 'wss:');
  assert.equal(url.pathname, '/realtime/v1/ws');
  assert.equal(url.searchParams.get('channel'), topic);
});

test('routes.query.schema()/schemaDdl() build the documented paths', () => {
  assert.equal(routes.query.schema(DB_ID), `/query/v1/${DB_ID}/schema`);
  assert.equal(routes.query.schemaDdl(DB_ID), `/query/v1/${DB_ID}/schema/ddl`);
});
