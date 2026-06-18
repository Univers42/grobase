/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   realtime.test.mjs                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// A5 unit tests for the realtime client's broadcast + presence WIRE SHAPING.
// A fake WebSocket records sent frames and lets the test push server frames,
// so we verify the protocol without any network. Run against built output.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createClient } from '../dist/index.js';

const BASE_URL = 'https://baas.test';

/** Minimal fake WebSocket matching the subset the client uses. */
class FakeWebSocket {
  static OPEN = 1;
  constructor() {
    this.readyState = 1; // OPEN — the client only sends when readyState === 1
    this.sent = [];
    this.listeners = {};
    FakeWebSocket.last = this;
    // Fire `open` on the next tick so addEventListener('open') is registered.
    queueMicrotask(() => this.emit('open', {}));
  }
  addEventListener(type, cb) {
    (this.listeners[type] ??= []).push(cb);
  }
  send(data) {
    this.sent.push(JSON.parse(data));
  }
  close() {
    this.readyState = 3;
  }
  emit(type, ev) {
    for (const cb of this.listeners[type] ?? []) cb(ev);
  }
  /** Push a server frame to the client. */
  server(frame) {
    this.emit('message', { data: JSON.stringify(frame) });
  }
}

function makeClient() {
  return createClient({ url: BASE_URL, anonKey: 'anon-key', persistSession: false });
}

/** Drive the AUTH→SUBSCRIBED handshake against a FakeWebSocket. */
async function subscribed(client, opts) {
  const promise = client.realtime.subscribe({
    adapter: 'postgresql',
    channel: 'public.todos',
    webSocket: FakeWebSocket,
    onEvent: () => {},
    ...opts,
  });
  // open → client sends AUTH; reply AUTH_OK → client sends SUBSCRIBE.
  await Promise.resolve();
  const ws = FakeWebSocket.last;
  ws.server({ type: 'AUTH_OK' });
  const sub = ws.sent.find((m) => m.type === 'SUBSCRIBE');
  ws.server({ type: 'SUBSCRIBED', sub_id: sub.sub_id });
  const handle = await promise;
  return { ws, handle, subId: sub.sub_id };
}

test('subscribe() sends AUTH then SUBSCRIBE for the channel', async () => {
  const client = makeClient();
  const { ws } = await subscribed(client);
  assert.equal(ws.sent[0].type, 'AUTH');
  const sub = ws.sent.find((m) => m.type === 'SUBSCRIBE');
  assert.ok(sub, 'a SUBSCRIBE frame was sent');
  assert.equal(sub.topic, 'pg/public/todos/*');
});

test('handle.broadcast() sends a BROADCAST frame with topic/event/payload', async () => {
  const client = makeClient();
  const { ws, handle } = await subscribed(client);

  handle.broadcast('cursor_move', { x: 1, y: 2 });

  const bcast = ws.sent.find((m) => m.type === 'BROADCAST');
  assert.ok(bcast, 'a BROADCAST frame was sent');
  assert.equal(bcast.topic, 'pg/public/todos/*');
  assert.equal(bcast.event, 'cursor_move');
  assert.deepEqual(bcast.payload, { x: 1, y: 2 });
});

test('presence:true auto-sends TRACK after SUBSCRIBED', async () => {
  const client = makeClient();
  const { ws } = await subscribed(client, { presence: true, presenceMeta: { name: 'alice' } });

  const track = ws.sent.find((m) => m.type === 'TRACK');
  assert.ok(track, 'a TRACK frame was sent on subscribe');
  assert.equal(track.topic, 'pg/public/todos/*');
  assert.deepEqual(track.meta, { name: 'alice' });
});

test('presence EVENT frames route to onPresence, not onEvent', async () => {
  const client = makeClient();
  const presences = [];
  const dataEvents = [];
  const promise = client.realtime.subscribe({
    adapter: 'postgresql',
    channel: 'public.todos',
    webSocket: FakeWebSocket,
    presence: true,
    onEvent: (e) => dataEvents.push(e),
    onPresence: (m) => presences.push(m),
  });
  await Promise.resolve();
  const ws = FakeWebSocket.last;
  ws.server({ type: 'AUTH_OK' });
  const sub = ws.sent.find((m) => m.type === 'SUBSCRIBE');
  ws.server({ type: 'SUBSCRIBED', sub_id: sub.sub_id });
  await promise;

  // Server delivers a presence snapshot as an EVENT with event_type "presence".
  ws.server({
    type: 'EVENT',
    sub_id: sub.sub_id,
    event: {
      topic: 'pg/public/todos/*',
      event_type: 'presence',
      payload: { topic: 'pg/public/todos/*', members: [{ conn_id: '7', user_id: 'alice', meta: { color: 'blue' } }] },
    },
  });

  assert.equal(presences.length, 1, 'onPresence fired once');
  assert.equal(presences[0].length, 1);
  assert.equal(presences[0][0].connId, '7');
  assert.equal(presences[0][0].userId, 'alice');
  assert.deepEqual(presences[0][0].meta, { color: 'blue' });
  assert.equal(dataEvents.length, 0, 'presence did not leak into onEvent');
});

test('broadcast EVENT frames route to onEvent', async () => {
  const client = makeClient();
  const events = [];
  const promise = client.realtime.subscribe({
    adapter: 'postgresql',
    channel: 'public.todos',
    webSocket: FakeWebSocket,
    onEvent: (e) => events.push(e),
  });
  await Promise.resolve();
  const ws = FakeWebSocket.last;
  ws.server({ type: 'AUTH_OK' });
  const sub = ws.sent.find((m) => m.type === 'SUBSCRIBE');
  ws.server({ type: 'SUBSCRIBED', sub_id: sub.sub_id });
  await promise;

  ws.server({
    type: 'EVENT',
    sub_id: sub.sub_id,
    event: {
      topic: 'pg/public/todos/*',
      event_type: 'broadcast',
      payload: { event: 'cursor_move', payload: { x: 9 } },
    },
  });

  assert.equal(events.length, 1, 'broadcast surfaced via onEvent');
  assert.equal(events[0].event, 'broadcast');
});

test('unsubscribe() after track sends UNTRACK then UNSUBSCRIBE', async () => {
  const client = makeClient();
  const { ws, handle } = await subscribed(client, { presence: true });

  await handle.unsubscribe();
  const types = ws.sent.map((m) => m.type);
  assert.ok(types.includes('UNTRACK'), 'UNTRACK sent on unsubscribe when tracking');
  assert.ok(types.includes('UNSUBSCRIBE'), 'UNSUBSCRIBE sent on unsubscribe');
  assert.ok(
    types.lastIndexOf('UNTRACK') < types.lastIndexOf('UNSUBSCRIBE'),
    'UNTRACK precedes UNSUBSCRIBE',
  );
});
