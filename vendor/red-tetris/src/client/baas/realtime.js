// Grobase realtime — the full client used for live multiplayer (BROADCAST +
// presence/TRACK) AND for CDC leaderboard subscriptions. One WebSocket per tab,
// authenticated with the signed-in user's GoTrue token (which the realtime
// gateway verifies with the shared JWT secret) or the seeded app token.
import config from './config.js';
import { accessToken } from './session.js';

/** wsUrl builds the same-origin realtime WS URL (ws/wss matching the page). */
function wsUrl() {
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${window.location.host}/realtime/v1/ws`;
}

/**
 * rtToken returns the WS token. The shared realtime token is preferred because
 * it carries can_publish (GoTrue user tokens default can_publish=false and can
 * only subscribe); per-player identity rides in presence meta, and owner-scoped
 * DB writes keep using the user's GoTrue token over HTTP.
 */
export function rtToken() {
  return config.realtimeToken || accessToken();
}

/**
 * RealtimeClient owns one authenticated WebSocket and multiplexes topic
 * subscriptions, ephemeral broadcasts, and presence over it. On an unexpected
 * close it reconnects, re-authenticates, then replays every subscription and
 * presence track so a network blip is invisible to the game.
 */
export class RealtimeClient {
  constructor() {
    this.ws = null;
    this.authed = false;
    this.closed = false;
    this.connId = null;
    this.subs = new Map();
    this.tracks = new Map();
    this.handlers = new Map();
    this.readyCbs = new Set();
    this.stateCbs = new Set();
    this.outbox = [];
  }

  /** connect opens the socket (idempotent) and wires the lifecycle handlers. */
  connect() {
    if (this.ws) return this;
    this.closed = false;
    this.ws = new WebSocket(wsUrl());
    this.ws.addEventListener('open', () => this._send({ type: 'AUTH', token: rtToken() }));
    this.ws.addEventListener('message', (ev) => this._onMessage(ev));
    this.ws.addEventListener('close', () => this._onClose());
    this.ws.addEventListener('error', () => this.ws && this.ws.close());
    return this;
  }

  /** onReady registers a callback fired after each successful AUTH_OK. */
  onReady(cb) { this.readyCbs.add(cb); if (this.authed) cb(); return () => this.readyCbs.delete(cb); }

  /** onState registers a connected/disconnected listener (boolean). */
  onState(cb) { this.stateCbs.add(cb); cb(this.authed); return () => this.stateCbs.delete(cb); }

  /** subscribe registers a handler for a topic and (re)sends the SUBSCRIBE. */
  subscribe(topic, handler) {
    this._addHandler(topic, handler);
    const subId = this.subs.get(topic) || `${topic}#${Date.now()}`;
    this.subs.set(topic, subId);
    this._send({ type: 'SUBSCRIBE', sub_id: subId, topic });
    return () => this.unsubscribe(topic, handler);
  }

  /** unsubscribe drops one handler; the topic SUBSCRIBE is left in place. */
  unsubscribe(topic, handler) {
    const set = this.handlers.get(topic);
    if (set) set.delete(handler);
  }

  /** broadcast sends an ephemeral client→client event to a topic's subscribers. */
  broadcast(topic, event, payload) {
    this._send({ type: 'BROADCAST', topic, event, payload });
  }

  /** track joins (or refreshes) a topic's presence set with opaque metadata. */
  track(topic, meta) {
    this.tracks.set(topic, meta);
    this._send({ type: 'TRACK', topic, meta });
  }

  /** untrack leaves a topic's presence set. */
  untrack(topic) {
    this.tracks.delete(topic);
    this._send({ type: 'UNTRACK', topic });
  }

  _addHandler(topic, handler) {
    if (!this.handlers.has(topic)) this.handlers.set(topic, new Set());
    this.handlers.get(topic).add(handler);
  }

  _send(obj) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN && (this.authed || obj.type === 'AUTH')) {
      this.ws.send(JSON.stringify(obj));
    } else if (obj.type !== 'AUTH') {
      this.outbox.push(obj);
    }
  }

  _onMessage(ev) {
    let msg;
    try { msg = JSON.parse(String(ev.data)); } catch { return; }
    if (msg.type === 'AUTH_OK') return this._onAuthOk(msg);
    if (msg.type === 'EVENT' && msg.event) return this._dispatchEvent(msg.event);
    if (msg.type === 'PRESENCE') return this._dispatch(msg.topic, { kind: 'presence', members: msg.members || [] });
  }

  _onAuthOk(msg) {
    this.authed = true;
    this.connId = msg.conn_id || null;
    this.subs.forEach((subId, topic) => this.ws.send(JSON.stringify({ type: 'SUBSCRIBE', sub_id: subId, topic })));
    this.tracks.forEach((meta, topic) => this.ws.send(JSON.stringify({ type: 'TRACK', topic, meta })));
    this.outbox.splice(0).forEach((o) => this.ws.send(JSON.stringify(o)));
    this.readyCbs.forEach((cb) => cb());
    this.stateCbs.forEach((cb) => cb(true));
  }

  _dispatchEvent(event) {
    const et = event.event_type;
    if (et === 'presence') {
      this._dispatch(event.topic, { kind: 'presence', members: (event.payload && event.payload.members) || [] });
    } else if (et === 'broadcast') {
      const body = event.payload || {};
      this._dispatch(event.topic, { kind: 'broadcast', event: body.event, payload: body.payload });
    } else {
      this._dispatch(event.topic, { kind: 'row', event_type: et, payload: event.payload, raw: event });
    }
  }

  _dispatch(topic, msg) {
    const set = this.handlers.get(topic);
    if (set) set.forEach((h) => h(msg));
  }

  _onClose() {
    this.authed = false;
    this.ws = null;
    this.stateCbs.forEach((cb) => cb(false));
    if (!this.closed) setTimeout(() => this.connect(), 1200);
  }

  /** close tears down the socket and stops reconnecting. */
  close() { this.closed = true; if (this.ws) this.ws.close(); }
}

let singleton = null;

/** getClient returns the process-wide RealtimeClient, connecting on first use. */
export function getClient() {
  if (!singleton) singleton = new RealtimeClient().connect();
  return singleton;
}

/**
 * subscribeTable keeps the simple CDC API the leaderboard/leagues pages use:
 * subscribe to a PG-mount table's change topic and invoke onChange per row event.
 */
export function subscribeTable(table, onChange) {
  const client = getClient();
  const topic = `table:${config.pgDbId}:${table}`;
  const off = client.subscribe(topic, (m) => { if (m.kind === 'row') onChange(m); });
  return { close: off };
}
