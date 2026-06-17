/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.service.ts                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
  OnModuleInit,
  ServiceUnavailableException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';
import type { VerifiedRequestIdentity } from '@mini-baas/common';
import { serviceAuthHeaders } from '@mini-baas/common';
import type { EngineCaps, IDatabaseAdapter, QueryResult } from '@mini-baas/database';
// All TS in-process engines have been removed. The 5 real engines
// (postgresql/mongodb/mysql/redis/http) flow through `RustDataPlaneProxy` to
// the Rust data-plane-router. The 6 former stubs (jdbc/cassandra/neo4j/
// elasticsearch/qdrant/influx) were deleted instead of advertised, because
// they returned NotImplemented on most ops and pretending otherwise lied to
// SDK consumers. Re-introducing any of them requires a real Rust adapter,
// not a TS stub.
import { ExecuteQueryDto } from './dto/query.dto';
import { TxnOpDto } from './dto/txn.dto';
import { OutboxService } from './outbox.service';
import { AutomationsService, type AutomationWriteEvent } from './automations.service';
import { RealtimePublisherService, RealtimeWriteOp } from './realtime-publisher.service';
import { RustDataPlaneProxy, RustProxyContext } from '../proxy/rust-data-plane.proxy';

/** Ops that fan out as best-effort `row_changed` realtime events (mirrors the
 *  outbox's MUTATING_OPS — reads never publish). */
const REALTIME_WRITE_OPS: ReadonlySet<string> = new Set(['insert', 'update', 'delete', 'upsert']);

export interface AdapterResponse {
  engine: string;
  connection_string: string;
  // Tenant isolation strategy from adapter-registry (shared_rls default |
  // schema_per_tenant | db_per_tenant). Forwarded to the Rust data plane so a
  // schema_per_tenant mount is scoped to its tenant schema at query time.
  isolation?: string;
  // Phase 4 tiering: the resolved package name + its capability mask
  // (capability bools + rps/burst), derived by adapter-registry from the
  // tenant's plan. Stamped onto the mount forwarded to Rust, where the planner
  // narrows by it (403 capability_gated) and the token bucket reads rps/burst
  // (429). Absent when tiering is disabled (parity).
  package?: string;
  capability_overrides?: Record<string, unknown>;
}

export interface EngineDescriptor {
  engine: string;
  capabilities: EngineCaps;
}

interface QueryRequestContext {
  requestId?: string;
  identity?: VerifiedRequestIdentity;
  /** Caller IP (same source as audit.interceptor.ts) — fed to the PDP attrs so
   *  ip_cidr conditions can decide. Undefined when not derivable. */
  ip?: string;
  /** Per-instance subject id (dto.filter?.id) — fed to the PDP so resource_id /
   *  resource_id_in conditions can decide per-row (B3). Inert when conditions off. */
  resourceId?: string;
  /** >0 on automation follow-up writes — they never re-trigger (loop safety). */
  automationDepth?: number;
}

interface FieldMask {
  hide?: string[];
  redact?: Record<string, string>;
}

interface PermissionDecision {
  allow: boolean;
  reason: string;
  mask?: FieldMask;
}

/** Per-operation outcome inside a committed transaction. */
export interface TxnOpResult {
  op: string;
  resource: string;
  rowCount: number;
}

/** Result of a single-mount atomic batch (`POST /txn`). `atomic` is the real
 *  ACID tier — every op committed on one backend, or none did. */
export interface TxnResult {
  guarantee: 'atomic';
  mount: string;
  results: TxnOpResult[];
}

/** Cache entry for resolved DSNs. Keyed by `${tenantId}:${dbId}`. */
interface DsnCacheEntry {
  value: AdapterResponse;
  expiresAt: number;
}

/**
 * Parses `DATA_PLANE_MOUNTS` env into a static dbId → {engine, dsn} map.
 *
 * Accepts two JSON shapes:
 *
 *   1. Reference-keyed (matches the Rust router's EnvMountResolver):
 *        `{"ref-1": "postgres://...", "ref-2": "mongodb://..."}`
 *      The engine is inferred from the DSN scheme.
 *
 *   2. dbId-keyed object (preferred for query-router; carries engine):
 *        `{"<dbId>": {"engine":"mysql","connection_string":"mysql://..."}}`
 *
 * Lean deploys typically use form 2 with a small set of well-known dbIds.
 * Empty or malformed input yields an empty map — adapter-registry stays
 * primary in that case.
 */
