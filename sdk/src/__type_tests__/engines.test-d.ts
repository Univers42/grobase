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
//   cd apps/baas/sdk && npx tsc --noEmit -p tsconfig.json

import type { EngineClient, StreamableEngine, TransactionalEngine, UpsertableEngine } from '../index.js';

// ── 1) Always-present base operations ────────────────────────────────────────
declare const pg: EngineClient<'postgresql', { id: string; name: string }>;
declare const mongo: EngineClient<'mongodb', { _id: string; amount: number }>;
declare const redis: EngineClient<'redis', { id: string; value: string }>;
declare const http: EngineClient<'http', { id: string; payload: unknown }>;

// All five base ops exist on every engine — these must type-check.
pg.list satisfies unknown;
pg.get satisfies unknown;
pg.insert satisfies unknown;
pg.update satisfies unknown;
pg.delete satisfies unknown;
mongo.list satisfies unknown;
redis.list satisfies unknown;
http.list satisfies unknown;

// ── 2) Capability narrowing — POSITIVE cases (must compile) ──────────────────
// postgresql.caps.txIntra === true  → transaction() exists
pg.transaction satisfies unknown;
// postgresql.caps.upsert === false  → upsert is absent (positive: redis has it)
redis.upsert satisfies unknown;
// mongodb.caps.stream === true      → subscribe() exists
mongo.subscribe satisfies unknown;
// http.caps.upsert === true         → upsert() exists
http.upsert satisfies unknown;

// ── 3) Capability narrowing — NEGATIVE cases (must FAIL to compile) ─────────
// If any of these lines silently compile, the type narrowing is broken.

// @ts-expect-error postgresql.caps.upsert === false → no .upsert()
pg.upsert satisfies unknown;

// @ts-expect-error postgresql.caps.stream === false → no .subscribe()
pg.subscribe satisfies unknown;

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

// ── 4) Discriminated-union helpers ──────────────────────────────────────────
// `StreamableEngine` should equal exactly the engines whose caps.stream===true.
// Post-audit: the 6 stub engines (jdbc/cassandra/neo4j/elasticsearch/qdrant/
// influx) were dropped from ENGINE_CAPS, so they no longer appear in these
// derived union types. Tests check the 5 real engines only.
const streamables: StreamableEngine[] = ['mongodb'];
streamables satisfies unknown;

// @ts-expect-error postgresql.caps.stream === false → not a StreamableEngine
const wrongStream: StreamableEngine = 'postgresql';
wrongStream satisfies unknown;

// `TransactionalEngine` should equal exactly engines with txIntra===true.
const tx: TransactionalEngine[] = ['postgresql', 'mysql'];
tx satisfies unknown;

// @ts-expect-error mongodb.caps.txIntra === false → not a TransactionalEngine
const wrongTx: TransactionalEngine = 'mongodb';
wrongTx satisfies unknown;

// `UpsertableEngine` excludes postgresql (caps.upsert === false).
const upsertable: UpsertableEngine[] = ['mysql', 'redis', 'http'];
upsertable satisfies unknown;

// @ts-expect-error postgresql.caps.upsert === false → not an UpsertableEngine
const wrongUpsert: UpsertableEngine = 'postgresql';
wrongUpsert satisfies unknown;
