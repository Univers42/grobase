import type { BaasConfig } from './config.ts';

export type RealtimeHandle = { close: () => void };

/** wsUrl builds the same-origin realtime WS URL (ws/wss matching the page). */
function wsUrl(): string {
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${window.location.host}/realtime/v1/ws`;
}

/** subscribeTable opens a realtime socket, authenticates, and subscribes to a
 *  table topic, invoking onEvent for every change message. Returns a closer. */
export function subscribeTable(
  cfg: BaasConfig,
  topic: string,
  onEvent: (payload: unknown) => void,
): RealtimeHandle {
  const ws = new WebSocket(wsUrl());
  ws.addEventListener('open', () => {
    ws.send(JSON.stringify({ type: 'AUTH', token: cfg.realtimeToken }));
    ws.send(JSON.stringify({ type: 'SUBSCRIBE', topic }));
  });
  ws.addEventListener('message', (ev) => {
    try {
      onEvent(JSON.parse(String(ev.data)));
    } catch {
      onEvent(ev.data);
    }
  });
  return { close: () => ws.close() };
}

/** commentsTopic returns the realtime topic for a mount's comments table. */
export function commentsTopic(cfg: BaasConfig): string {
  return `table:${cfg.mongoDbId}:comments`;
}
