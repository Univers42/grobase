/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema.service.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/09 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/09 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  BadRequestException,
  Injectable,
  Logger,
  NotFoundException,
  Optional,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import type { VerifiedRequestIdentity } from '@mini-baas/common';
import { QueryService } from './query.service';
import { RealtimePublisherService } from './realtime-publisher.service';
import {
  RustDataPlaneProxy,
  RustDdlColumnDef,
  RustEngineCapabilities,
  RustProxyContext,
  RustSchemaDdlRequest,
  RustSchemaDdlResult,
  RustTableSchema,
} from '../proxy/rust-data-plane.proxy';
import { SchemaDdlColumnDto, SchemaDdlRequestDto } from './dto/schema-ddl.dto';

/** Response of `GET /query/v1/:dbId/schema` — the Rust `SchemaDescriptor`
 *  enriched with the mount id and the engine's live capability descriptor so
 *  a client learns in ONE call both what the data looks like and what it may
 *  do with it (read/write/ddl/transactions/introspect…). */
export interface SchemaResponse {
  dbId: string;
  engine: string;
  capabilities: RustEngineCapabilities | null;
  tables: RustTableSchema[];
}

/** Response of `POST /query/v1/:dbId/schema/ddl` — the Rust `SchemaDdlResult`
 *  enriched with the mount id. */
export interface SchemaDdlResponse extends RustSchemaDdlResult {
  dbId: string;
}

/** Ops that destroy data and therefore require an explicit `confirm: true`. */
const DESTRUCTIVE_DDL_OPS = new Set(['drop_column', 'drop_table']);

interface SchemaCacheEntry {
  value: SchemaResponse;
  expiresAt: number;
}

/**
 * Engine-agnostic schema introspection (M22, live-database mode).
 *
 * Resolves the mount through {@link QueryService.resolveConnection} (the same
 * static-mount/registry path the query hot path uses), forwards to the Rust
 * data plane's `POST /v1/schema` via {@link RustDataPlaneProxy.describeSchema},
 * and merges in the engine's live capabilities from the shared
 * `/v1/capabilities` TTL cache.
 *
 * Results are TTL-cached in-memory keyed by `${tenantId}:${dbId}` (schema
 * changes are rare; 60s staleness is acceptable and keeps the catalog queries
 * off the hot path), capped at a fixed number of entries with simple
 * oldest-entry eviction (Map iteration is insertion order).
 */
@Injectable()
export class SchemaService {
  private readonly logger = new Logger(SchemaService.name);
  private readonly cache = new Map<string, SchemaCacheEntry>();
  private readonly cacheTtlMs: number;
  private readonly cacheMaxEntries: number;

  constructor(
    config: ConfigService,
    private readonly query: QueryService,
    private readonly rustProxy: RustDataPlaneProxy,
    // Optional so existing call sites/tests that build the service without a
    // publisher keep working; Nest injects it when the provider is registered.
    @Optional() private readonly realtime?: RealtimePublisherService,
  ) {
    this.cacheTtlMs = Number(config.get<string>('QUERY_ROUTER_SCHEMA_CACHE_TTL_MS', '60000'));
    this.cacheMaxEntries = Number(
      config.get<string>('QUERY_ROUTER_SCHEMA_CACHE_MAX_ENTRIES', '256'),
    );
  }

  /** Describe `dbId`'s schema for the calling identity (tenant-scoped). */
  async describe(
    dbId: string,
    userId: string,
    identity?: VerifiedRequestIdentity,
  ): Promise<SchemaResponse> {
    const tenantId = identity?.tenantId ?? userId;
    const cacheKey = `${tenantId}:${dbId}`;
    const cached = this.readCache(cacheKey);
    if (cached) return cached;

    const { engine, connection_string, isolation } = await this.query.resolveConnection(
      dbId,
      tenantId,
    );
    const ctx: RustProxyContext = {
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
    };
    const descriptor = await this.rustProxy.describeSchema(ctx);
    const capabilities = await this.capabilitiesFor(engine);
    const value: SchemaResponse = {
      dbId,
      engine: descriptor.engine,
      capabilities,
      tables: descriptor.tables,
    };
    this.writeCache(cacheKey, value);
    return value;
  }

