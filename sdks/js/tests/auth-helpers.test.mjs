/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   auth-helpers.test.mjs                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// Unit tests for the A3 auth DX helpers: signInWithOAuth (builds the gotrue
// /auth/v1/authorize URL — no request) + MFA enroll/challenge/verify against
// /auth/v1/factors. Transport mocked via the `fetch` option; no network.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createClient, AuthMfaClient } from '../dist/index.js';

const BASE_URL = 'https://baas.test';

function mockTransport(handler = () => ({})) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), init });
    const { status = 200, body = {}, raw } = handler(String(url), init);
    const payload = raw !== undefined ? raw : JSON.stringify(body);
    return new Response(payload, { status, headers: { 'Content-Type': 'application/json' } });
  };
  return { calls, fetchImpl };
}

function makeClient(transport) {
  return createClient({ url: BASE_URL, anonKey: 'anon-key', persistSession: false, fetch: transport.fetchImpl });
}

test('signInWithOAuth builds the authorize URL and issues NO request', () => {
  const transport = mockTransport();
  const client = makeClient(transport);

  const out = client.auth.signInWithOAuth({ provider: 'github', redirectTo: 'https://app.test/cb', scopes: 'repo' });

  assert.equal(transport.calls.length, 0, 'no network call — URL only');
  assert.equal(out.provider, 'github');
  const url = new URL(out.url);
  assert.equal(url.origin + url.pathname, `${BASE_URL}/auth/v1/authorize`);
  assert.equal(url.searchParams.get('provider'), 'github');
  assert.equal(url.searchParams.get('apikey'), 'anon-key');
  assert.equal(url.searchParams.get('redirect_to'), 'https://app.test/cb');
  assert.equal(url.searchParams.get('scopes'), 'repo');
});

test('signInWithOAuth appends arbitrary queryParams and omits absent options', () => {
  const client = makeClient(mockTransport());
  const out = client.auth.signInWithOAuth({ provider: 'google', queryParams: { prompt: 'consent' } });
  const url = new URL(out.url);
  assert.equal(url.searchParams.get('provider'), 'google');
  assert.equal(url.searchParams.get('prompt'), 'consent');
  assert.equal(url.searchParams.get('redirect_to'), null);
  assert.equal(url.searchParams.get('scopes'), null);
});

test('client.auth.mfa is an AuthMfaClient', () => {
  const client = makeClient(mockTransport());
  assert.ok(client.auth.mfa instanceof AuthMfaClient);
});

test('mfa.enroll POSTs /auth/v1/factors with factor_type defaulting to totp', async () => {
  const transport = mockTransport(() => ({ body: { id: 'f1', type: 'totp', totp: { secret: 'ABC', uri: 'otpauth://x', qr_code: 'data:...' } } }));
  const client = makeClient(transport);

  const out = await client.auth.mfa.enroll({ friendlyName: 'My phone' });

  assert.equal(transport.calls[0].url, `${BASE_URL}/auth/v1/factors`);
  assert.equal(transport.calls[0].init.method, 'POST');
  assert.deepEqual(JSON.parse(transport.calls[0].init.body), { factor_type: 'totp', friendly_name: 'My phone' });
  assert.equal(out.id, 'f1');
  assert.equal(out.totp.secret, 'ABC');
});

test('mfa.enroll forwards phone for a phone factor', async () => {
  const transport = mockTransport(() => ({ body: { id: 'f2', type: 'phone' } }));
  const client = makeClient(transport);
  await client.auth.mfa.enroll({ factorType: 'phone', phone: '+15551234567' });
  assert.deepEqual(JSON.parse(transport.calls[0].init.body), { factor_type: 'phone', phone: '+15551234567' });
});

test('mfa.challenge POSTs /auth/v1/factors/:id/challenge', async () => {
  const transport = mockTransport(() => ({ body: { id: 'c1', expires_at: 123 } }));
  const client = makeClient(transport);

  const out = await client.auth.mfa.challenge({ factorId: 'f1' });
  assert.equal(transport.calls[0].url, `${BASE_URL}/auth/v1/factors/f1/challenge`);
  assert.equal(transport.calls[0].init.method, 'POST');
  assert.equal(out.id, 'c1');
});

test('mfa.verify POSTs challenge_id+code and persists the upgraded session', async () => {
  const transport = mockTransport(() => ({ body: { access_token: 'AAL2-token', refresh_token: 'r', token_type: 'bearer' } }));
  const client = makeClient(transport);

  const session = await client.auth.mfa.verify({ factorId: 'f1', challengeId: 'c1', code: '123456' });
  assert.equal(transport.calls[0].url, `${BASE_URL}/auth/v1/factors/f1/verify`);
  assert.deepEqual(JSON.parse(transport.calls[0].init.body), { challenge_id: 'c1', code: '123456' });
  assert.equal(session.access_token, 'AAL2-token');
  // setSession ran — the new token becomes the bearer for subsequent calls.
  assert.equal(client.getSession().accessToken, 'AAL2-token');
});

test('mfa.unenroll DELETEs /auth/v1/factors/:id', async () => {
  const transport = mockTransport(() => ({ body: {} }));
  const client = makeClient(transport);
  await client.auth.mfa.unenroll('f1');
  assert.equal(transport.calls[0].url, `${BASE_URL}/auth/v1/factors/f1`);
  assert.equal(transport.calls[0].init.method, 'DELETE');
});

test('back-compat: existing auth.signInWithPassword still posts the token endpoint', async () => {
  const transport = mockTransport(() => ({ body: { access_token: 'tok', token_type: 'bearer' } }));
  const client = makeClient(transport);
  await client.auth.signInWithPassword({ email: 'a@b.c', password: 'pw' });
  assert.equal(transport.calls[0].url, `${BASE_URL}/auth/v1/token?grant_type=password`);
  assert.equal(transport.calls[0].init.method, 'POST');
});
