/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   functions-triggers.test.mjs                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// Unit tests for the A2 Functions DX SDK surface (triggers / schedules /
// secrets) on `client.functions`. Run against the BUILT output:
//
//   npm run build && npm test
//
// The transport is mocked via the `fetch` client option — no network.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createClient, FunctionsClient } from '../dist/index.js';
import { routes } from '../dist/core/routes.js';

const BASE_URL = 'https://baas.test';
const SERVICE_KEY = 'service-role-key';

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

function makeClient(transport, withKey = true) {
  return createClient({
    url: BASE_URL,
    anonKey: 'anon-key',
    persistSession: false,
    fetch: transport.fetchImpl,
    ...(withKey ? { serviceRoleKey: SERVICE_KEY } : {}),
  });
}

test('client.functions is a FunctionsClient', () => {
  const client = makeClient(mockTransport());
  assert.ok(client.functions instanceof FunctionsClient);
});

test('createTrigger POSTs /admin/v1/function-triggers with the body + service key', async () => {
  const created = { id: 't1', name: 'on-order', function_name: 'notify', enabled: true };
  const transport = mockTransport(() => ({ status: 201, body: created }));
  const client = makeClient(transport);

  const out = await client.functions.createTrigger({
    name: 'on-order',
    function_name: 'notify',
    aggregates: ['orders'],
    event_types: ['created'],
  });

  assert.deepEqual(out, created);
  assert.equal(transport.calls.length, 1);
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.functions.triggers}`);
  assert.equal(transport.calls[0].init.method, 'POST');
  const body = JSON.parse(transport.calls[0].init.body);
  assert.equal(body.function_name, 'notify');
  assert.deepEqual(body.aggregates, ['orders']);
  // service key sent as both apikey + bearer (init.headers is a Headers obj)
  const hdrs = transport.calls[0].init.headers;
  assert.equal(hdrs.get('apikey'), SERVICE_KEY);
  assert.equal(hdrs.get('Authorization'), `Bearer ${SERVICE_KEY}`);
});

test('listTriggers GETs the trigger collection', async () => {
  const transport = mockTransport(() => ({ body: [] }));
  const client = makeClient(transport);
  await client.functions.listTriggers();
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.functions.triggers}`);
  assert.equal(transport.calls[0].init.method, 'GET');
});

test('deleteTrigger DELETEs the single-trigger path', async () => {
  const transport = mockTransport(() => ({ body: { deleted: true } }));
  const client = makeClient(transport);
  const out = await client.functions.deleteTrigger('abc');
  assert.deepEqual(out, { deleted: true });
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.functions.trigger('abc')}`);
  assert.equal(transport.calls[0].init.method, 'DELETE');
});

test('createSchedule POSTs /admin/v1/function-schedules', async () => {
  const created = { id: 's1', name: 'nightly', function_name: 'report', schedule_expr: '@daily' };
  const transport = mockTransport(() => ({ status: 201, body: created }));
  const client = makeClient(transport);
  const out = await client.functions.createSchedule({
    name: 'nightly',
    function_name: 'report',
    schedule_expr: '@daily',
  });
  assert.deepEqual(out, created);
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.functions.schedules}`);
  const body = JSON.parse(transport.calls[0].init.body);
  assert.equal(body.schedule_expr, '@daily');
});

test('setSecret POSTs /admin/v1/function-secrets', async () => {
  const transport = mockTransport(() => ({ status: 201, body: { key: 'API_KEY', function_name: '', updated_at: 'now' } }));
  const client = makeClient(transport);
  const out = await client.functions.setSecret({ key: 'API_KEY', value: 's3cr3t' });
  assert.equal(out.key, 'API_KEY');
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.functions.secrets}`);
  const body = JSON.parse(transport.calls[0].init.body);
  assert.equal(body.value, 's3cr3t');
});

test('deleteSecret appends function_name query when scoped', async () => {
  const transport = mockTransport(() => ({ body: { deleted: true } }));
  const client = makeClient(transport);
  await client.functions.deleteSecret('API_KEY', 'notify');
  assert.equal(
    transport.calls[0].url,
    `${BASE_URL}${routes.functions.secret('API_KEY')}?function_name=notify`,
  );
  assert.equal(transport.calls[0].init.method, 'DELETE');
});

test('admin surfaces throw without a serviceRoleKey (no network call)', () => {
  const transport = mockTransport();
  const client = makeClient(transport, /* withKey */ false);
  // requireAdminKey throws synchronously, before any promise/network call.
  assert.throws(() => client.functions.listTriggers(), /service role key/i);
  assert.throws(() => client.functions.setSecret({ key: 'K', value: 'v' }), /service role key/i);
  assert.equal(transport.calls.length, 0, 'must not hit the network without a key');
});

test('deploy/invoke still work WITHOUT a service key (regular surface)', async () => {
  const transport = mockTransport(() => ({ body: { name: 'fn', bytes: 3 } }));
  const client = makeClient(transport, /* withKey */ false);
  await client.functions.deploy({ name: 'fn', code: 'abc' });
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.functions.root}`);
  assert.equal(transport.calls[0].init.method, 'POST');
});
