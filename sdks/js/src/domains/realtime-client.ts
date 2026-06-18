/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   realtime-client.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/01 13:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:40:54 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// M10.b — WebSocket client for the `dlesieur/realtime-agnostic` Rust engine.
//
// Wire :  SDK  →  Kong (`/realtime/v1/ws`)  →  realtime:4000/ws
//                                              │
//                              ┌───────────────┴───────────────┐
//                              ▼                               ▼
//                       PG LISTEN/NOTIFY                Mongo change streams
//                       (realtime_events)               (full_document=updateLookup)
//
// Protocol (per realtime-agnostic):
//   client → server : {"type":"AUTH","token":"..."}
//   server → client : {"type":"AUTH_OK", ...}
//   client → server : {"type":"SUBSCRIBE","sub_id":"...","topic":"mongo/orders/*"}
//   server → client : {"type":"SUBSCRIBED","sub_id":"..."}
//   server → client : {"type":"EVENT","sub_id":"...","event":{...}}
//
// This client is the runtime that satisfies the M10 `StreamableMixin.subscribe`
// surface. The capability narrowing in `engine-clients.ts` guarantees that
// `subscribe()` is only callable on engines where `caps.stream === true`
// (mongodb, cassandra). All other engines reject at compile time.

import type { HttpClient } from '../core/http.js';
import type { EngineId } from '../generated/engines.js';

/** Standard event envelope emitted by the realtime engine. */
export interface RealtimeEvent<Row = Record<string, unknown>> {
  /** Originating topic, e.g. `pg.public.todos` or `mongo.mini_baas.orders`. */
  readonly topic: string;
  /** Event type — `insert`, `update`, `delete`, or producer-specific. */
  readonly event: string;
  /** The row / document. Shape depends on the producer. */
  readonly row: Row;
  /** ISO timestamp the engine stamped the event. */
  readonly ts?: string;
}

/** A single member of a topic's presence set (mirrors the wire `PresenceMember`). */
export interface PresenceMember<Meta = Record<string, unknown>> {
  /** Stable per-connection id (string form of the server `ConnectionId`). */
  readonly connId: string;
  /** Authenticated subject (JWT `sub`) when the server knew one. */
  readonly userId?: string;
  /** Opaque per-member metadata supplied at `track()` time. */
  readonly meta: Meta;
}

/**
 * Handle returned by `subscribe()` — call `.unsubscribe()` to close cleanly.
 *
 * A5 adds ephemeral **broadcast** (client→client) and **presence** (who's
 * online) over the same connection:
 * - `broadcast(event, payload)` sends a `BROADCAST` frame; other subscribers of
 *   the same topic receive it via `onEvent` with `event === 'broadcast'`.
 * - `track(meta)` / `untrack()` join / leave the topic's presence set; changes
 *   are surfaced to `onPresence` (when provided).
 */
export interface RealtimeSubscription {
  unsubscribe(): Promise<void>;
  /** Send an ephemeral broadcast to every subscriber of this topic. */
  broadcast(event: string, payload?: unknown): void;
  /** Join (or refresh) the topic's presence set with optional metadata. */
  track(meta?: Record<string, unknown>): void;
  /** Leave the topic's presence set. */
  untrack(): void;
}

export interface RealtimeSubscribeOptions<Row> {
  /** Engine the subscription targets — `mongodb`, `cassandra`, `postgresql`, etc. */
  adapter: EngineId;
  /** Channel string the engine expects, e.g. `public.todos` (PG) or `orders` (Mongo). */
  channel: string;
  /** Override the topic pattern sent to realtime-agnostic. */
  topic?: string;
  /** Optional server-side filter expression. */
  filter?: Record<string, unknown>;
  /** Optional client-chosen subscription id. */
  subscriptionId?: string;
  /** AUTH_OK + SUBSCRIBED timeout. */
  timeoutMs?: number;
  /** Test/runtime override for platforms without a global WebSocket. */
  webSocket?: typeof WebSocket;
  /** Handler invoked for every matching event. */
  onEvent: (event: RealtimeEvent<Row>) => void;
  /** Optional handler for parse / transport errors (default: console.warn). */
  onError?: (error: Error) => void;
  /**
   * When `true` (or when `presenceMeta` is set), the client emits a `TRACK`
   * frame right after `SUBSCRIBED`, joining the topic's presence set. Presence
   * changes are delivered to {@link RealtimeSubscribeOptions.onPresence}.
   */
  presence?: boolean;
  /** Opaque metadata to publish for this member (implies `presence: true`). */
  presenceMeta?: Record<string, unknown>;
  /**
   * Handler invoked with the current member list whenever the topic's presence
   * set changes. Presence is single-node authoritative on the server; the list
   * reflects the emitting node's local members. See the realtime engine docs.
   */
  onPresence?: (members: PresenceMember[]) => void;
}

