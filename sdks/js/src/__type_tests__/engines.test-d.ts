/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   engines.test-d.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/01 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// **Compile-time** assertions for M10 capability-typed clients.
//
// This file is **expected to compile** under `tsc --noEmit`. If TypeScript
// complains, capability typing has drifted. The `// @ts-expect-error` lines
// are the inverse: they MUST trigger an error — if the line silently
// compiles, the type narrowing is broken and the SDK lies to its users.
//
// To verify locally:
//   cd sdks/js && npm run typecheck

import type { EngineClient, StreamableEngine, TransactionalEngine, UpsertableEngine } from '../index.js';

// ── 1) Always-present base operations ────────────────────────────────────────
declare const pg: EngineClient<'postgresql', { id: string; name: string }>;
declare const mongo: EngineClient<'mongodb', { _id: string; amount: number }>;
declare const redis: EngineClient<'redis', { id: string; value: string }>;
declare const http: EngineClient<'http', { id: string; payload: unknown }>;
declare const sqlite: EngineClient<'sqlite', { id: number; title: string }>;
declare const cockroach: EngineClient<'cockroachdb', { id: string }>;

// All five base ops exist on every engine — these must type-check.
pg.list satisfies unknown;
pg.get satisfies unknown;
pg.insert satisfies unknown;
pg.update satisfies unknown;
pg.delete satisfies unknown;
mongo.list satisfies unknown;
redis.list satisfies unknown;
http.list satisfies unknown;
sqlite.list satisfies unknown;

// ── 2) Capability narrowing — POSITIVE cases (must compile) ──────────────────
// postgresql: txIntra, upsert (ON CONFLICT) and stream (LISTEN/NOTIFY) are true
pg.transaction satisfies unknown;
pg.upsert satisfies unknown;
pg.subscribe satisfies unknown;
// mongodb.caps.stream === true, upsert === true
mongo.subscribe satisfies unknown;
mongo.upsert satisfies unknown;
// every engine the data plane serves upserts
redis.upsert satisfies unknown;
http.upsert satisfies unknown;
sqlite.upsert satisfies unknown;
cockroach.transaction satisfies unknown;

// ── 3) Capability narrowing — NEGATIVE cases (must FAIL to compile) ─────────
// If any of these lines silently compile, the type narrowing is broken.

// @ts-expect-error mongodb.caps.txIntra === false → no .transaction()
mongo.transaction satisfies unknown;

// @ts-expect-error redis.caps.txIntra === false → no .transaction()
redis.transaction satisfies unknown;

// @ts-expect-error redis.caps.stream === false → no .subscribe()
redis.subscribe satisfies unknown;

// @ts-expect-error http.caps.txIntra === false → no .transaction()
http.transaction satisfies unknown;

// @ts-expect-error http.caps.stream === false → no .subscribe()
http.subscribe satisfies unknown;

// @ts-expect-error sqlite.caps.txIntra === false → no .transaction()
sqlite.transaction satisfies unknown;

// @ts-expect-error cockroachdb.caps.stream === false → no .subscribe()
cockroach.subscribe satisfies unknown;

// ── 4) Discriminated-union helpers ──────────────────────────────────────────
// Each union equals exactly the engines whose cap is true in ENGINE_CAPS.
const streamables: StreamableEngine[] = ['postgresql', 'mongodb'];
streamables satisfies unknown;

// @ts-expect-error mysql.caps.stream === false → not a StreamableEngine
const wrongStream: StreamableEngine = 'mysql';
wrongStream satisfies unknown;

const tx: TransactionalEngine[] = ['postgresql', 'cockroachdb', 'mysql', 'mariadb'];
tx satisfies unknown;

// @ts-expect-error mongodb.caps.txIntra === false → not a TransactionalEngine
const wrongTx: TransactionalEngine = 'mongodb';
wrongTx satisfies unknown;

const upsertable: UpsertableEngine[] = [
  'postgresql',
  'cockroachdb',
  'mongodb',
  'mysql',
  'mariadb',
  'redis',
  'sqlite',
  'mssql',
  'http',
];
upsertable satisfies unknown;

// @ts-expect-error 'oracle' is not an engine the data plane serves
const wrongUpsert: UpsertableEngine = 'oracle';
wrongUpsert satisfies unknown;
