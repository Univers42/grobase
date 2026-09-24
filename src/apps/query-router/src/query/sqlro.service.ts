/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sqlro.service.ts                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/07/12 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/23 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Pool, PoolClient } from 'pg';
import { AdapterResponse, QueryService } from './query.service';

const STATEMENT_TIMEOUT_MS = 3000;
const ROW_CAP = 500;
const READ_PREFIXES = ['select', 'with', 'table', 'values', 'show', 'explain'];
const UNSCOPED_ISOLATION = 'tenant_owned';

/** Result of a read-only SQL run. */
export interface SqlRoResult {
  rows: Record<string, unknown>[];
  truncated: boolean;
}

/**
 * Whether raw SQL may read `mount` without bypassing the platform's per-request
 * scoping. Only `tenant_owned` qualifies — the one isolation the data plane does
 * not owner-scope per row (data-plane-core `Isolation::owner_scoped`); every other
 * one is RLS-GUC / owner_id / search_path scoped per request, which a raw DSN
 * connection cannot reproduce. A mount that opted into `read_scoped` (migration
 * 070, `capability_overrides.read_scoped`) is refused too, whatever its isolation.
 * So is a mount with no inline DSN (a Vault cred-ref mount returns ""): node-pg
 * would otherwise fall back to its default host, localhost:5432.
 */
function servesRawSql(mount: AdapterResponse): boolean {
  const readScoped = mount.capability_overrides?.read_scoped;
  const unscoped = mount.isolation?.trim() === UNSCOPED_ISOLATION;
  const hasDsn = (mount.connection_string ?? '').trim() !== '';
  return unscoped && hasDsn && (readScoped === undefined || readScoped === false);
}

/** Collapse a mount-lookup 404 into the bare 404 so it never names the dbId. */
function hideNotFound(error: unknown): never {
  throw error instanceof NotFoundException ? new NotFoundException() : error;
}

/**
 * Read-only raw SQL against a postgres mount (`POST /:dbId/sql-ro`). Flag-gated
 * OFF by default (`QUERY_ROUTER_SQL_RO`) so a missing var 404s = byte-parity.
 * Safety is Postgres's own READ ONLY transaction (writes raise SQLSTATE 25006);
 * the single-statement + read-prefix checks reject obvious non-reads early.
 */
@Injectable()
export class SqlRoService {
  private readonly enabled: boolean;

  constructor(
    private readonly config: ConfigService,
    private readonly query: QueryService,
  ) {
    this.enabled = ['1', 'true', 'yes', 'on'].includes(
      (this.config.get<string>('QUERY_ROUTER_SQL_RO', '0') ?? '0').trim().toLowerCase(),
    );
  }

  /**
   * Run `sql` read-only against a mount `tenantId` owns; caps rows at ROW_CAP.
   * `tenantId` must be the verified identity's tenant. Flag OFF → bare 404.
   */
  async run(dbId: string, tenantId: string, sql: string): Promise<SqlRoResult> {
    if (!this.enabled) throw new NotFoundException();
    const statement = this.assertSingleRead(sql);
    const mount = await this.resolveOwnedMount(dbId, tenantId);
    if (mount.engine !== 'postgresql') {
      throw new BadRequestException('The SQL runner supports postgres mounts only.');
    }
    return this.execute(mount.connection_string, statement);
  }

  /** Reject anything that is not a single read statement (defence in depth). */
  private assertSingleRead(sql: string): string {
    const trimmed = sql.trim().replace(/;\s*$/, '');
    if (trimmed.includes(';')) throw new BadRequestException('Only a single statement is allowed.');
    const first = trimmed.toLowerCase().split(/\s+/, 1)[0] ?? '';
    if (!READ_PREFIXES.includes(first))
      throw new BadRequestException('Only read-only queries are allowed.');
    return trimmed;
  }

  /**
   * Resolve `dbId` as a mount registered to `tenantId` that raw SQL may read.
   * The raw DSN runs OUTSIDE the Rust data-plane pool, so nothing it relies on
   * for scoping applies here. Hence static `DATA_PLANE_MOUNTS` are refused: they
   * match by dbId alone and have no owner to check. Registered mounts are tenant-
   * scoped by adapter-registry `/connect` (`tenant_id = X-Tenant-Id`); owner-scoped
   * ones are refused by {@link servesRawSql}. Every refusal — static, foreign,
   * unknown, owner-scoped — is the same bare 404 as the flag-OFF endpoint, so the
   * response never reveals whether the mount exists.
   */
  private async resolveOwnedMount(dbId: string, tenantId: string): Promise<AdapterResponse> {
    if (this.query.isStaticMount(dbId)) throw new NotFoundException();
    const mount = await this.query.resolveConnection(dbId, tenantId).catch(hideNotFound);
    if (!servesRawSql(mount)) throw new NotFoundException();
    return mount;
  }

  /**
   * Open a short-lived single-connection pool and run `statement` read-only.
   * The pool is ended on every path — including a failed `connect()` — and a
   * connect error propagates unmapped (no DSN detail reaches the caller).
   */
  private async execute(connectionString: string, statement: string): Promise<SqlRoResult> {
    // ponytail: per-request pool — cache by dbId if this becomes a hot path.
    const pool = new Pool({
      connectionString,
      max: 1,
      statement_timeout: STATEMENT_TIMEOUT_MS,
      idleTimeoutMillis: 1000,
    });
    try {
      const client = await pool.connect();
      try {
        return await this.runReadOnly(client, statement);
      } finally {
        client.release();
      }
    } finally {
      await pool.end().catch(() => undefined);
    }
  }

  /** Run `statement` in a READ ONLY txn; a failure rolls back and maps to 400. */
  private async runReadOnly(client: PoolClient, statement: string): Promise<SqlRoResult> {
    try {
      await client.query('BEGIN');
      await client.query('SET TRANSACTION READ ONLY');
      await client.query(`SET LOCAL statement_timeout = ${STATEMENT_TIMEOUT_MS}`);
      const result = await client.query(statement);
      await client.query('COMMIT');
      const rows = (result.rows ?? []).slice(0, ROW_CAP);
      return { rows, truncated: (result.rows?.length ?? 0) > ROW_CAP };
    } catch (error) {
      await client.query('ROLLBACK').catch(() => undefined);
      throw new BadRequestException(error instanceof Error ? error.message : 'Query failed.');
    }
  }
}