type ServerMessage =
  | { type: 'AUTH_OK' }
  | { type: 'SUBSCRIBED'; sub_id: string }
  | { type: 'UNSUBSCRIBED'; sub_id: string }
  | { type: 'EVENT'; sub_id: string; event: WireEvent }
  | { type: 'ERROR'; code: string; message: string }
  | { type: 'PONG' };

interface WireEvent {
  event_id?: string;
  topic?: string;
  event_type?: string;
  sequence?: number;
  timestamp?: string;
  payload?: unknown;
}

/**
 * Lazy WebSocket client. Each `subscribe()` call opens its own WS — keeping
 * connection scope local to the caller and matching the realtime engine's
 * per-connection subscription cap (200 by default).
 *
 * Uses the platform `WebSocket` global: present natively in browsers, Node 22+,
 * Deno, Bun. No bundled polyfill — keeps the SDK runtime-agnostic.
 */
export class RealtimeClient {
  constructor(private readonly http: HttpClient) {}

  async subscribe<Row = Record<string, unknown>>(
    options: RealtimeSubscribeOptions<Row>,
  ): Promise<RealtimeSubscription> {
    const WebSocketImpl = options.webSocket ?? globalThis.WebSocket;
    if (!WebSocketImpl) {
      throw new Error(
        '[mini-baas/realtime] global WebSocket not found. ' +
          'Use Node 22+, a browser, Deno, or Bun — or polyfill `ws`.',
      );
    }

    const url = this.http.createRealtimeWsUrl();
    const ws = new WebSocketImpl(url.toString());
    const topic = options.topic ?? defaultTopic(options.adapter, options.channel);
    const subId = options.subscriptionId ?? `${options.adapter}:${options.channel}:${Date.now().toString(36)}:${Math.random().toString(36).slice(2)}`;
    const onError = options.onError ?? ((err) => console.warn('[mini-baas/realtime]', err.message));
    const wantsPresence = options.presence === true || options.presenceMeta !== undefined;

    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const timeout = setTimeout(() => rejectBeforeReady(new Error(`[mini-baas/realtime] subscribe timeout for ${topic}`)), options.timeoutMs ?? 10_000);

      const rejectBeforeReady = (error: Error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        tryClose(ws);
        reject(error);
      };

      const resolveReady = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        resolve();
      };

      ws.addEventListener('open', () => {
        send(ws, { type: 'AUTH', token: this.http.getRealtimeAuthToken() });
      });

      ws.addEventListener('message', (message) => {
        const frame = parseMessage(message.data);
        if (!frame) return;

        if (frame.type === 'AUTH_OK') {
          send(ws, {
            type: 'SUBSCRIBE',
            sub_id: subId,
            topic,
            filter: options.filter,
          });
          return;
        }

        if (frame.type === 'SUBSCRIBED' && frame.sub_id === subId) {
          if (wantsPresence) {
            send(ws, { type: 'TRACK', topic, meta: options.presenceMeta ?? {} });
          }
          resolveReady();
          return;
        }

        if (frame.type === 'EVENT' && frame.sub_id === subId) {
          // Presence and broadcast both arrive as EVENT frames; route by the
          // engine-stamped event_type so callers get typed callbacks.
          if (frame.event?.event_type === 'presence') {
            options.onPresence?.(parsePresence(frame.event.payload));
            return;
          }
          options.onEvent(normalizeEvent<Row>(frame.event));
          return;
        }

        if (frame.type === 'ERROR') {
          const error = new Error(`[mini-baas/realtime] ${frame.code}: ${frame.message}`);
          if (settled) onError(error);
          else rejectBeforeReady(error);
        }
      });

