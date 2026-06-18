// wiring.test.mjs — offline unit tests (node:test) for the Canagrou web client
// lib. A mock fetch + FakeWebSocket assert the EXACT request shapes hit the
// Grobase gateway: /query op bodies + tenant header, GoTrue auth bodies,
// storage PUT + shared-identity bearer, realtime AUTH→SUBSCRIBE topic.
// Run:  node --test vendor/Canagrou/web/test/wiring.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';

import { createDb } from '../src/lib/db.js';
import { createAuth } from '../src/lib/auth.js';
import { createStorage } from '../src/lib/storage.js';
import { createRealtime } from '../src/lib/realtime.js';

const config = {
  url: 'https://baas.test',
  anonKey: 'anon-key',
  apiKey: 'mbk_tenant',
  dbId: 'db-123',
  storageBucket: 'post-images',
  storageToken: 'storage-jwt',
  realtimeToken: 'rt-jwt',
};

function mockFetch(responder = () => ({ rows: [] })) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const headers = new Headers(init.headers || {});
    calls.push({ url: String(url), method: init.method || 'GET', headers, body: init.body });
    const { status = 200, json = responder(String(url), init) } = {};
    return new Response(JSON.stringify(json), { status, headers: { 'Content-Type': 'application/json' } });
  };
  return calls;
}

test('db.list → POST /query/v1/<dbId>/tables/<t> with op:list + tenant header', async () => {
  const calls = mockFetch(() => ({ rows: [{ id: 1 }] }));
  const db = createDb(config);
  const rows = await db.list('posts', { where: { user_id: 'u1' }, limit: 5, sort: { created_at: 'desc' } });
  assert.deepEqual(rows, [{ id: 1 }]);
  const c = calls[0];
  assert.equal(c.url, 'https://baas.test/query/v1/db-123/tables/posts');
  assert.equal(c.method, 'POST');
  assert.equal(c.headers.get('apikey'), 'anon-key');
  assert.equal(c.headers.get('X-Baas-Api-Key'), 'mbk_tenant');
  const body = JSON.parse(c.body);
  assert.equal(body.op, 'list');
  assert.deepEqual(body.filter, { user_id: { $eq: 'u1' } });
  assert.equal(body.limit, 5);
  assert.deepEqual(body.sort, { created_at: 'desc' });
});

test('db.insert → op:insert and returns the first row', async () => {
  const calls = mockFetch(() => ({ rows: [{ id: 9, image_key: 'k.png' }] }));
  const row = await createDb(config).insert('posts', { user_id: 'u1', image_key: 'k.png' });
  assert.deepEqual(row, { id: 9, image_key: 'k.png' });
  const body = JSON.parse(calls[0].body);
  assert.equal(body.op, 'insert');
  assert.deepEqual(body.data, { user_id: 'u1', image_key: 'k.png' });
});

test('db.remove → op:delete with $eq filter', async () => {
  const calls = mockFetch(() => ({ rows: [] }));
  await createDb(config).remove('likes', { post_id: 7, user_id: 'u1' });
  const body = JSON.parse(calls[0].body);
  assert.equal(body.op, 'delete');
  assert.deepEqual(body.filter, { post_id: { $eq: 7 }, user_id: { $eq: 'u1' } });
});

test('auth.signUp → POST /auth/v1/signup with data.username, persists session', async () => {
  const calls = mockFetch(() => ({ access_token: 'jwt', refresh_token: 'r', user: { id: 'sub-1', email: 'a@b.c' } }));
  const saved = {};
  const store = { load: () => saved.s || null, save: (s) => (saved.s = s), clear: () => (saved.s = null) };
  const auth = createAuth(config, store);
  await auth.signUp({ email: 'a@b.c', password: 'pw', username: 'alice' });
  assert.equal(calls[0].url, 'https://baas.test/auth/v1/signup');
  const body = JSON.parse(calls[0].body);
  assert.deepEqual(body, { email: 'a@b.c', password: 'pw', data: { username: 'alice' } });
  assert.equal(auth.currentUser().id, 'sub-1');
  assert.equal(auth.isAuthed(), true);
});

test('auth.signInWithPassword → token?grant_type=password', async () => {
  const calls = mockFetch(() => ({ access_token: 'jwt', refresh_token: 'r', user: { id: 'sub-2' } }));
  const store = { load: () => null, save: () => {}, clear: () => {} };
  await createAuth(config, store).signInWithPassword({ email: 'a@b.c', password: 'pw' });
  assert.equal(calls[0].url, 'https://baas.test/auth/v1/token?grant_type=password');
  assert.deepEqual(JSON.parse(calls[0].body), { email: 'a@b.c', password: 'pw' });
});

test('storage.upload → PUT /storage/v1/object/<bucket>/<key> with shared bearer', async () => {
  const calls = mockFetch(() => ({ bucket: 'post-images', key: 'canagrou-app/x.png' }));
  await createStorage(config).upload('x.png', new Blob([new Uint8Array([1, 2, 3])]), 'image/png');
  const c = calls[0];
  assert.equal(c.url, 'https://baas.test/storage/v1/object/post-images/x.png');
  assert.equal(c.method, 'PUT');
  assert.equal(c.headers.get('Authorization'), 'Bearer storage-jwt');
  assert.equal(c.headers.get('apikey'), 'anon-key');
});

test('realtime.subscribe → AUTH then SUBSCRIBE on table:<dbId>:<t>', async () => {
  const sent = [];
  class FakeWS {
    constructor(url) {
      this.url = url;
      this.listeners = {};
      FakeWS.last = this;
    }
    addEventListener(t, cb) {
      (this.listeners[t] ||= []).push(cb);
    }
    send(d) {
      sent.push(JSON.parse(d));
    }
    close() {}
    emit(t, ev) {
      (this.listeners[t] || []).forEach((cb) => cb(ev));
    }
  }
  globalThis.WebSocket = FakeWS;
  const events = [];
  createRealtime(config).subscribe('posts', (e) => events.push(e));
  const ws = FakeWS.last;
  assert.match(ws.url, /\/realtime\/v1\/ws\?/);
  assert.match(ws.url, /access_token=rt-jwt/);
  ws.emit('open');
  assert.deepEqual(sent[0], { type: 'AUTH', token: 'rt-jwt' });
  ws.emit('message', { data: JSON.stringify({ type: 'AUTH_OK' }) });
  assert.equal(sent[1].type, 'SUBSCRIBE');
  assert.equal(sent[1].topic, 'table:db-123:posts');
  ws.emit('message', { data: JSON.stringify({ type: 'EVENT', event: { event_type: 'insert', payload: { id: 5 } } }) });
  assert.deepEqual(events[0], { event: 'insert', row: { id: 5 }, ts: undefined });
});
