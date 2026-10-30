/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   audit.service.ts                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 21:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 12:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { Pool } from 'pg';
import { Counter, register } from 'prom-client';
import { AuditBatchWriter, AuditRow, FailureReason } from './audit-writer';
import { requestIdUuid } from './request-id';

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

const SECRET_KEY_PARTS = ['password', 'secret', 'token', 'apikey', 'api_key'];
const REDACT_MAX_DEPTH = 4;
const REDACT_MAX_ENTRIES = 256;
const TRUNCATED = '[TRUNCATED]';

function isSecretKey(key: string): boolean {
  const lower = key.toLowerCase();
  return SECRET_KEY_PARTS.some((part) => lower.includes(part));
}

/**
 * Copy of `value` with every secret-named key replaced by `[REDACTED]`.
 *
 * Caveat: matches key NAMES only — a secret under an innocuous key (`pw`,
 * `auth`, a value inside a string) is stored as-is. Anything deeper than
 * REDACT_MAX_DEPTH, and entries past REDACT_MAX_ENTRIES, become
 * `[TRUNCATED]` rather than being stored unscanned.
 */
function redactSecrets(value: unknown, depth: number): unknown {
  if (value === null || typeof value !== 'object') return value;
  if (depth >= REDACT_MAX_DEPTH) return TRUNCATED;
  if (Array.isArray(value)) {
    const items = value.slice(0, REDACT_MAX_ENTRIES).map((item) => redactSecrets(item, depth + 1));
    return value.length > REDACT_MAX_ENTRIES ? [...items, TRUNCATED] : items;
  }
  const out: Record<string, unknown> = {};
  const entries = Object.entries(value as Record<string, unknown>);
  for (const [key, item] of entries.slice(0, REDACT_MAX_ENTRIES)) {
    out[key] = isSecretKey(key) ? '[REDACTED]' : redactSecrets(item, depth + 1);
  }
  if (entries.length > REDACT_MAX_ENTRIES) out[TRUNCATED] = entries.length - REDACT_MAX_ENTRIES;
  return out;
}

function counter(name: string, help: string, labelNames: string[]): Counter<string> {
  const existing = register.getSingleMetric(name);
  if (existing instanceof Counter) return existing;
  return new Counter({ name, help, labelNames });
}

function positiveInt(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  return Number.isInteger(value) && value > 0 ? value : fallback;
}

// Verdict A1: under 10% of the 96 MB heap six services run with.
const DEFAULT_MAX_BYTES = 8 * 1024 * 1024;
const SHUTDOWN_DRAIN_MS = 5_000;
const DROP_WARN_EVERY_MS = 10_000;

/**
 * Writer for the `audit_log` table introduced in migration 013.
 *
 * The writer is best-effort by design — if PostgreSQL is unreachable the
 * mutating request still succeeds, but a warning is logged. Rows go through
 * AuditBatchWriter (grobase#81): batched, bounded, retried only when the
 * database provably never saw them. M3 will reinforce
 * this with the outbox pattern: same write, but inside the application's own
 * transaction so it cannot be lost on a crash between the business write and
 * the audit write.
 */
@Injectable()
export class AuditService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(AuditService.name);
  private readonly auditFailures = counter(
    'mini_baas_audit_log_write_failed_total',
    'Failed audit_log writes by mini-BaaS services.',
    ['reason'],
  );
  private readonly auditDropped = counter(
    'mini_baas_audit_log_dropped_total',
    'audit_log rows dropped before a write: buffer full or shutting down.',
    [],
  );
  private pool: Pool | null = null;
  private droppedSinceWarn = 0;
  private lastDropWarn = 0;
  private readonly writer = new AuditBatchWriter(
    { query: (text, params) => this.requirePool().query(text, params) },
    {
      maxRows: positiveInt('AUDIT_BUFFER_MAX', 10_000),
      maxBytes: positiveInt('AUDIT_BUFFER_MAX_BYTES', DEFAULT_MAX_BYTES),
      batchRows: 100,
      backoffMs: [500, 1_000, 2_000],
      failed: (reason: FailureReason, rows: number) => this.auditFailures.inc({ reason }, rows),
      dropped: (rows: number) => this.noteDropped(rows),
      warn: (message: string) => this.logger.warn(message),
    },
  );

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
    if (!this.pool) return;
    await this.writer.close(SHUTDOWN_DRAIN_MS);
    await this.pool.end().catch(() => {});
  }

  /**
   * Buffer one audit row for the batch writer; it never waits on PostgreSQL
   * and never throws. Redaction and serialization happen here, so the buffer
   * holds strings, never a reference to the request body (verdict A5).
   */
  async record(entry: AuditEntry): Promise<void> {
    if (!this.pool) return;
    try {
      this.writer.enqueue(this.toRow(entry));
    } catch (err) {
      this.auditFailures.inc({ reason: 'other' });
      const message = err instanceof Error ? err.message : String(err);
      this.logger.warn(
        `audit_log row rejected (raw=${entry.requestId.slice(0, 128)} action=${entry.action} resource=${entry.resource}): ${message}`,
      );
    }
  }

  private toRow(entry: AuditEntry): AuditRow {
    const payload = this.normalizePayload(entry.payload);
    return [
      requestIdUuid(entry.requestId),
      entry.actorId ?? null,
      entry.actorRole ?? null,
      entry.action,
      entry.resource,
      payload === undefined ? null : JSON.stringify(payload),
      entry.ip ?? null,
      entry.userAgent ?? null,
    ];
  }

  private requirePool(): Pool {
    if (!this.pool) throw new Error('audit_log pool is closed');
    return this.pool;
  }

  /** One warn per DROP_WARN_EVERY_MS, carrying the count since the last one. */
  private noteDropped(rows: number): void {
    this.auditDropped.inc(rows);
    this.droppedSinceWarn += rows;
    const now = Date.now();
    if (now - this.lastDropWarn < DROP_WARN_EVERY_MS) return;
    this.logger.warn(`audit_log buffer dropped ${this.droppedSinceWarn} row(s)`);
    this.droppedSinceWarn = 0;
    this.lastDropWarn = now;
  }

  /**
   * Drop secret-named keys at every level before persisting: query-router
   * bodies nest under `data` / `filter`, and `audit_log_self_read` lets the
   * actor read the stored payload back. Last line of defence — callers may
   * pass an already-sanitized payload.
   */
  private normalizePayload(payload: unknown): unknown {
    if (payload == null) return undefined;
    return redactSecrets(payload, 0);
  }
}
