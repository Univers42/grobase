/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   rest-builder.test.mjs                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// Unit tests for the A3 fluent REST query builder (supabase-js-shaped
// .select/.eq/.in/.or/.order/.range/.single chaining on client.from().query()).
// Transport mocked via the `fetch` option; no network. Asserts the chained
// builder produces the same PostgREST request shape as the options-object API.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createClient, RestQueryBuilder } from '../dist/index.js';

const BASE_URL = 'https://baas.test';

function mockTransport(handler = () => ({})) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), init });
    const { status = 200, body = [], raw } = handler(String(url), init);
    const payload = raw !== undefined ? raw : JSON.stringify(body);
    return new Response(payload, { status, headers: { 'Content-Type': 'application/json' } });
  };
  return { calls, fetchImpl };
}

function makeClient(transport) {
  return createClient({ url: BASE_URL, anonKey: 'anon-key', persistSession: false, fetch: transport.fetchImpl });
}

/** Decode the query string of the (single) recorded call into [k, v] pairs. */
function paramsOf(transport) {
  const url = new URL(transport.calls[0].url);
  return [...url.searchParams.entries()];
}

test('from(t).query() returns a RestQueryBuilder; back-compat select(options) still works', async () => {
  const transport = mockTransport(() => ({ body: [{ id: 1 }] }));
  const client = makeClient(transport);

  const builder = client.from('users').query();
  assert.ok(builder instanceof RestQueryBuilder);

  // Old options-object API untouched.
  const rows = await client.from('users').select({ columns: 'id', limit: 1 });
  assert.deepEqual(rows, [{ id: 1 }]);
  assert.equal(transport.calls[0].init.method, 'GET');
});

test('chained filters build the PostgREST request shape (eq/neq/gt/like/order/limit)', async () => {
  const transport = mockTransport(() => ({ body: [] }));
  const client = makeClient(transport);

  await client
    .from('users')
    .query()
    .select('id,name')
    .eq('active', true)
    .neq('role', 'banned')
    .gt('age', 18)
    .like('name', 'Al%')
    .order('created_at', { ascending: false })
    .limit(10);

  const url = new URL(transport.calls[0].url);
  assert.equal(url.pathname, '/rest/v1/users');
  assert.equal(transport.calls[0].init.method, 'GET');
  assert.deepEqual(paramsOf(transport), [
    ['select', 'id,name'],
    ['limit', '10'],
    ['order', 'created_at.desc'],
    ['active', 'eq.true'],
    ['role', 'neq.banned'],
    ['age', 'gt.18'],
    ['name', 'like.Al%'],
  ]);
});

test('.in(col, [...]) emits PostgREST in.(a,b,c) and quotes values with commas', async () => {
  const transport = mockTransport(() => ({ body: [] }));
  const client = makeClient(transport);

  await client.from('items').query().in('id', [1, 2, 3]).in('tag', ['a,b', 'c']);
  const params = paramsOf(transport);
  assert.deepEqual(params, [
    ['id', 'in.(1,2,3)'],
    ['tag', 'in.("a,b",c)'],
  ]);
});

test('.or(filter) emits a parenthesised or= group', async () => {
  const transport = mockTransport(() => ({ body: [] }));
  const client = makeClient(transport);

  await client.from('users').query().or('age.gt.18,name.eq.Al');
  assert.deepEqual(paramsOf(transport), [['or', '(age.gt.18,name.eq.Al)']]);
});

test('.range(from,to) maps to offset + inclusive limit', async () => {
  const transport = mockTransport(() => ({ body: [] }));
  const client = makeClient(transport);

  await client.from('rows').query().range(10, 19);
  const url = new URL(transport.calls[0].url);
  assert.equal(url.searchParams.get('offset'), '10');
  assert.equal(url.searchParams.get('limit'), '10'); // 19 - 10 + 1
});

test('.single() sets the pgrst object Accept header and returns one row', async () => {
  const transport = mockTransport(() => ({ body: { id: 7, name: 'Solo' } }));
  const client = makeClient(transport);

  const row = await client.from('users').query().eq('id', 7).single();
  assert.deepEqual(row, { id: 7, name: 'Solo' });
  assert.equal(new Headers(transport.calls[0].init.headers).get('Accept'), 'application/vnd.pgrst.object+json');
});

test('.single() unwraps the first element when the server returns an array', async () => {
  const transport = mockTransport(() => ({ body: [{ id: 1 }, { id: 2 }] }));
  const client = makeClient(transport);
  const row = await client.from('users').query().single();
  assert.deepEqual(row, { id: 1 });
});

test('.maybeSingle() returns null when no rows match', async () => {
  const transport = mockTransport(() => ({ body: [] }));
  const client = makeClient(transport);
  const row = await client.from('users').query().eq('id', 999).maybeSingle();
  assert.equal(row, null);
});

test('the builder is lazy: no request until awaited', async () => {
  const transport = mockTransport(() => ({ body: [] }));
  const client = makeClient(transport);

  const b = client.from('users').query().eq('a', 1);
  assert.equal(transport.calls.length, 0, 'no fetch before await');
  await b;
  assert.equal(transport.calls.length, 1, 'one fetch after await');
});

test('chained builder URL matches the equivalent options-object select URL', async () => {
  const t1 = mockTransport(() => ({ body: [] }));
  const c1 = makeClient(t1);
  await c1.from('users').query().select('id,name').eq('active', true).limit(5);

  const t2 = mockTransport(() => ({ body: [] }));
  const c2 = makeClient(t2);
  await c2.from('users').select({
    columns: 'id,name',
    limit: 5,
    filters: [{ column: 'active', operator: 'eq', value: true }],
  });

  // Same path + same param multiset (order of select/limit vs filter differs,
  // but PostgREST is order-insensitive; compare as sorted sets).
  const sortPairs = (t) => paramsOf(t).map(([k, v]) => `${k}=${v}`).sort();
  assert.deepEqual(sortPairs(t1), sortPairs(t2));
});

test('builder surfaces a non-2xx as a rejection (MiniBaasError-shaped)', async () => {
  const transport = mockTransport(() => ({ status: 400, body: { message: 'bad filter' } }));
  const client = makeClient(transport);
  await assert.rejects(
    async () => client.from('users').query().eq('x', 1),
    (err) => err.status === 400,
  );
});
