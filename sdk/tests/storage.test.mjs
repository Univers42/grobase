/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   storage.test.mjs                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// Unit tests for the A1 Storage DX (`client.storage`) — Supabase-shaped
// from(bucket) + bucket management. Transport mocked via the `fetch` option;
// no network. Run: npm run build && npm test.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createClient, MiniBaasError, StorageClient, StorageBucketClient } from '../dist/index.js';

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

test('client.storage is a StorageClient; .from() returns a StorageBucketClient', () => {
  const client = makeClient(mockTransport());
  assert.ok(client.storage instanceof StorageClient);
  assert.ok(client.storage.from('avatars') instanceof StorageBucketClient);
});

test('from(bucket).upload() PUTs binary to /storage/v1/object/:bucket/:key with the body verbatim', async () => {
  const transport = mockTransport(() => ({ body: { bucket: 'avatars', key: 'u/me.png', size: 4 } }));
  const client = makeClient(transport);

  const out = await client.storage.from('avatars').upload('me.png', 'DATA', { contentType: 'image/png' });

  assert.deepEqual(out, { bucket: 'avatars', key: 'u/me.png', size: 4 });
  assert.equal(transport.calls.length, 1);
  assert.equal(transport.calls[0].url, `${BASE_URL}/storage/v1/object/avatars/me.png`);
  assert.equal(transport.calls[0].init.method, 'PUT');
  assert.equal(transport.calls[0].init.body, 'DATA'); // NOT JSON-stringified
  assert.equal(new Headers(transport.calls[0].init.headers).get('Content-Type'), 'image/png');
});

test('upload() guesses content-type from the extension when not given', async () => {
  const transport = mockTransport(() => ({ body: {} }));
  const client = makeClient(transport);
  await client.storage.from('docs').upload('a/b/report.pdf', 'x');
  assert.equal(new Headers(transport.calls[0].init.headers).get('Content-Type'), 'application/pdf');
});

test('from(bucket).download() GETs the object and returns a Blob', async () => {
  const transport = mockTransport(() => ({ raw: 'file-bytes' }));
  const client = makeClient(transport);

  const blob = await client.storage.from('avatars').download('me.png');
  assert.equal(transport.calls[0].url, `${BASE_URL}/storage/v1/object/avatars/me.png`);
  assert.equal(transport.calls[0].init.method, 'GET');
  assert.equal(await blob.text(), 'file-bytes');
});

test('from(bucket).list(prefix) GETs /storage/v1/list/:bucket?prefix= and unwraps objects', async () => {
  const objects = [{ key: 'a.txt', size: 1, lastModified: null }];
  const transport = mockTransport(() => ({ body: { objects } }));
  const client = makeClient(transport);

  const out = await client.storage.from('avatars').list('photos/');
  assert.deepEqual(out, objects);
  assert.equal(transport.calls[0].url, `${BASE_URL}/storage/v1/list/avatars?prefix=photos%2F`);
  assert.equal(transport.calls[0].init.method, 'GET');
});

test('from(bucket).remove([...]) DELETEs each object path', async () => {
  const transport = mockTransport(() => ({ body: { deleted: true } }));
  const client = makeClient(transport);

  const out = await client.storage.from('avatars').remove(['a.txt', 'b/c.txt']);
  assert.deepEqual(out, [{ key: 'a.txt', deleted: true }, { key: 'b/c.txt', deleted: true }]);
  assert.equal(transport.calls.length, 2);
  assert.equal(transport.calls[0].url, `${BASE_URL}/storage/v1/object/avatars/a.txt`);
  assert.equal(transport.calls[0].init.method, 'DELETE');
  assert.equal(transport.calls[1].url, `${BASE_URL}/storage/v1/object/avatars/b/c.txt`);
});

test('from(bucket).createSignedUrl() POSTs method+expiresIn to /storage/v1/sign/:bucket/:key', async () => {
  const transport = mockTransport(() => ({ body: { signedUrl: 'https://x', expiresAt: 'soon' } }));
  const client = makeClient(transport);

  await client.storage.from('avatars').createSignedUrl('me.png', 600, 'GET');
  assert.equal(transport.calls[0].url, `${BASE_URL}/storage/v1/sign/avatars/me.png`);
  assert.equal(transport.calls[0].init.method, 'POST');
  assert.deepEqual(JSON.parse(transport.calls[0].init.body), { method: 'GET', expiresIn: 600 });
});

test('storage.createBucket() POSTs /storage/v1/bucket/:name; listBuckets() GETs /storage/v1/bucket', async () => {
  const transport = mockTransport((url) =>
    url.endsWith('/bucket') ? ({ body: { buckets: [{ name: 'avatars', createdAt: null }] } }) : ({ body: { name: 'avatars', created: true } }),
  );
  const client = makeClient(transport);

  const created = await client.storage.createBucket('avatars');
  assert.deepEqual(created, { name: 'avatars', created: true });
  assert.equal(transport.calls[0].url, `${BASE_URL}/storage/v1/bucket/avatars`);
  assert.equal(transport.calls[0].init.method, 'POST');

  const buckets = await client.storage.listBuckets();
  assert.deepEqual(buckets, [{ name: 'avatars', createdAt: null }]);
  assert.equal(transport.calls[1].url, `${BASE_URL}/storage/v1/bucket`);
  assert.equal(transport.calls[1].init.method, 'GET');
});

test('back-compat: storage.presign() still POSTs to /storage/v1/sign/:bucket/:key', async () => {
  const transport = mockTransport(() => ({ body: { signedUrl: 'https://x' } }));
  const client = makeClient(transport);

  await client.storage.presign({ bucket: 'avatars', key: 'me.png', method: 'PUT', contentType: 'image/png' });
  assert.equal(transport.calls[0].url, `${BASE_URL}/storage/v1/sign/avatars/me.png`);
  assert.deepEqual(JSON.parse(transport.calls[0].init.body), { method: 'PUT', contentType: 'image/png' });
});

test('upload() surfaces a non-2xx as MiniBaasError with the gateway status', async () => {
  const transport = mockTransport(() => ({ status: 413, body: { message: 'object exceeds max upload size' } }));
  const client = makeClient(transport);
  await assert.rejects(
    client.storage.from('avatars').upload('big.bin', 'x'),
    (err) => err instanceof MiniBaasError && err.status === 413,
  );
});
