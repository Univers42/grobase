/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   engine-clients.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/01 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:51:48 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Per-engine SDK clients (M10 — capabilities at the type level).
//
// The shape of each `EngineClient<E, Row>` is **derived from
// `ENGINE_CAPS[E]`** at the type level. Methods that the engine does not
// support are absent from the type — calling them is a *compile* error,
// not a runtime surprise.
//
// Example:
//
//   const pg    = client.engine<'postgresql', User>(dbId, 'users');
//   const mongo = client.engine<'mongodb',    User>(dbId, 'users');
//
//   await pg.list();              // ✅ pg.caps.read    === true
//   await pg.transaction(...);    // ✅ pg.caps.txIntra === true
//   await pg.upsert(...);         // ❌ COMPILE ERROR — postgresql.caps.upsert === false
//   await pg.subscribe(...);      // ❌ COMPILE ERROR — postgresql.caps.stream === false
//
//   await mongo.subscribe((doc) => console.log(doc));  // ✅ mongodb.caps.stream === true
//   await mongo.transaction(...); // ❌ COMPILE ERROR — mongodb.caps.txIntra === false

import { routes } from '../core/routes.js';
import type { HttpClient } from '../core/http.js';
import {
  ENGINE_CAPS,
  type EngineCaps,
  type EngineId,
} from '../generated/engines.js';
import { RealtimeClient, type RealtimeSubscribeOptions, type RealtimeSubscription } from './realtime-client.js';

/** Always-on operations every engine in the catalog supports. */
export interface BaseEngineClient<Row = Record<string, unknown>> {
  /** List rows / documents matching `filter`. */
  list(opts?: { filter?: Record<string, unknown>; limit?: number; offset?: number }): Promise<Row[]>;
  /** Fetch one by id-shaped filter. Returns `null` when not found. */
  get(filter: Record<string, unknown>): Promise<Row | null>;
  /** Insert one row. The server tags it with the calling `userId`. */
  insert(data: Partial<Row>): Promise<Row>;
  /** Update rows matching `filter`. Returns the rows that were updated. */
  update(filter: Record<string, unknown>, data: Partial<Row>): Promise<Row[]>;
  /** Delete rows matching `filter`. Returns the rows that were deleted. */
  delete(filter: Record<string, unknown>): Promise<Row[]>;
}

/** Mixed in when `caps.upsert === true`. */
export interface UpsertableMixin<Row> {
  /** Insert if missing, update if present. Native upsert path on the engine. */
  upsert(data: Partial<Row>): Promise<Row>;
}

/** Mixed in when `caps.stream === true`. */
export interface StreamableMixin<Row> {
  /**
   * Subscribe to a change stream / CDC feed via the realtime-agnostic engine.
   *
   * Opens a WebSocket to `/realtime/v1/ws` (routed by Kong → realtime:4000/ws),
   * sends `{action:'subscribe', channel, adapter}`, and dispatches every
   * incoming event to `handler`. Returns a handle whose `unsubscribe()` sends
   * the matching unsubscribe message and closes the socket cleanly.
   */
  subscribe(
    handler: (event: { type: 'insert' | 'update' | 'delete' | (string & {}); row: Row }) => void,
    options?: EngineSubscribeOptions<Row>,
  ): Promise<RealtimeSubscription>;
}

export type EngineSubscribeOptions<Row> = Omit<
  RealtimeSubscribeOptions<Row>,
  'adapter' | 'channel' | 'onEvent'
>;

/** Mixed in when `caps.txIntra === true`. */
export interface TransactionalMixin<Row> {
  /** Run `fn` inside an intra-engine transaction; commits if it resolves, rolls back if it throws. */
  transaction<T>(fn: (tx: BaseEngineClient<Row>) => Promise<T>): Promise<T>;
}

/**
 * The final, capability-derived shape exposed to user code.
 *
 * Use as `EngineClient<'postgresql', MyRow>`. The type intersection is
 * computed at compile time from `ENGINE_CAPS[E]` — missing capabilities
 * leave the mixin out, so calling them is a hard compile error.
 */
