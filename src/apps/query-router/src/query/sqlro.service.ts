/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sqlro.service.ts                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/07/12 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/07/12 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Pool } from 'pg';
import { QueryService } from './query.service';

const STATEMENT_TIMEOUT_MS = 3000;
const ROW_CAP = 500;
const READ_PREFIXES = ['select', 'with', 'table', 'values', 'show', 'explain'];

/** Result of a read-only SQL run. */
export interface SqlRoResult {
  rows: Record<string, unknown>[];
  truncated: boolean;
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
      (this.config.get<string>('QUERY_ROUTER_SQL_RO', '0') ?? '0').toLowerCase(),
    );
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

  /** Run `sql` read-only against the mount's postgres DSN; caps rows at ROW_CAP. */
  async run(dbId: string, tenantId: string, sql: string): Promise<SqlRoResult> {
    if (!this.enabled) throw new NotFoundException();
    const statement = this.assertSingleRead(sql);
    const adapter = await this.query.resolveConnection(dbId, tenantId);
    if (adapter.engine !== 'postgresql') {
      throw new BadRequestException('The SQL runner supports postgres mounts only.');
    }
    return this.execute(adapter.connection_string, statement);
  }

  /** Open a short-lived single-connection pool and run in a READ ONLY txn. */
  private async execute(connectionString: string, statement: string): Promise<SqlRoResult> {
    // ponytail: per-request pool — cache by dbId if this becomes a hot path.
    const pool = new Pool({
      connectionString,
      max: 1,
      statement_timeout: STATEMENT_TIMEOUT_MS,
      idleTimeoutMillis: 1000,
    });
    const client = await pool.connect();
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
    } finally {
      client.release();
      await pool.end().catch(() => undefined);
    }
  }
}
