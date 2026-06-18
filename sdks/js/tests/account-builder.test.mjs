/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   account-builder.test.mjs                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// Unit tests for the B7/builder SDK surface on `AccountClient` (mounts,
// entitlements, builder preview). Run against the BUILT output:
//
//   npm run build && npm test
//
// The transport is mocked via the standalone `fetch` option — no network.

import test from 'node:test';
import assert from 'node:assert/strict';
import { AccountClient } from '../dist/index.js';
import { routes } from '../dist/core/routes.js';

const BASE_URL = 'https://baas.test';
const TOKEN = 'tenant-api-key';

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

function makeAccount(transport) {
  return new AccountClient({ baseUrl: BASE_URL, token: TOKEN, fetch: transport.fetchImpl });
}

test('listMounts GETs /v1/tenants/me/mounts with the caller bearer', async () => {
  const mounts = [{ id: 'm1', tenant_id: 't1', engine: 'postgresql', name: 'main', isolation: 'shared_rls', status: 'active', created_at: 'now' }];
  const transport = mockTransport(() => ({ body: mounts }));
  const account = makeAccount(transport);

  const out = await account.listMounts();

  assert.deepEqual(out, mounts);
  assert.equal(transport.calls.length, 1);
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.tenantsSelf.mounts}`);
  assert.equal(transport.calls[0].init.method, 'GET');
  // standalone mode pins the caller's bearer as both apikey + Authorization
  const hdrs = transport.calls[0].init.headers;
  assert.equal(hdrs.get('apikey'), TOKEN);
  assert.equal(hdrs.get('Authorization'), `Bearer ${TOKEN}`);
});

test('createMount POSTs the body to /v1/tenants/me/mounts', async () => {
  const created = { id: 'm2', tenant_id: 't1', engine: 'mysql', name: 'ops', isolation: 'shared_rls', status: 'active', created_at: 'now' };
  const transport = mockTransport(() => ({ status: 201, body: created }));
  const account = makeAccount(transport);

  const input = { engine: 'mysql', name: 'ops', connection_string: 'mysql://x' };
  const out = await account.createMount(input);

  assert.deepEqual(out, created);
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.tenantsSelf.mounts}`);
  assert.equal(transport.calls[0].init.method, 'POST');
  assert.deepEqual(JSON.parse(transport.calls[0].init.body), input);
});

test('deleteMount DELETEs the single-mount path (caller-scoped server-side)', async () => {
  const transport = mockTransport(() => ({ body: { deleted: true } }));
  const account = makeAccount(transport);

  const out = await account.deleteMount('m1');

  assert.deepEqual(out, { deleted: true });
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.tenantsSelf.mount('m1')}`);
  assert.equal(transport.calls[0].init.method, 'DELETE');
});

test('getEntitlements GETs /v1/tenants/me/entitlements', async () => {
  const ent = {
    engines: ['postgresql'],
    capabilities: ['realtime'],
    limits: { rps: 50 },
    quota: { 'query.count': 100000 },
    custom: true,
    ceiling: { engines: ['postgresql', 'mysql'], capabilities: ['realtime', 'functions'], limits: { rps: 100 }, quota: { 'query.count': 1000000 } },
  };
  const transport = mockTransport(() => ({ body: ent }));
  const account = makeAccount(transport);

  const out = await account.getEntitlements();

  assert.deepEqual(out, ent);
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.tenantsSelf.entitlements}`);
  assert.equal(transport.calls[0].init.method, 'GET');
});

test('patchEntitlements PATCHes the overlay to /v1/tenants/me/entitlements', async () => {
  const ent = { engines: ['postgresql'], capabilities: [], limits: { rps: 25 }, quota: {}, custom: true };
  const transport = mockTransport(() => ({ body: ent }));
  const account = makeAccount(transport);

  const patch = { capabilities: { realtime: false }, limits: { rps: 25 } };
  const out = await account.patchEntitlements(patch);

  assert.deepEqual(out, ent);
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.tenantsSelf.entitlements}`);
  assert.equal(transport.calls[0].init.method, 'PATCH');
  assert.deepEqual(JSON.parse(transport.calls[0].init.body), patch);
});

test('previewBuilder POSTs the proposal to /v1/tenants/me/builder', async () => {
  const result = {
    valid: false,
    clamped: { engines: ['postgresql'], capabilities: [], limits: { rps: 50 }, quota: {} },
    violations: ['engine "mongodb" exceeds ceiling', 'rps 200 > ceiling 50'],
    effectiveCapabilityOverrides: { realtime: false },
    mountBudget: { used: 2, max: 3 },
  };
  const transport = mockTransport(() => ({ body: result }));
  const account = makeAccount(transport);

  const input = {
    entitlements: { engines: ['postgresql', 'mongodb'], limits: { rps: 200 } },
    mounts: [{ engine: 'postgresql', name: 'a' }, { engine: 'postgresql', name: 'b' }],
  };
  const out = await account.previewBuilder(input);

  assert.deepEqual(out, result);
  assert.equal(out.valid, false);
  assert.equal(transport.calls[0].url, `${BASE_URL}${routes.tenantsSelf.builder}`);
  assert.equal(transport.calls[0].init.method, 'POST');
  assert.deepEqual(JSON.parse(transport.calls[0].init.body), input);
});

test('builder routes build the documented self-service paths', () => {
  assert.equal(routes.tenantsSelf.mounts, '/v1/tenants/me/mounts');
  assert.equal(routes.tenantsSelf.mount('m 1'), '/v1/tenants/me/mounts/m%201');
  assert.equal(routes.tenantsSelf.entitlements, '/v1/tenants/me/entitlements');
  assert.equal(routes.tenantsSelf.builder, '/v1/tenants/me/builder');
});