export type EngineClient<E extends EngineId, Row = Record<string, unknown>> =
  & BaseEngineClient<Row>
  & ((typeof ENGINE_CAPS)[E]['upsert'] extends true ? UpsertableMixin<Row> : {})
  & ((typeof ENGINE_CAPS)[E]['stream'] extends true ? StreamableMixin<Row> : {})
  & ((typeof ENGINE_CAPS)[E]['txIntra'] extends true ? TransactionalMixin<Row> : {})
  & { readonly engine: E; readonly caps: EngineCaps<E> };

interface QueryEnvelope<TPayload> {
  database_id: string;
  action: string;
  resource: string;
  payload?: TPayload;
}

interface ExecuteResponse<TResult> {
  data?: TResult;
  rows?: TResult;
}

/**
 * Runtime client implementation. The shape exposed to TypeScript is the
 * narrowed `EngineClient<E, Row>` — methods absent from that type are
 * simply not reachable at the type level even if they exist here.
 *
 * The cast `as EngineClient<E, Row>` is the *only* place we suppress the
 * structural mismatch: it is what binds the runtime adapter to the
 * compile-time capability narrowing.
 */
export function makeEngineClient<E extends EngineId, Row = Record<string, unknown>>(
  http: HttpClient,
  engine: E,
  databaseId: string,
  resource: string,
): EngineClient<E, Row> {
  const caps = ENGINE_CAPS[engine];

  async function exec<T>(action: string, payload?: Record<string, unknown>): Promise<T> {
    const envelope: QueryEnvelope<Record<string, unknown> | undefined> = {
      database_id: databaseId,
      action,
      resource,
      payload,
    };
    const response = await http.request<ExecuteResponse<T> | T>(routes.query.execute, {
      method: 'POST',
      body: envelope,
    });
    if (response && typeof response === 'object' && 'data' in response && response.data !== undefined) {
      return response.data;
    }
    if (response && typeof response === 'object' && 'rows' in response && response.rows !== undefined) {
      return response.rows;
    }
    return response as T;
  }

  const base: BaseEngineClient<Row> = {
    list: (opts) => exec<Row[]>('list', opts),
    get: async (filter) => {
      const rows = await exec<Row[]>('get', { filter });
      return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
    },
    insert: (data) => exec<Row>('insert', { data }),
    update: (filter, data) => exec<Row[]>('update', { filter, data }),
    delete: (filter) => exec<Row[]>('delete', { filter }),
  };

  const mixins: Record<string, unknown> = { engine, caps };

  if (caps.upsert) {
    (mixins as { upsert: UpsertableMixin<Row>['upsert'] }).upsert = (data) => exec<Row>('upsert', { data });
  }

  if (caps.stream) {
    const realtime = new RealtimeClient(http);
    // Channel naming mirrors the realtime engine's producer prefix:
    //   PG  → `pg.<schema>.<table>`   e.g. `pg.public.todos`
    //   Mongo → `mongo.<db>.<coll>`   e.g. `mongo.mini_baas.orders`
    // The `resource` arg is the bare table/collection name; the caller may
    // also pass an already-qualified name (e.g. `public.todos`) and it will
    // be sent through as-is.
    (mixins as { subscribe: StreamableMixin<Row>['subscribe'] }).subscribe = (handler, options) =>
      realtime.subscribe<Row>({
        ...options,
        adapter: engine,
        channel: resource,
        onEvent: (evt) => handler({ type: evt.event, row: evt.row }),
      });
  }

  if (caps.txIntra) {
    (mixins as { transaction: TransactionalMixin<Row>['transaction'] }).transaction = async (fn) => {
      // Single-statement transactional semantics are deferred to the gateway
      // (Idempotency-Key replay + ABAC decision happen there). For now we run
      // the body against the same client — multi-statement TX is M10.b.
      return fn(base);
    };
  }

  return { ...base, ...mixins } as EngineClient<E, Row>;
}
