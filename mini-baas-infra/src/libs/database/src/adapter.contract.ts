/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   adapter.contract.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 21:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

/**
 * Unified database adapter contract (M1 hardening).
 *
 * All engines registered with the query-router must implement this interface
 * so the router can dispatch by `engine` name via a Map<string, IDatabaseAdapter>
 * instead of the previous `if (engine === 'postgresql') ...` chains. This is
 * what allows M2 to add MySQL, Redis, HTTP engines without touching the
 * dispatcher.
 */

/** Coarse capability flags advertised by each adapter for the planner. */
export type EngineJoinCapability = 'native' | 'limited' | 'none';
export type EnginePatternSearchCapability = 'native' | 'indexed' | 'limited' | 'scan' | 'remote' | 'none';
export type EngineLatencyClass = 'native' | 'adapter' | 'fdw' | 'remote';

export interface EngineSemanticCaps {
  /** Whether relation-style joins are native, limited, or impossible for this engine. */
  joins: EngineJoinCapability;
  /** Whether LIKE / text-pattern search is indexed/native or degrades into scans. */
  patternSearch: EnginePatternSearchCapability;
  /** Whether schema-service can create/drop resources for this engine. */
  ddl: boolean;
  /** Whether schema-service records cross-engine migration history for this engine. */
  migrationVersioning: boolean;
  /** Cost class exposed to SDK planners and users. */
  latencyClass: EngineLatencyClass;
}

export interface EngineCaps {
  /** Adapter can read rows / documents. */
  read: boolean;
  /** Adapter can write (insert / update / delete) rows / documents. */
  write: boolean;
  /** Adapter natively supports upsert (`INSERT ... ON CONFLICT`, `updateOne({upsert:true})`, etc.). */
  upsert: boolean;
  /** Adapter supports intra-engine transactions (BEGIN/COMMIT or session.withTransaction). */
  txIntra: boolean;
  /** Adapter exposes a change-stream / replication-feed for CDC. */
  stream: boolean;
  /** Semantic and cost model hints clients can use before choosing an operation. */
  semantic: EngineSemanticCaps;
}

/** Generic execution options passed to every adapter operation. */
export interface QueryOpts {
  /** Payload for `insert` / `update` / `upsert`. */
  data?: Record<string, unknown>;
  /** Filter conditions for `list` / `get` / `update` / `delete`. */
  filter?: Record<string, unknown>;
  /** Sort directive, e.g. `{ created_at: 'desc' }`. */
  sort?: Record<string, 'asc' | 'desc'>;
  /** Hard cap on returned rows (adapter may also enforce its own ceiling). */
  limit?: number;
  /** Offset / skip for pagination. */
  offset?: number;
  /** Calling user id — adapter uses it to enforce RLS / `owner_id` filters. */
  userId?: string;
  /** Verified tenant id — adapter uses it for tenant filters and RLS. */
  tenantId?: string;
  /** Verified project id for future project-scoped mounts/resources. */
  projectId?: string;
  /** Verified app/client id for ABAC and auditing. */
  appId?: string;
  /** Optional `Idempotency-Key` honoured by adapters that support it (M3). */
  idempotencyKey?: string;
  /** Aggregation request — required when `op = 'aggregate'`, ignored otherwise. */
  aggregate?: AggregateSpec;
  /** Sub-operations — required when `op = 'batch'`, ignored otherwise.
   *  Items may not themselves be batches; `resource` defaults to the
   *  request's resource. SQL engines run the batch atomically (one
   *  transaction); document/KV engines run it ordered, stop-on-first-error. */
  operations?: BatchOperation[];
}

/** One batch sub-operation (mirrors the data-plane wire shape). */
export interface BatchOperation {
  op: Exclude<AdapterOp, 'batch'>;
  /** Defaults to the batch request's own resource when omitted. */
  resource?: string;
  data?: Record<string, unknown>;
  filter?: Record<string, unknown>;
  sort?: Record<string, 'asc' | 'desc'>;
  limit?: number;
  offset?: number;
}

/** An allowlisted SQL aggregate function (mirrors data-plane `AggFunc`). */
export type AggregateFunc = 'count' | 'sum' | 'avg' | 'min' | 'max';

/** One aggregate output column: `func(field) AS alias`. `field` is omitted for
 *  `count` (→ `COUNT(*)`), required for the others. */
export interface AggregateColumn {
  func: AggregateFunc;
  field?: string;
  distinct?: boolean;
  alias: string;
}

/** A GROUP BY + aggregate request (mirrors data-plane `AggregateSpec`). The
 *  operation's `filter` scopes the rows before grouping. */
export interface AggregateSpec {
  groupBy?: string[];
  aggregates: AggregateColumn[];
}

/** Standard shape returned by every adapter call. */
export interface QueryResult {
  rows: Record<string, unknown>[];
  rowCount: number;
  /** Per-item outcomes — present only for `op = 'batch'` (additive). */
  batch?: BatchResultSummary;
}

/** Batch result envelope (mirrors the data-plane `BatchSummary`). */
export interface BatchResultSummary {
  /** `true` → all-or-nothing; `false` → ordered, earlier items persisted. */
  atomic: boolean;
  items: Array<{
    index: number;
    status: 'ok' | 'error' | 'skipped';
    affected_rows: number;
    error?: string;
  }>;
}

/** Canonical operation set the router dispatches across engines. */
export type AdapterOp =
  | 'list'
  | 'get'
  | 'insert'
  | 'update'
  | 'delete'
  | 'upsert'
  | 'aggregate'
  | 'batch';

/**
 * Contract every database engine must satisfy to plug into the query-router.
 *
 * Adapters that do not natively support a given `AdapterOp` should still
 * declare a coherent `capabilities()` (with the matching flag `false`) and
 * throw `NotImplementedException` when called, rather than silently mapping
 * to a different operation.
 */
export interface IDatabaseAdapter {
  /** Short engine identifier — matches the value stored in `tenant_databases.engine`. */
  readonly engine: string;

  /** Static capability descriptor — used by the planner to reject impossible ops early. */
  capabilities(): EngineCaps;

  /** Execute one operation on a single resource (table / collection / key prefix / endpoint). */
  execute(
    connectionString: string,
    resource: string,
    op: AdapterOp,
    opts: QueryOpts,
  ): Promise<QueryResult>;

  /** List addressable resources in the target database (tables / collections / etc.). */
  listResources(connectionString: string, dbName?: string): Promise<string[]>;
}
