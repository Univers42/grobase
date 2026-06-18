// realtime.ts — live row changes over the realtime WebSocket. Protocol:
// AUTH → AUTH_OK → SUBSCRIBE{sub_id,topic} → SUBSCRIBED → EVENT{event:{...}}.
// Topic is table:<dbId>:<table> (the app-publish path, mount-agnostic).

import type { BaasConfig } from './config';
import { isRecord, asString } from './guards';

/** RealtimeEvent is the normalized row-change delivered to subscribers. */
export type RealtimeEvent = { event: string; row: Record<string, unknown>; ts: string };

/** Subscription is the handle returned by subscribe(); call close() to tear down. */
export type Subscription = { close: () => void };

/** Realtime is the subscribe surface bound to one mount. */
export type Realtime = {
  subscribe: (dbId: string, table: string, onEvent: (e: RealtimeEvent) => void, onError?: (e: Error) => void) => Subscription;
};

/** normalize maps a wire EVENT envelope to {event,row,ts}. */
function normalize(msg: Record<string, unknown>): RealtimeEvent {
  const e = isRecord(msg.event) ? msg.event : msg;
  const row = isRecord(e.payload) ? e.payload : isRecord(e.data) ? e.data : isRecord(e.row) ? e.row : {};
  return {
    event: asString(e.event_type ?? e.event ?? e.operation, 'change'),
    row,
    ts: asString(e.timestamp ?? e.ts),
  };
}

/** createRealtime returns subscribe(dbId, table, onEvent) → {close}, opening one
 * WS per table change topic. Returns a no-op handle when not configured. */
export function createRealtime(config: BaasConfig): Realtime {
  function subscribe(dbId: string, table: string, onEvent: (e: RealtimeEvent) => void, onError?: (e: Error) => void): Subscription {
    if (!config.url || !config.realtimeToken) return { close: () => undefined };
    const url = new URL('/realtime/v1/ws', config.url);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('apikey', config.anonKey);
    url.searchParams.set('access_token', config.realtimeToken);
    const topic = `table:${dbId}:${table}`;
    const subId = `${table}:${Math.random().toString(36).slice(2)}`;
    const ws = new WebSocket(url.toString());

    ws.addEventListener('open', () => ws.send(JSON.stringify({ type: 'AUTH', token: config.realtimeToken })));
    ws.addEventListener('message', (frame) => {
      let msg: unknown;
      try {
        msg = JSON.parse(typeof frame.data === 'string' ? frame.data : '');
      } catch {
        return;
      }
      if (!isRecord(msg)) return;
      if (msg.type === 'AUTH_OK') ws.send(JSON.stringify({ type: 'SUBSCRIBE', sub_id: subId, topic }));
      else if (msg.type === 'EVENT' || msg.type === 'ROW_CHANGED') onEvent(normalize(msg));
      else if (msg.type === 'ERROR' && onError) onError(new Error(asString(msg.message, 'realtime error')));
    });
    if (onError) ws.addEventListener('error', () => onError(new Error('realtime socket error')));

    return { close: () => ws.close() };
  }

  return { subscribe };
}