  /**
   * Apply ONE schema-DDL operation to `dbId` (M22 step 2). Flow:
   *   1. destructive ops (drop_column / drop_table) require an explicit
   *      `confirm: true` — refused with a 400 otherwise;
   *   2. `alter_column_type` composes the FULL target column definition by
   *      merging the request with the CURRENT column (via the cached
   *      describe path) — engines like MySQL (`MODIFY COLUMN`) reset omitted
   *      attributes, so the data plane always receives a complete def. An
   *      unknown table/column is a 404;
   *   3. forward to the Rust data plane (`POST /v1/schema/ddl`);
   *   4. on success, BUST this tenant+db's schema cache entry so the next
   *      describe sees the new shape immediately (not after the TTL).
   */
  async applyDdl(
    dbId: string,
    userId: string,
    dto: SchemaDdlRequestDto,
    identity?: VerifiedRequestIdentity,
  ): Promise<SchemaDdlResponse> {
    if (DESTRUCTIVE_DDL_OPS.has(dto.op) && dto.confirm !== true) {
      throw new BadRequestException(
        `ddl op '${dto.op}' is destructive — set "confirm": true to proceed`,
      );
    }
    const tenantId = identity?.tenantId ?? userId;

    let column: RustDdlColumnDef | null = dto.column ? this.fullColumn(dto.column) : null;
    if (dto.op === 'alter_column_type') {
      column = await this.composeAlterTarget(dbId, userId, dto, identity);
    }

    const { engine, connection_string, isolation } = await this.query.resolveConnection(
      dbId,
      tenantId,
    );
    const ctx: RustProxyContext = {
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
    };
    const ddl: RustSchemaDdlRequest = {
      op: dto.op,
      table: dto.table,
      column,
      column_name: dto.column_name ?? null,
      columns: dto.columns ? dto.columns.map((c) => this.fullColumn(c)) : null,
      primary_key: dto.primary_key ?? null,
    };
    const result = await this.rustProxy.applySchemaDdl(ctx, ddl);
    // The schema changed — the cached descriptor for this tenant+db is stale.
    this.cache.delete(`${tenantId}:${dbId}`);
    // Best-effort realtime fan-out on the SAME table channel as row_changed —
    // subscribed clients refetch the schema. Fire-and-forget (never rejects).
    if (this.realtime) {
      void this.realtime.publishSchemaChanged(dbId, dto.table, dto.op);
    }
    return { ...result, dbId };
  }

  /** Defaults an (optional-attribute) DTO column into the FULL wire def. */
  private fullColumn(c: SchemaDdlColumnDto): RustDdlColumnDef {
    return {
      name: c.name,
      normalized_type: c.normalized_type,
      nullable: c.nullable ?? true,
      default: c.default ?? null,
      enum_values: c.enum_values ?? null,
    };
  }

  /**
   * For `alter_column_type`: fetch the current schema (cached describe path),
   * 404 on an unknown table/column, then compose the FULL target definition —
   * the requested type always wins; nullability/default/enum values are
   * preserved from the current column unless the request overrides them.
   */
  private async composeAlterTarget(
    dbId: string,
    userId: string,
    dto: SchemaDdlRequestDto,
    identity?: VerifiedRequestIdentity,
  ): Promise<RustDdlColumnDef> {
    const requested = dto.column;
    if (!requested) {
      throw new BadRequestException("ddl op 'alter_column_type' requires `column`");
    }
    const schema = await this.describe(dbId, userId, identity);
    const table = schema.tables.find((t) => t.name === dto.table);
    if (!table) {
      throw new NotFoundException(`table '${dto.table}' does not exist on database ${dbId}`);
    }
    const current = table.columns.find((c) => c.name === requested.name);
    if (!current) {
      throw new NotFoundException(
        `column '${requested.name}' does not exist on table '${dto.table}'`,
      );
    }
    return {
      name: requested.name,
      normalized_type: requested.normalized_type,
      nullable: requested.nullable ?? current.nullable,
      // `undefined` = "keep the current default"; an explicit `null` clears it.
      default: requested.default !== undefined ? requested.default : current.default,
      enum_values:
        requested.enum_values !== undefined ? requested.enum_values : current.enum_values,
    };
  }

  /** Engine capabilities from the live `/v1/capabilities` shared TTL cache —
   *  the same source `/capabilities` and `/engines` expose. Best-effort: a
   *  capabilities outage must not fail the schema read itself. */
  private async capabilitiesFor(engine: string): Promise<RustEngineCapabilities | null> {
    try {
      const caps = await this.rustProxy.getCapabilitiesCached();
      return caps.engines.find((e) => e.engine === engine)?.capabilities ?? null;
    } catch (error) {
      this.logger.warn(
        `capabilities lookup for '${engine}' failed (schema still served): ${
          error instanceof Error ? error.message : 'unknown error'
        }`,
      );
      return null;
    }
  }

  private readCache(cacheKey: string): SchemaResponse | undefined {
    if (this.cacheTtlMs <= 0) return undefined;
    const entry = this.cache.get(cacheKey);
    if (!entry) return undefined;
    if (entry.expiresAt <= Date.now()) {
      this.cache.delete(cacheKey);
      return undefined;
    }
    return entry.value;
  }

  private writeCache(cacheKey: string, value: SchemaResponse): void {
    if (this.cacheTtlMs <= 0) return;
    this.evictIfFull();
    this.cache.set(cacheKey, { value, expiresAt: Date.now() + this.cacheTtlMs });
  }

  /** Same policy as QueryService's DSN cache: lazy-reap expired entries, then
   *  drop the oldest (Map iteration is insertion order) if still over cap. */
  private evictIfFull(): void {
    if (this.cache.size < this.cacheMaxEntries) return;
    const now = Date.now();
    for (const [key, entry] of this.cache) {
      if (entry.expiresAt <= now) this.cache.delete(key);
    }
    if (this.cache.size >= this.cacheMaxEntries) {
      const oldest = this.cache.keys().next().value;
      if (oldest) this.cache.delete(oldest);
    }
  }
}