function parseStaticMounts(
  raw: string,
): Map<string, { engine: string; connection_string: string }> {
  const out = new Map<string, { engine: string; connection_string: string }>();
  const parsed = safeJsonParse(raw);
  if (!isPlainObject(parsed)) return out;
  for (const [key, value] of Object.entries(parsed)) {
    const entry = staticMountFromValue(value);
    if (entry) out.set(key, entry);
  }
  return out;
}

function safeJsonParse(raw: string): unknown {
  const trimmed = raw.trim();
  if (!trimmed) return undefined;
  try {
    return JSON.parse(trimmed);
  } catch {
    return undefined;
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}

function staticMountFromValue(
  value: unknown,
): { engine: string; connection_string: string } | undefined {
  if (typeof value === 'string') {
    const engine = inferEngineFromDsn(value);
    return engine ? { engine, connection_string: value } : undefined;
  }
  if (!isPlainObject(value)) return undefined;
  const engine = typeof value.engine === 'string' ? value.engine : undefined;
  const dsn = typeof value.connection_string === 'string' ? value.connection_string : undefined;
  return engine && dsn ? { engine, connection_string: dsn } : undefined;
}

function inferEngineFromDsn(dsn: string): string | undefined {
  const colon = dsn.indexOf(':');
  if (colon <= 0) return undefined;
  const scheme = dsn.slice(0, colon).toLowerCase();
  switch (scheme) {
    case 'postgres':
    case 'postgresql':
      return 'postgresql';
    case 'mysql':
      return 'mysql';
    case 'mongodb':
    case 'mongodb+srv':
      return 'mongodb';
    case 'redis':
    case 'rediss':
      return 'redis';
    case 'http':
    case 'https':
      return 'http';
    default:
      return undefined;
  }
}

@Injectable()
export class QueryService implements OnModuleInit {
  private readonly logger = new Logger(QueryService.name);
  private readonly registryUrl: string;
  private readonly permissionUrl: string;
  private readonly serviceToken: string;
  private readonly controlPlaneTimeoutMs: number;
  private readonly adapters = new Map<string, IDatabaseAdapter>();
  // adapter-registry decrypts the DSN on every /connect call; a short TTL
  // cache cuts that hop out of the hot path while still letting credential
  // rotation propagate in seconds, not days.
  private readonly dsnCache = new Map<string, DsnCacheEntry>();
  private readonly dsnCacheTtlMs: number;
  private readonly dsnCacheMaxEntries: number;
  // Static mount table for lean / single-tenant deploys that don't want to
  // run adapter-registry-go. Same env name + JSON shape the Rust router
  // reads — share a single source of truth across the stack.
  private readonly staticMounts: Map<string, { engine: string; connection_string: string }>;
  // B5: when ON, api-key callers STOP short-circuiting on scope and instead
  // flow through the ABAC PDP (their scope is projected to apikey:read/write/
  // admin role membership seeded in migration 063), so they get the SAME masks
  // + conditions a JWT caller gets. OFF (default) ⇒ today's decideByApiKeyScope
  // — byte-identical scope-only decision.
  private readonly apiKeyAbacEnabled: boolean;

  constructor(
    private readonly config: ConfigService,
    private readonly http: HttpService,
    private readonly outbox: OutboxService,
    private readonly rustProxy: RustDataPlaneProxy,
    private readonly realtime: RealtimePublisherService,
    private readonly automations: AutomationsService,
  ) {
    this.registryUrl = this.config.getOrThrow<string>('ADAPTER_REGISTRY_URL');
    // internal/loopback only — not externally exposed
    const permissionScheme = 'http';
    this.permissionUrl = this.config.get<string>(
      'PERMISSION_ENGINE_URL',
      `${permissionScheme}://permission-engine:3050`,
    );
    this.serviceToken = this.config.get<string>('ADAPTER_REGISTRY_SERVICE_TOKEN', '');
    this.controlPlaneTimeoutMs = this.config.get<number>('CONTROL_PLANE_TIMEOUT_MS', 2_000);
    this.dsnCacheTtlMs = Number(
      this.config.get<string>('QUERY_ROUTER_DSN_CACHE_TTL_MS', '30000'),
    );
    this.dsnCacheMaxEntries = Number(
      this.config.get<string>('QUERY_ROUTER_DSN_CACHE_MAX_ENTRIES', '500'),
    );
    this.staticMounts = parseStaticMounts(
      this.config.get<string>('DATA_PLANE_MOUNTS', '') ?? '',
    );
    this.apiKeyAbacEnabled = ['1', 'true', 'yes', 'on'].includes(
      (this.config.get<string>('API_KEY_ABAC_ENABLED', '0') ?? '0').toLowerCase(),
    );
    if (this.apiKeyAbacEnabled) {
      this.logger.log(
        'API_KEY_ABAC_ENABLED=1 — api-key callers flow through the ABAC PDP (scope→role projection) for masks/conditions',
      );
    }
    if (this.staticMounts.size > 0) {
      this.logger.log(
        `Static mount table loaded (${this.staticMounts.size} entries) — adapter-registry will be bypassed for matching dbIds`,
      );
    }
  }

  onModuleInit(): void {
    this.registerAdapters();
  }

  private registerAdapters(): void {
    // No TS adapters remain — every supported engine forwards to Rust via
    // RustDataPlaneProxy. Method kept for API stability (callers still invoke
    // it from listEngines/resolveAdapter) but the map is empty by design.
    if (this.adapters.size === 0) {
      this.logger.log(
        'No local TS adapters registered; all engines served by Rust data-plane-router',
      );
    }
  }

  /** Static introspection of every adapter currently mounted on this service. */
  listEngines(): EngineDescriptor[] {
    this.registerAdapters();
    return Array.from(this.adapters.values()).map((a) => ({
      engine: a.engine,
      capabilities: a.capabilities(),
    }));
  }

  /**
   * Public, additive wrapper over the private {@link fetchConnection} so
   * sibling services (SchemaService) can resolve a mount's engine + DSN +
   * isolation without duplicating the static-mount/registry/cache logic.
   * Same semantics: static `DATA_PLANE_MOUNTS` bypass first, then the
   * TTL-cached adapter-registry `/connect` hop.
   */
  async resolveConnection(dbId: string, tenantId: string): Promise<AdapterResponse> {
    return this.fetchConnection(dbId, tenantId);
  }

  private async fetchConnection(dbId: string, userId: string): Promise<AdapterResponse> {
    // Bypass path: lean deploys can ship a static DATA_PLANE_MOUNTS map and
    // skip running adapter-registry-go entirely. Match by dbId only — the
    // tenant scope is already enforced by the per-mount Rust pool.
    const staticMount = this.staticMounts.get(dbId);
    if (staticMount) {
      return staticMount;
    }
    if (this.dsnCacheTtlMs <= 0) {
      return this.fetchConnectionFromRegistry(dbId, userId);
    }
    const cacheKey = `${userId}:${dbId}`;
    const cached = this.readDsnCache(cacheKey);
    if (cached) return cached;
    const fresh = await this.fetchConnectionFromRegistry(dbId, userId);
    this.writeDsnCache(cacheKey, fresh);
    return fresh;
  }

  private readDsnCache(cacheKey: string): AdapterResponse | undefined {
    const entry = this.dsnCache.get(cacheKey);
    if (!entry) return undefined;
    if (entry.expiresAt <= Date.now()) {
      this.dsnCache.delete(cacheKey);
      return undefined;
    }
    return entry.value;
  }

  private writeDsnCache(cacheKey: string, value: AdapterResponse): void {
    this.evictDsnCacheIfFull();
    this.dsnCache.set(cacheKey, { value, expiresAt: Date.now() + this.dsnCacheTtlMs });
  }

  private evictDsnCacheIfFull(): void {
    if (this.dsnCache.size < this.dsnCacheMaxEntries) return;
    const now = Date.now();
    // Lazy reap: cheaper than a separate timer for typical workloads.
    for (const [key, entry] of this.dsnCache) {
      if (entry.expiresAt <= now) this.dsnCache.delete(key);
    }
    // Still over capacity → drop the oldest (Map iteration is insertion order).
    if (this.dsnCache.size >= this.dsnCacheMaxEntries) {
      const oldest = this.dsnCache.keys().next().value;
      if (oldest) this.dsnCache.delete(oldest);
    }
  }

  private async fetchConnectionFromRegistry(dbId: string, userId: string): Promise<AdapterResponse> {
    const path = `/databases/${dbId}/connect`;
    const url = `${this.registryUrl}${path}`;
    try {
      const { data } = await firstValueFrom(
        this.http.get<AdapterResponse>(url, {
          headers: {
            // hmac mode replaces the raw token with a per-request signature (O1).
            ...serviceAuthHeaders(this.serviceToken, 'GET', path, ''),
            'X-Tenant-Id': userId,
          },
        }),
      );
      return data;
    } catch (error) {
      // adapter-registry scopes /connect to the caller's tenant (mount.tenant_id
      // == X-Tenant-Id); an unknown OR cross-tenant dbId is a 404 there. Surface
      // it as a clean 404, not the opaque 500 an unhandled axios reject becomes
      // — the dbId is either wrong or not this tenant's.
      const status = (error as { response?: { status?: number } })?.response?.status;
      if (status === 404) {
        throw new NotFoundException(`Database mount '${dbId}' was not found for this tenant.`);
      }
      throw error;
    }
  }

  private resolveAdapter(engine: string): IDatabaseAdapter {
    this.registerAdapters();
    const adapter = this.adapters.get(engine);
    if (!adapter) {
      throw new BadRequestException(
        `Unsupported engine '${engine}'. Registered engines: ${Array.from(this.adapters.keys()).join(', ')}`,
      );
    }
    return adapter;
  }

  async executeQuery(
    dbId: string,
    resource: string,
    userId: string,
    dto: ExecuteQueryDto,
    context: QueryRequestContext = {},
  ) {
    const identity = context.identity;
    const tenantId = identity?.tenantId ?? userId;
    // Guard against a malformed body that didn't deserialize into an ExecuteQueryDto
    // instance (e.g. a JSON array or primitive): calling resolveOp() on a plain object
    // throws a TypeError -> 500. That's a client error, so reject it cleanly as 400.
    if (typeof (dto as { resolveOp?: unknown })?.resolveOp !== 'function') {
      throw new BadRequestException(
        'Invalid request body: expected a single operation object.',
      );
    }
    const op = dto.resolveOp();
    if (!op) {
      throw new BadRequestException(
        'Missing operation: provide `op` (preferred) or the deprecated `action` field.',
      );
    }

    const { engine, connection_string, isolation, capability_overrides } =
      await this.fetchConnection(dbId, tenantId);
    // Per-instance subject for B3 conditions: the row id the caller is acting
    // on (filter.id). Inert unless PERMISSION_CONDITIONS_ENABLED is on.
    const resourceId = this.resourceIdFromFilter(dto.filter);
    const decision = await this.decidePermission(userId, engine, resource, op, {
      ...context,
      resourceId,
    });
    if (!decision.allow) {
      throw new ForbiddenException(decision.reason);
    }

    if (dto.action && !dto.op) {
      this.logger.warn(
        `[deprecated] action='${dto.action}' received — switch to op='${op}' before the next minor release.`,
      );
    }

    // Strategy: forward to Rust data-plane-router when RUST_DATA_PLANE_FORWARD=1
    // is set AND the engine has a Rust pool (postgresql, mongodb today). The
    // proxy uses long-lived per-mount pools so we stop paying the per-call
    // `new Client()` cost. TS adapters stay as fallback for offline/dev mode
    // and engines without a Rust port yet.
    const opts = {
      data: dto.data,
      filter: dto.filter,
      sort: dto.sort,
      limit: dto.limit,
      offset: dto.offset,
      userId,
      tenantId,
      projectId: identity?.projectId,
      appId: identity?.appId,
      idempotencyKey: dto.idempotencyKey,
      aggregate: dto.aggregate,
      operations: dto.operations,
    };

    let result: QueryResult;
    if (this.rustProxy.shouldForward(engine)) {
      this.logger.debug(`[rust-forward] ${engine}.${resource}.${op}`);
      result = await this.rustProxy.execute(
        {
          databaseId: dbId,
          engine,
          tenantId,
          projectId: identity?.projectId,
          appId: identity?.appId,
          userId,
          credentialReference: dbId,
          credentialVersion: 'live',
          connectionString: connection_string,
          isolation,
          capabilityOverrides: capability_overrides,
          requestId: context.requestId,
        },
        resource,
        op,
        opts,
      );
    } else {
      const adapter = this.resolveAdapter(engine);
      result = await adapter.execute(connection_string, resource, op, opts);
    }

    await this.outbox
      .emitForQuery({
        engine,
        resource,
        op,
        result,
        data: dto.data,
        filter: dto.filter,
        requestId: context.requestId,
        actorId: userId,
        tenantId,
        idempotencyKey: dto.idempotencyKey,
      })
      .catch((error: Error) => {
        this.logger.warn(`outbox emission failed for ${engine}.${resource}.${op}: ${error.message}`);
      });

    // Best-effort realtime fan-out — fire-and-forget so the write response is
    // never delayed; the publisher swallows every failure internally.
    if (REALTIME_WRITE_OPS.has(op)) {
      const pk = result.rows[0]?.['id'] ?? dto.data?.['id'] ?? dto.filter?.['id'];
      void this.realtime.publishRowChanged(dbId, resource, op as RealtimeWriteOp, {
        filter: dto.filter,
        idempotencyKey: dto.idempotencyKey,
        pk,
      });
      this.fireAutomations({
        dbId,
        tenantId,
        userId,
        table: resource,
        op: op as RealtimeWriteOp,
        row: result.rows[0] ?? { ...dto.filter, ...dto.data },
        pk,
      }, context);
    }

    return this.applyFieldMask(result, decision.mask);
  }

  /**
   * Single-mount atomic batch: every op runs in ONE backend transaction on
   * `dbId` and commits all-or-nothing (rolled back on the first failure). This
   * is the real ACID tier (`guarantee: 'atomic'`) — but only within one mount;
   * the data plane rejects non-transactional engines (mongo/redis/http) with a
   * clean 400. Every op is permission-checked up front, so the whole batch is
   * denied before any write happens if any op is unauthorized.
   */
  async executeTransaction(
    dbId: string,
    userId: string,
    ops: TxnOpDto[],
    context: QueryRequestContext = {},
  ): Promise<TxnResult> {
    const identity = context.identity;
    const tenantId = identity?.tenantId ?? userId;
    const { engine, connection_string, isolation, capability_overrides } =
      await this.fetchConnection(dbId, tenantId);

    // Authorize every op BEFORE opening the transaction — fail the batch closed.
    for (const o of ops) {
      const decision = await this.decidePermission(userId, engine, o.resource, o.op, {
        ...context,
        resourceId: this.resourceIdFromFilter(o.filter),
      });
      if (!decision.allow) {
        throw new ForbiddenException(`op '${o.op} ${o.resource}': ${decision.reason}`);
      }
    }

    const proxyCtx: RustProxyContext = {
      databaseId: dbId,
      engine,
      tenantId,
      projectId: identity?.projectId,
      appId: identity?.appId,
      userId,
      credentialReference: dbId,
      credentialVersion: 'live',
      connectionString: connection_string,
      isolation,
      capabilityOverrides: capability_overrides,
      requestId: context.requestId,
    };

    const results = await this.runTransaction(proxyCtx, ops);
    this.emitTxnOutbox(engine, ops, results, userId, context);
    // Post-commit realtime fan-out: one best-effort `row_changed` per op in
    // the committed batch (TXN_OPS are all writes). Fire-and-forget — the
    // publisher never rejects.
    for (const o of ops) {
      const pk = o.data?.['id'] ?? o.filter?.['id'];
      void this.realtime.publishRowChanged(dbId, o.resource, o.op as RealtimeWriteOp, {
        filter: o.filter,
        idempotencyKey: o.idempotencyKey,
        pk,
      });
      this.fireAutomations({
        dbId,
        tenantId,
        userId,
        table: o.resource,
        op: o.op as RealtimeWriteOp,
        row: { ...o.filter, ...o.data },
        pk,
      }, context);
    }
    return { guarantee: 'atomic', mount: dbId, results };
  }

  /**
   * Server-backed automations: fire-and-forget evaluation of the stored
   * rules after a SUCCESSFUL write — for EVERY client, not only the session
   * that defined the rules. Loop safety: follow-up `set_property` writes
   * carry automationDepth=1 and writes at depth ≥ 1 never re-enter here.
   */
  private fireAutomations(event: AutomationWriteEvent, context: QueryRequestContext): void {
    if ((context.automationDepth ?? 0) > 0) return;
    void this.automations
      .runForWrite(
        event,
        (table, data, filter) => {
          const followUp = Object.assign(new ExecuteQueryDto(), { op: 'update', data, filter });
          return this.executeQuery(event.dbId, table, event.userId, followUp, {
            requestId: context.requestId,
            identity: context.identity,
            automationDepth: (context.automationDepth ?? 0) + 1,
          });
        },
        (rule, message, pk) =>
          this.realtime.publishAutomationFired(event.dbId, event.table, rule.id, rule.name, message, pk),
      )
      .catch((error: Error) => this.logger.warn(`automation run failed: ${error.message}`));
  }

  /** begin → execute each op → commit; rollback (best-effort) on any failure. */
  private async runTransaction(
    ctx: RustProxyContext,
    ops: TxnOpDto[],
  ): Promise<TxnOpResult[]> {
    const txId = await this.rustProxy.beginTransaction(ctx, ops[0].resource);
    try {
      const results: TxnOpResult[] = [];
      for (const o of ops) {
        const r = await this.rustProxy.executeInTransaction(ctx, txId, o.resource, o.op, {
          data: o.data,
          filter: o.filter,
          idempotencyKey: o.idempotencyKey,
        });
        results.push({ op: o.op, resource: o.resource, rowCount: r.rowCount });
      }
      await this.rustProxy.commitTransaction(ctx, txId);
      return results;
    } catch (error) {
      await this.rustProxy
        .rollbackTransaction(ctx, txId)
        .catch((e: Error) => this.logger.warn(`rollback of tx ${txId} failed: ${e.message}`));
      throw error;
    }
  }

  /** Emit a CDC/realtime event per committed op (best-effort, post-commit). */
  private emitTxnOutbox(
    engine: string,
    ops: TxnOpDto[],
    results: TxnOpResult[],
    userId: string,
    context: QueryRequestContext,
  ): void {
    ops.forEach((o, i) => {
      this.outbox
        .emitForQuery({
          engine,
          resource: o.resource,
          op: o.op,
          result: { rows: [], rowCount: results[i]?.rowCount ?? 0 },
          data: o.data,
          filter: o.filter,
          requestId: context.requestId,
          actorId: userId,
          tenantId: context.identity?.tenantId ?? userId,
          idempotencyKey: o.idempotencyKey,
        })
        .catch((error: Error) =>
          this.logger.warn(`txn outbox emit for ${engine}.${o.resource}.${o.op} failed: ${error.message}`),
        );
    });
  }

  private async decidePermission(
    userId: string,
    engine: string,
    resource: string,
    op: string,
    context: QueryRequestContext,
  ): Promise<PermissionDecision> {
    const identity = context.identity;
    const tenantId = identity?.tenantId ?? userId;

    // API-key callers carry verified key scopes, not ABAC user roles. By default
    // (API_KEY_ABAC_ENABLED off) the synthetic `api-key:<id>` actor has no role
    // rows (and isn't a UUID, so the user-centric ABAC engine would fail closed)
    // — authorize by scope instead; ABAC + field masks remain the model for
    // JWT/user auth. B5: when API_KEY_ABAC_ENABLED is ON, an api-key caller
    // instead FALLS THROUGH to the PDP using its key uuid as the subject (its
    // scope is projected to apikey:<scope> role membership in migration 063), so
    // it gets the SAME masks/conditions a JWT caller gets.
    const apiKeyUuid = this.apiKeyAbacEnabled ? this.apiKeyUuid(identity) : undefined;
    if (!apiKeyUuid) {
      const scoped = this.decideByApiKeyScope(identity, op);
      if (scoped) return scoped;
    }

    // Subject the PDP decides on: the api-key uuid (B5 path) or the user id.
    const subjectId = apiKeyUuid ?? userId;

    try {
      const { data } = await firstValueFrom(
        this.http.post<PermissionDecision>(
          `${this.permissionUrl}/permissions/decide`,
          {
            user: { id: subjectId },
            tenant_id: tenantId,
            project_id: identity?.projectId ?? tenantId,
            app_id: identity?.appId ?? 'legacy',
            resource_type: engine,
            resource_name: resource,
            op,
            resource_id: context.resourceId,
            attributes: {
              request_id: context.requestId,
              // ip feeds ip_cidr conditions; resource_id feeds per-instance
              // (resource_id / resource_id_in) conditions. Both are inert unless
              // PERMISSION_CONDITIONS_ENABLED is on at the PDP.
              ...(context.ip ? { ip: context.ip } : {}),
              ...(context.resourceId ? { resource_id: context.resourceId } : {}),
            },
          },
          {
            timeout: this.controlPlaneTimeoutMs,
            headers: {
              'X-Service-Token': this.serviceToken,
              'X-Tenant-Id': tenantId,
            },
          },
        ),
      );
      return data;
    } catch (error) {
      throw new ServiceUnavailableException(
        `ABAC decision service failed closed: ${error instanceof Error ? error.message : 'unknown error'}`,
      );
    }
  }

  /**
   * Extract the key uuid from an api-key identity (`api-key:<uuid>`) when B5 is
   * enabled — that uuid is the ABAC subject the PDP decides on (its scope is
   * projected to apikey:<scope> role membership in migration 063). Returns
   * undefined for non-api-key identities (they keep the JWT subject).
   */
  private apiKeyUuid(identity: VerifiedRequestIdentity | undefined): string | undefined {
    if (identity?.authMethod !== 'kong-hmac') return undefined;
    const uid = identity.userId;
    if (!uid?.startsWith('api-key:')) return undefined;
    const uuid = uid.slice('api-key:'.length);
    return uuid.length > 0 ? uuid : undefined;
  }

  /**
   * Scope-based authorization for api-key callers (authMethod `kong-hmac` with a
   * synthetic `api-key:<id>` actor). Returns a decision to short-circuit ABAC,
   * or `undefined` for JWT/user callers (who fall through to the ABAC engine).
   * `admin` ⇒ all ops; `read` ⇒ list/get; `write` ⇒ insert/update/delete/upsert/batch.
   */
  private decideByApiKeyScope(
    identity: VerifiedRequestIdentity | undefined,
    op: string,
  ): PermissionDecision | undefined {
    if (identity?.authMethod !== 'kong-hmac') return undefined;
    if (!identity.userId?.startsWith('api-key:')) return undefined;

    const scopes = new Set(identity.scopes ?? []);
    if (scopes.has('admin')) return { allow: true, reason: 'api-key admin scope' };

    const lop = op.toLowerCase();
    const READ = new Set(['list', 'get', 'select', 'read', 'count', 'aggregate']);
    const WRITE = new Set(['insert', 'update', 'delete', 'upsert', 'batch', 'create', 'patch', 'remove']);
    if (READ.has(lop) && scopes.has('read')) return { allow: true, reason: 'api-key read scope' };
    if (WRITE.has(lop) && scopes.has('write')) return { allow: true, reason: 'api-key write scope' };

    let needed = 'admin';
    if (READ.has(lop)) needed = 'read';
    else if (WRITE.has(lop)) needed = 'write';
    return { allow: false, reason: `api-key lacks '${needed}' scope for op '${op}'` };
  }

  /** Per-instance subject id from a query filter (`filter.id`), as a string —
   *  the value B3 conditions (resource_id / resource_id_in) decide on. */
  private resourceIdFromFilter(filter: Record<string, unknown> | undefined): string | undefined {
    const id = filter?.['id'];
    if (id === undefined || id === null) return undefined;
    if (typeof id === 'string') return id;
    if (typeof id === 'number' || typeof id === 'boolean' || typeof id === 'bigint') return String(id);
    return JSON.stringify(id);
  }

  private applyFieldMask(result: QueryResult, mask: FieldMask | undefined): QueryResult {
    if (!mask) return result;
    const hidden = new Set(mask.hide ?? []);
    const redact = mask.redact ?? {};
    return {
      rowCount: result.rowCount,
      rows: result.rows.map((row) => {
        const masked: Record<string, unknown> = { ...row };
        for (const field of hidden) delete masked[field];
        for (const [field, replacement] of Object.entries(redact)) {
          if (field in masked) masked[field] = replacement;
        }
        return masked;
      }),
    };
  }

  async listTables(dbId: string, userId: string, identity?: VerifiedRequestIdentity) {
    const { engine, connection_string } = await this.fetchConnection(dbId, identity?.tenantId ?? userId);
    const adapter = this.resolveAdapter(engine);
    const resources = await adapter.listResources(connection_string);

    // Per-engine response key kept for back-compat with existing clients that
    // looked for `.tables` (SQL) or `.collections` (Mongo). New engines only
    // expose `.resources` — clients should migrate to that key.
    const legacyKey = RESOURCE_KEY_BY_ENGINE[engine];
    if (legacyKey) {
      return { engine, [legacyKey]: resources, resources };
    }
    return { engine, resources };
  }
}

const RESOURCE_KEY_BY_ENGINE: Readonly<Record<string, string>> = Object.freeze({
  postgresql: 'tables',
  mongodb: 'collections',
  mysql: 'tables',
  jdbc: 'resources',
  cassandra: 'tables',
  neo4j: 'labels',
  elasticsearch: 'indices',
  qdrant: 'collections',
  influx: 'measurements',
});