      ws.addEventListener('error', () => {
        const error = new Error(`[mini-baas/realtime] WebSocket error at ${url.toString()}`);
        if (settled) onError(error);
        else rejectBeforeReady(error);
      });

      ws.addEventListener('close', () => {
        if (settled) return;
        rejectBeforeReady(new Error('[mini-baas/realtime] WebSocket closed before subscription was ready'));
      });
    });

    let closed = false;
    let tracked = wantsPresence;
    return {
      broadcast: (event: string, payload: unknown = {}) => {
        if (closed || ws.readyState !== 1) return;
        send(ws, { type: 'BROADCAST', topic, event, payload });
      },
      track: (meta: Record<string, unknown> = {}) => {
        if (closed || ws.readyState !== 1) return;
        tracked = true;
        send(ws, { type: 'TRACK', topic, meta });
      },
      untrack: () => {
        if (closed || ws.readyState !== 1) return;
        tracked = false;
        send(ws, { type: 'UNTRACK', topic });
      },
      unsubscribe: async () => {
        if (closed) return;
        closed = true;
        if (ws.readyState === 1) {
          if (tracked) send(ws, { type: 'UNTRACK', topic });
          send(ws, { type: 'UNSUBSCRIBE', sub_id: subId });
        }
        tryClose(ws);
      },
    };
  }
}

function defaultTopic(adapter: EngineId, channel: string): string {
  const normalizedChannel = channel.split('/').filter(Boolean).join('/').replaceAll('.', '/');
  if (adapter === 'mongodb') return `mongo/${normalizedChannel}/*`;
  if (adapter === 'postgresql') return `pg/${normalizedChannel}/*`;
  return `${adapter}/${normalizedChannel}/*`;
}

function send(ws: WebSocket, payload: Record<string, unknown>): void {
  ws.send(JSON.stringify(payload));
}

function parseMessage(data: unknown): ServerMessage | undefined {
  const text = messageText(data);
  if (!text) return undefined;
  try {
    return JSON.parse(text) as ServerMessage;
  } catch {
    return undefined;
  }
}

function messageText(data: unknown): string | undefined {
  if (typeof data === 'string') return data;
  if (data instanceof ArrayBuffer) return new TextDecoder().decode(data);
  if (ArrayBuffer.isView(data)) return new TextDecoder().decode(data);
  return undefined;
}

/**
 * Parse a `presence` EVENT payload (`{ topic, members: [...] }`) into the
 * SDK's {@link PresenceMember} shape, tolerating absent fields.
 */
function parsePresence(payload: unknown): PresenceMember[] {
  const body = isRecord(payload) ? payload : {};
  const members = Array.isArray(body['members']) ? body['members'] : [];
  return members.filter(isRecord).map((m) => ({
    connId: stringValue(m['conn_id']) ?? '',
    userId: stringValue(m['user_id']),
    meta: (isRecord(m['meta']) ? m['meta'] : {}) as Record<string, unknown>,
  }));
}

function normalizeEvent<Row>(event: WireEvent): RealtimeEvent<Row> {
  const payload = isRecord(event.payload) ? event.payload : { value: event.payload };
  const rowCandidate = payload['fullDocument'] ?? payload['row'] ?? payload['data'] ??
    (Array.isArray(payload['rows']) ? payload['rows'][0] : undefined) ?? payload['documentKey'] ?? payload;

  return {
    topic: event.topic ?? '',
    event: normalizeEventType(event.event_type ?? stringValue(payload['operation']) ?? stringValue(payload['op'])),
    row: (isRecord(rowCandidate) ? rowCandidate : { value: rowCandidate }) as Row,
    ts: event.timestamp,
  };
}

function normalizeEventType(value: string | undefined): string {
  const normalized = (value ?? '').toLowerCase();
  if (normalized.endsWith('.delete') || normalized === 'delete' || normalized === 'deleted') return 'delete';
  if (normalized.endsWith('.update') || normalized === 'update' || normalized === 'updated') return 'update';
  if (normalized === 'replace' || normalized === 'replaced') return 'update';
  if (normalized.endsWith('.insert') || normalized === 'insert' || normalized === 'inserted') return 'insert';
  return value ?? 'insert';
}

function tryClose(ws: WebSocket): void {
  if (ws.readyState === 0 || ws.readyState === 1) {
    ws.close(1000, 'client unsubscribed');
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}
