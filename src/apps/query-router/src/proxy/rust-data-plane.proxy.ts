/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   rust-data-plane.proxy.ts                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/02 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/02 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { HttpService } from '@nestjs/axios';
import {
  BadGatewayException,
  BadRequestException,
  ConflictException,
  Injectable,
  Logger,
  UnprocessableEntityException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { firstValueFrom } from 'rxjs';
import type { AdapterOp, QueryOpts, QueryResult } from '@mini-baas/database';

/**
 * Substitution layer between the NestJS query-router and the Rust
 * `data-plane-router`. When `RUST_DATA_PLANE_FORWARD=1` is set and the engine
 * is in {`postgresql`, `mongodb`}, this proxy:
 *
 * 1. Builds the Rust router's request envelope (`identity` + `mount` + `operation`).
 * 2. Forwards over HTTP to `POST {RUST_DATA_PLANE_URL}/v1/query`.
 * 3. Normalises the Rust `DataResult` back into the legacy `QueryResult` shape
 *    so existing controllers, the outbox emitter, and the SDK keep working
 *    untouched during the migration.
 *
 * Why a proxy (not a direct re-implementation):
 *   * The Rust router owns long-lived per-mount pools — every TS adapter
 *     currently creates a fresh client per call (the "fastest use" target).
 *   * Migrating one engine at a time means parity is verifiable; if Rust
 *     misbehaves we flip the flag back to TS without touching code.
 *   * Once parity is proven, the TS PG/Mongo engines are deleted in one PR
 *     (see `wiki/back/typescript-substitution-audit.md`).
 *
 * Design pattern: this is a **Strategy** registered next to the in-process
 * adapters. The QueryService picks one or the other based on env + engine,
 * never both. No silent fallback unless the proxy explicitly fails over.
 */
export interface RustProxyContext {
  databaseId: string;
  engine: string;
  tenantId: string;
  projectId?: string;
  appId?: string;
  userId: string;
  credentialReference: string;
  credentialVersion: string;
  /** Resolved DSN from adapter-registry; passed inline so the Rust router
   *  doesn't need to re-fetch it. */
  connectionString: string;
  /** Tenant isolation strategy for this mount (shared_rls default |
   *  schema_per_tenant | db_per_tenant). The Rust pool uses it to pin
   *  `search_path` for schema_per_tenant mounts. */
  isolation?: string;
  /** Phase 4 tiering: the tenant's package capability mask (capability bools +
   *  rps/burst) from adapter-registry. Stamped onto the mount so the Rust
   *  planner narrows by it (403) and the token bucket reads rps/burst (429).
   *  Absent → untiered (parity, no enforcement). */
  capabilityOverrides?: Record<string, unknown>;
  /** Correlation id + W3C trace context, forwarded so the Rust data plane logs
   *  join the same distributed trace as the gateway and this service. */
  requestId?: string;
  traceparent?: string;
}

/** Cost-model hints carried in the Rust router's capability descriptor (G6).
 *  Mirrors `data_plane_core::CostCapabilities` (snake_case on the wire). */
export interface RustCostCapabilities {
  latency_class: string;
  pattern_search: string;
  joins: string;
}

/** One engine's descriptor from the Rust router's `/v1/capabilities`. Mirrors
 *  `data_plane_core::EngineCapabilities` — the source of truth the SDK is typed
 *  against. Kept loose (`Record`-friendly) so adding a flag in Rust doesn't
 *  break this passthrough. */
export interface RustEngineCapabilities {
  read: boolean;
  write: boolean;
  upsert: boolean;
  batch?: boolean;
  aggregate?: boolean;
  stream: boolean;
  ddl: boolean;
  transactions: boolean;
  cost: RustCostCapabilities;
  [key: string]: unknown;
}

export interface RustEngineDescriptor {
  engine: string;
  phase: string;
  capabilities: RustEngineCapabilities;
}

/** The full `/v1/capabilities` payload from the Rust data-plane-router. */
export interface RustCapabilitiesResponse {
  router: Record<string, unknown>;
  engines: RustEngineDescriptor[];
}

/** One column from the Rust router's `POST /v1/schema` descriptor. Mirrors
 *  `data_plane_core::ColumnSchema` (snake_case on the wire). */
export interface RustColumnSchema {
  name: string;
  native_type: string;
  /** text|integer|float|decimal|boolean|date|datetime|json|uuid|enum|array|objectid|unknown */
  normalized_type: string;
  nullable: boolean;
  default: string | null;
  enum_values: string[] | null;
  references: { table: string; column: string } | null;
  /** true only for Mongo sample-based inference. */
  inferred: boolean;
}

/** One table/collection from `POST /v1/schema`. */
export interface RustTableSchema {
  name: string;
  primary_key: string[];
  columns: RustColumnSchema[];
}

/** The full `POST /v1/schema` payload — `data_plane_core::SchemaDescriptor`. */
export interface RustSchemaDescriptor {
  engine: string;
  tables: RustTableSchema[];
}

/** One DDL column definition — `data_plane_core::DdlColumnDef` (snake_case on
 *  the wire). The FULL definition: the service composes it before calling,
 *  because engines like MySQL (`MODIFY COLUMN`) reset omitted attributes. */
export interface RustDdlColumnDef {
  name: string;
  normalized_type: string;
  nullable: boolean;
  default: string | null;
  enum_values: string[] | null;
}

/** The `ddl` object of `POST /v1/schema/ddl` — `data_plane_core::SchemaDdlRequest`. */
export interface RustSchemaDdlRequest {
  op: string;
  table: string;
  column?: RustDdlColumnDef | null;
  column_name?: string | null;
  columns?: RustDdlColumnDef[] | null;
  primary_key?: string[] | null;
}

/** `POST /v1/schema/ddl` response — `data_plane_core::SchemaDdlResult`. */
export interface RustSchemaDdlResult {
  op: string;
  table: string;
  status: string;
}

@Injectable()
export class RustDataPlaneProxy {
  private readonly logger = new Logger(RustDataPlaneProxy.name);
  private readonly url: string;
  private readonly forwardEnabled: boolean;
  private readonly forwardEngines: ReadonlySet<string>;
  private readonly timeoutMs: number;
  private readonly serviceToken: string;
  private readonly capsTtlMs: number;
  /** Shared TTL cache for the `/v1/capabilities` descriptor (G6, N3). Both the
   *  `/capabilities` and `/engines` controllers read it through
   *  {@link getCapabilitiesCached} so there is ONE cache and ONE in-flight
   *  fetch — no duplicate TTL caches, no thundering herd on a cold miss. */
  private capsCache?: { value: RustCapabilitiesResponse; expiresAt: number };
  /** In-flight fetch guard: concurrent misses share this promise instead of
   *  each firing their own upstream call. Cleared on settle so a failure is
   *  never cached (a transient error must not poison the next request). */
  private capsInFlight?: Promise<RustCapabilitiesResponse>;

  constructor(
    config: ConfigService,
    private readonly http: HttpService,
  ) {
    // internal/loopback only — not externally exposed
    const dataPlaneScheme = 'http';
    this.url = config.get<string>(
      'RUST_DATA_PLANE_URL',
      `${dataPlaneScheme}://data-plane-router-rust:4011`,
    );
    this.forwardEnabled = ['1', 'true', 'on'].includes(
      (config.get<string>('RUST_DATA_PLANE_FORWARD', '0') ?? '0').toLowerCase(),
    );
    const enginesEnv = config.get<string>('RUST_DATA_PLANE_FORWARD_ENGINES', 'postgresql,mongodb');
    this.forwardEngines = new Set(
      enginesEnv
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .filter(Boolean),
    );
    this.timeoutMs = Number(config.get<string>('RUST_DATA_PLANE_TIMEOUT_MS', '5000'));
    this.serviceToken = config.get<string>('ADAPTER_REGISTRY_SERVICE_TOKEN', '');
    this.capsTtlMs = Number(config.get<string>('QUERY_ROUTER_CAPS_CACHE_TTL_MS', '30000'));
  }

  /** Returns true when the proxy should handle this `(engine)` instead of TS. */
  shouldForward(engine: string): boolean {
    return this.forwardEnabled && this.forwardEngines.has(engine.toLowerCase());
  }

  /**
   * Engines this proxy forwards to the Rust data-plane-router. Used by
   * EnginesController to advertise the full backend catalog (TS-registered +
   * Rust-forwarded). When forwarding is disabled, returns an empty list — the
   * proxy doesn't claim engines it can't reach.
   */
  forwardedEngines(): string[] {
    if (!this.forwardEnabled) return [];
    return Array.from(this.forwardEngines.values()).sort((a, b) => a.localeCompare(b));
  }

  /**
   * Fetch the Rust data-plane-router's live `/v1/capabilities` descriptor — the
   * single source of truth for what each engine can do (G6). Used by the
   * `/capabilities` proxy controller and `/engines` to close the SDK drift
   * (no more hand-written capability stubs). The shape is the router's own
   * `CapabilitiesResponse` (`{ router, engines: [{ engine, phase, capabilities }] }`);
   * callers TTL-cache it so this hop stays off the hot path.
   */
  async fetchCapabilities(): Promise<RustCapabilitiesResponse> {
    try {
      const { data } = await firstValueFrom(
        this.http.get<RustCapabilitiesResponse>(`${this.url}/v1/capabilities`, {
          timeout: this.timeoutMs,
          headers: this.headersFor({} as RustProxyContext),
        }),
      );
      return data;
    } catch (error) {
      throw this.wrapError(error, 'capabilities');
    }
  }

  /**
   * TTL-cached, de-duplicated accessor for {@link fetchCapabilities} (G6, N3).
   * The Rust descriptor is process-wide-constant, so a short TTL keeps this hop
   * off the hot path while still picking up a router restart within one window.
   *
   * The single shared cache (used by both `/capabilities` and `/engines`)
   * replaces the two independent per-controller caches and adds an in-flight
   * promise guard: concurrent cold misses share ONE upstream fetch (no
   * thundering herd). Failures are never cached — the in-flight promise is
   * cleared on settle, so a transient error just re-fetches next call.
   */
  async getCapabilitiesCached(): Promise<RustCapabilitiesResponse> {
    const now = Date.now();
    if (this.capsCache && this.capsCache.expiresAt > now) return this.capsCache.value;
    if (this.capsInFlight !== undefined) return this.capsInFlight;
    this.capsInFlight = this.fetchCapabilities()
      .then((value) => {
        if (this.capsTtlMs > 0) {
          this.capsCache = { value, expiresAt: Date.now() + this.capsTtlMs };
        }
        return value;
      })
      .finally(() => {
        // Clear the guard on settle (success OR failure) so a rejection is not
        // retained — only successful values are ever cached above.
        this.capsInFlight = undefined;
      });
    return this.capsInFlight;
  }

  async execute(
    context: RustProxyContext,
    resource: string,
    op: AdapterOp,
    opts: QueryOpts,
  ): Promise<QueryResult> {
    const envelope = {
      identity: this.buildIdentity(context),
      mount: this.buildMount(context, resource),
      operation: this.buildOperation(resource, op, opts),
    };
    const data = await this.postJson<{ rows: unknown[]; affected_rows: number }>(
      '/v1/query',
      envelope,
      context,
      `${context.engine}.${resource}.${op}`,
    );
    return this.normalizeResult(data);
  }

  /**
   * Engine-agnostic schema introspection (M22): POSTs the `{ identity, mount }`
   * envelope to the Rust router's `/v1/schema` and returns its
   * `SchemaDescriptor` verbatim (tables + normalized columns + PK/FK + enum
   * values). Engines without an introspection surface (redis/http) are
   * rejected upstream with 422 `unsupported_capability`, which `postJson`
   * surfaces as a clean `UnprocessableEntityException`.
   */
  async describeSchema(context: RustProxyContext): Promise<RustSchemaDescriptor> {
    const body = {
      identity: this.buildIdentity(context),
      mount: this.buildMount(context, 'schema'),
    };
    return this.postJson<RustSchemaDescriptor>(
      '/v1/schema',
      body,
      context,
      `${context.engine}.schema`,
    );
  }

  /**
   * Engine-agnostic schema DDL (M22 step 2): POSTs the
   * `{ identity, mount, ddl }` envelope to the Rust router's `/v1/schema/ddl`
   * (one operation per request) and returns its `SchemaDdlResult` verbatim.
   * Error mapping mirrors {@link describeSchema}: a capability rejection
   * (redis/http) surfaces as 422 `unsupported_capability`, and "existing data
   * is incompatible with the new type" surfaces as a 409 Conflict — both
   * preserved by `postJson`.
   */
  async applySchemaDdl(
    context: RustProxyContext,
    ddl: RustSchemaDdlRequest,
  ): Promise<RustSchemaDdlResult> {
    const body = {
      identity: this.buildIdentity(context),
      mount: this.buildMount(context, 'schema'),
      ddl,
    };
    return this.postJson<RustSchemaDdlResult>(
      '/v1/schema/ddl',
      body,
      context,
      `${context.engine}.schema.ddl.${ddl.op}`,
    );
  }

  // ── Single-mount transactions ──────────────────────────────────────────────
  //
  // The data plane binds a transaction to ONE mount/connection (`POST
  // /v1/transactions`), so every op in the batch runs on the same backend and
  // commits/rolls back atomically — real ACID, but only within one mount. The
  // engine must advertise `transactions:true` (postgresql/mysql); mongo/redis/
  // http are rejected by the data plane with 400 `unsupported_capability`, which
  // `postJson` surfaces as a clean `BadRequestException`. Cross-mount atomicity
  // is a fundamentally different (2PC) problem and is NOT offered here.

  /** Open a transaction on `context`'s mount. `defaultResource` is cosmetic —
   *  the pool is keyed by tenant/project/dbId/engine, not by name. */
  async beginTransaction(context: RustProxyContext, defaultResource: string): Promise<string> {
    const body = {
      identity: this.buildIdentity(context),
      mount: this.buildMount(context, defaultResource),
    };
    const data = await this.postJson<{ tx_id: string }>('/v1/transactions', body, context);
    return data.tx_id;
  }

  async executeInTransaction(
    context: RustProxyContext,
    txId: string,
    resource: string,
    op: AdapterOp,
    opts: QueryOpts,
  ): Promise<QueryResult> {
    const body = {
      identity: this.buildIdentity(context),
      operation: this.buildOperation(resource, op, opts),
    };
    const data = await this.postJson<{ rows: unknown[]; affected_rows: number }>(
      `/v1/transactions/${encodeURIComponent(txId)}/execute`,
      body,
      context,
    );
    return this.normalizeResult(data);
  }

  async commitTransaction(context: RustProxyContext, txId: string): Promise<void> {
    await this.postJson(`/v1/transactions/${encodeURIComponent(txId)}/commit`, {}, context);
  }

  async rollbackTransaction(context: RustProxyContext, txId: string): Promise<void> {
    await this.postJson(`/v1/transactions/${encodeURIComponent(txId)}/rollback`, {}, context);
  }

  // ── Envelope builders (shared by /v1/query and the transaction calls) ───────

  private buildIdentity(context: RustProxyContext): Record<string, unknown> {
    return {
      tenant_id: context.tenantId,
      project_id: context.projectId ?? null,
      app_id: context.appId ?? null,
      user_id: context.userId,
      // Must match data_plane_core::IdentitySource (snake_case): the TS proxy
      // talks to Rust via the internal HMAC envelope path.
      source: 'signed_envelope',
    };
  }

  private buildMount(context: RustProxyContext, name: string): Record<string, unknown> {
    return {
      id: context.databaseId,
      tenant_id: context.tenantId,
      project_id: context.projectId ?? null,
      engine: context.engine,
      name,
      credential_ref: {
        provider: 'adapter-registry',
        reference: context.credentialReference,
        version: context.credentialVersion,
      },
      pool_policy: { min: 0, max: 10, idle_ttl_ms: 30_000, max_lifetime_ms: 1_800_000 },
      // Phase 4 tiering: the tenant's package mask drives the Rust planner's
      // capability gate (403) + per-tenant token bucket (429). null → untiered.
      capability_overrides: context.capabilityOverrides ?? null,
      inline_dsn: context.connectionString,
      isolation: context.isolation ?? null,
    };
  }

  private buildOperation(
    resource: string,
    op: AdapterOp,
    opts: QueryOpts,
  ): Record<string, unknown> {
    // Batch wire shape: `data` carries the JSON array of sub-operations (the
    // planner sizes it against max_batch_size; adapters parse + validate it).
    // Each item's `resource` defaults to the request's own resource.
    const data =
      op === 'batch' && opts.operations
        ? opts.operations.map((item) => ({
            op: item.op,
            resource: item.resource ?? resource,
            data: item.data ?? null,
            filter: item.filter ?? null,
            sort: item.sort ?? null,
            limit: item.limit ?? null,
            offset: item.offset ?? null,
            idempotency_key: null,
            expected_version: null,
            returning: null,
            aggregate: null,
          }))
        : (opts.data ?? null);
    return {
      op,
      resource,
      data,
      filter: opts.filter ?? null,
      sort: opts.sort ?? null,
      limit: opts.limit ?? null,
      offset: opts.offset ?? null,
      idempotency_key: opts.idempotencyKey ?? null,
      expected_version: null,
      returning: null,
      // Map the client `aggregate` to the data-plane `AggregateSpec` wire shape
      // (camelCase `groupBy` → snake_case `group_by`). Present only for op=aggregate.
      aggregate: opts.aggregate
        ? {
            group_by: opts.aggregate.groupBy ?? [],
            aggregates: opts.aggregate.aggregates.map((a) => ({
              func: a.func,
              field: a.field ?? null,
              distinct: a.distinct ?? false,
              alias: a.alias,
            })),
          }
        : null,
    };
  }

  private headersFor(context: RustProxyContext): Record<string, string> {
    const headers: Record<string, string> = {};
    if (this.serviceToken) headers['X-Service-Token'] = this.serviceToken;
    if (context.requestId) headers['x-request-id'] = context.requestId;
    if (context.traceparent) headers['traceparent'] = context.traceparent;
    return headers;
  }

  private normalizeResult(data: {
    rows?: unknown[];
    affected_rows?: number;
    batch?: QueryResult['batch'];
  }): QueryResult {
    const rows = Array.isArray(data?.rows) ? (data.rows as Record<string, unknown>[]) : [];
    const rowCount = typeof data?.affected_rows === 'number' ? data.affected_rows : rows.length;
    // Batch summaries (op=batch only) pass through additively.
    if (data?.batch) return { rows, rowCount, batch: data.batch };
    return { rows, rowCount };
  }

  /** POST JSON to the data plane, surfacing its 4xx (e.g. a capability/validation
   *  rejection) as a `BadRequestException` and anything else as `BadGateway`. */
  private async postJson<T>(
    path: string,
    body: unknown,
    context: RustProxyContext,
    label = path,
  ): Promise<T> {
    try {
      const { data } = await firstValueFrom(
        this.http.post<T>(`${this.url}${path}`, body, {
          timeout: this.timeoutMs,
          headers: this.headersFor(context),
        }),
      );
      return data;
    } catch (error) {
      throw this.wrapError(error, label);
    }
  }

  private wrapError(error: unknown, label: string): Error {
    const status =
      typeof error === 'object' && error !== null
        ? (
            error as {
              response?: { status?: number; data?: { error?: string; message?: string } };
            }
          ).response
        : undefined;
    const dpMessage = status?.data?.message;
    // The data plane's `ApiError` envelope carries a machine-readable code in
    // `error` (e.g. "unsupported_capability", "conflict") alongside `message`.
    const dpCode = status?.data?.error;
    if (status?.status === 409) {
      // Integrity-constraint violation (dup PK, FK, …) — a real conflict, not a
      // generic bad request. Preserve the 409 so clients can handle it.
      return new ConflictException(dpMessage ?? `conflict on ${label}`);
    }
    if (status?.status === 422) {
      // Capability rejection (G6): the request is well-formed but the engine
      // can't serve it (e.g. `unsupported_capability`). The data plane now
      // returns 422 here — preserve it (instead of collapsing to 400) so clients
      // can branch on the upstream `error` code. Mirrors the 409 special-case.
      return new UnprocessableEntityException({
        statusCode: 422,
        error: dpCode ?? 'unprocessable_entity',
        message: dpMessage ?? `data-plane rejected ${label}`,
      });
    }
    if (status?.status && status.status >= 400 && status.status < 500) {
      return new BadRequestException(dpMessage ?? `data-plane rejected ${label}`);
    }
    const message = error instanceof Error ? error.message : 'unknown error';
    this.logger.warn(`Rust data-plane forward for ${label} failed: ${message}`);
    return new BadGatewayException(`Rust data-plane forward failed: ${message}`);
  }
}
