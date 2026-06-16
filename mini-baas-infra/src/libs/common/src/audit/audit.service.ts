/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   audit.service.ts                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 21:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:14 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Injectable,
  Logger,
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';
import { Pool } from 'pg';
import { Counter, register } from 'prom-client';

/** One row of the `public.audit_log` table written per mutating HTTP request. */
export interface AuditEntry {
  requestId: string;
  actorId?: string | null;
  actorRole?: string | null;
  action: string;
  resource: string;
  payload?: unknown;
  ip?: string | null;
  userAgent?: string | null;
}

function auditFailureCounter(): Counter<string> {
  const existing = register.getSingleMetric('mini_baas_audit_log_write_failed_total');
  if (existing instanceof Counter) return existing as Counter<string>;
  return new Counter({
    name: 'mini_baas_audit_log_write_failed_total',
    help: 'Failed audit_log writes by mini-BaaS services.',
  });
}

/**
 * Writer for the `audit_log` table introduced in migration 013.
 *
 * The writer is best-effort by design — if PostgreSQL is unreachable the
 * mutating request still succeeds, but a warning is logged. M3 will reinforce
 * this with the outbox pattern: same write, but inside the application's own
 * transaction so it cannot be lost on a crash between the business write and
 * the audit write.
 */
@Injectable()
export class AuditService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(AuditService.name);
  private readonly auditFailures = auditFailureCounter();
  private pool: Pool | null = null;

  onModuleInit(): void {
    const connectionString = process.env['AUDIT_DATABASE_URL'] ?? process.env['DATABASE_URL'];
    if (!connectionString) {
      this.logger.warn(
        'AUDIT_DATABASE_URL / DATABASE_URL not set — audit_log writes will be skipped.',
      );
      return;
    }
    this.pool = new Pool({
      connectionString,
      max: 2,
      idleTimeoutMillis: 30_000,
      // Keep audit writes from blocking other queries; tight timeouts.
      connectionTimeoutMillis: 5_000,
      statement_timeout: 3_000,
    });
    this.pool.on('error', (err) => {
      this.logger.warn(`audit_log pool error: ${err.message}`);
    });
  }

  async onModuleDestroy(): Promise<void> {
    await this.pool?.end().catch(() => {});
  }

  /**
   * Persist one audit row. Errors are logged but never propagated — auditing
   * must not break the main HTTP response on a transient PG failure.
   */
  async record(entry: AuditEntry): Promise<void> {
    if (!this.pool) return;
    try {
      const payload = this.normalizePayload(entry.payload);
      await this.pool.query(
        `INSERT INTO public.audit_log
           (request_id, actor_id, actor_role, action, resource, payload, ip, user_agent)
         VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8)`,
        [
          entry.requestId,
          entry.actorId ?? null,
          entry.actorRole ?? null,
          entry.action,
          entry.resource,
          payload === undefined ? null : JSON.stringify(payload),
          entry.ip ?? null,
          entry.userAgent ?? null,
        ],
      );
    } catch (err) {
      this.auditFailures.inc();
      const message = err instanceof Error ? err.message : String(err);
      this.logger.warn(
        `audit_log insert failed (req=${entry.requestId} action=${entry.action} resource=${entry.resource}): ${message}`,
      );
    }
  }

  /**
   * Drop top-level secrets from the payload before persisting. Conservative
   * default — applications can pass an already-sanitized payload, this is the
   * last line of defence.
   */
  private normalizePayload(payload: unknown): unknown {
    if (payload == null) return undefined;
    if (typeof payload !== 'object') return payload;
    const cloned: Record<string, unknown> = { ...(payload as Record<string, unknown>) };
    for (const key of Object.keys(cloned)) {
      const lower = key.toLowerCase();
      if (
        lower.includes('password') ||
        lower.includes('secret') ||
        lower.includes('token') ||
        lower.includes('apikey') ||
        lower.includes('api_key')
      ) {
        cloned[key] = '[REDACTED]';
      }
    }
    return cloned;
  }
}
