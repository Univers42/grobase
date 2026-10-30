/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   audit-writer.ts                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 12:15:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 12:15:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Batched audit_log writer (grobase#81, devil verdict A1–A12). One INSERT per
// row on a 2-connection pool queued every row of a burst behind the pool, and
// a row waiting past the 5 s connect timeout was lost (bench: 810 of 1000 at
// 50 ms per insert). One flusher now writes up to `batchRows` rows per
// statement out of a buffer bounded by rows AND bytes: six services run with a
// 96 MB heap, so a row cap alone could crash them.
//
// Caveat: rows live in memory until written, so a crash loses what is
// buffered (the old fire-and-forget lost only in-flight rows). Byte accounting
// is 2 × string length, an upper bound for UTF-16, not the real heap cost.
// A connect-phase error is retried; a statement whose result never came back
// is not, so that rare case loses its batch rather than risk duplicates.

/** request_id, actor_id, actor_role, action, resource, payload, ip, user_agent. */
export type AuditRow = readonly (string | null)[];

export interface AuditDb {
  query(text: string, params: unknown[]): Promise<unknown>;
}

export type FailureReason = 'connect' | 'ambiguous' | 'data' | 'timeout' | 'other';

export interface AuditWriterOptions {
  maxRows: number;
  maxBytes: number;
  batchRows: number;
  backoffMs: readonly number[];
  failed(reason: FailureReason, rows: number): void;
  dropped(rows: number): void;
  warn(message: string): void;
  sleep?(ms: number): Promise<void>;
}

const COLUMNS = '(request_id, actor_id, actor_role, action, resource, payload, ip, user_agent)';
const RETRY_CODES = new Set([
  'ECONNREFUSED',
  'ENOTFOUND',
  'EAI_AGAIN',
  '57P01',
  '57P03',
  '53300',
  '40001',
  '40P01',
]);
const POOL_CONNECT_TIMEOUT = 'timeout exceeded when trying to connect';

/** Retry only what provably never reached the table (verdict A2). */
export function classifyFailure(err: unknown): FailureReason {
  const code = (err as { code?: unknown } | null)?.code;
  const message = err instanceof Error ? err.message : String(err);
  if (typeof code === 'string' && RETRY_CODES.has(code)) return 'connect';
  if (message.includes(POOL_CONNECT_TIMEOUT)) return 'connect';
  if (code === '57014') return 'timeout';
  if (typeof code === 'string' && /^2[23]/.test(code)) return 'data';
  if (typeof code === 'string' && /^[0-9A-Z]{5}$/.test(code)) return 'other';
  return 'ambiguous';
}

export function buildInsert(rows: readonly AuditRow[]): { text: string; params: unknown[] } {
  const params: unknown[] = [];
  const values = rows.map((row) => {
    const at = params.push(...row) - row.length;
    const slot = (i: number) => `$${at + i + 1}${i === 5 ? '::jsonb' : ''}`;
    return `(${row.map((_, i) => slot(i)).join(', ')})`;
  });
  return { text: `INSERT INTO public.audit_log ${COLUMNS} VALUES ${values.join(', ')}`, params };
}

function rowBytes(row: AuditRow): number {
  return 2 * row.reduce((sum, field) => sum + (field?.length ?? 0), 0);
}

function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms).unref());
}

export class AuditBatchWriter {
  private readonly buffer: AuditRow[] = [];
  private bytes = 0;
  private flushing: Promise<void> | null = null;
  private closed = false;
  private aborted = false;

  constructor(
    private readonly db: AuditDb,
    private readonly opts: AuditWriterOptions,
  ) {}

  get bufferedBytes(): number {
    return this.bytes;
  }

  /** False when the row was dropped (closed, or a cap would be exceeded). */
  enqueue(row: AuditRow): boolean {
    const size = rowBytes(row);
    const full = this.buffer.length >= this.opts.maxRows || this.bytes + size > this.opts.maxBytes;
    if (this.closed || full) {
      this.opts.dropped(1);
      return false;
    }
    this.buffer.push(row);
    this.bytes += size;
    this.kick();
    return true;
  }

  /** Stop accepting rows, drain for at most `deadlineMs`, count the rest dropped. */
  async close(deadlineMs: number): Promise<void> {
    this.closed = true;
    this.kick();
    let expired = false;
    let timer: NodeJS.Timeout | undefined;
    const deadline = new Promise<void>((resolve) => {
      timer = setTimeout(() => {
        expired = true;
        resolve();
      }, deadlineMs);
    });
    while (this.flushing && !expired) await Promise.race([this.flushing, deadline]);
    clearTimeout(timer);
    this.aborted = true;
    if (this.buffer.length > 0) this.opts.dropped(this.buffer.length);
    this.buffer.length = 0;
    this.bytes = 0;
  }

  // One flusher at a time; a row enqueued while the last one was finishing
  // starts the next, so nothing is left buffered without a writer.
  private kick(): void {
    if (this.flushing || this.aborted) return;
    this.flushing = this.flush().finally(() => {
      this.flushing = null;
      if (this.buffer.length > 0) this.kick();
    });
  }

  private async flush(): Promise<void> {
    while (this.buffer.length > 0 && !this.aborted) {
      const batch = this.buffer.splice(0, this.opts.batchRows);
      this.bytes -= batch.reduce((sum, row) => sum + rowBytes(row), 0);
      try {
        await this.writeBatch(batch);
      } catch (err) {
        this.giveUp(batch, 'other', err);
      }
    }
  }

  private async writeBatch(batch: readonly AuditRow[]): Promise<void> {
    for (let attempt = 0; ; attempt++) {
      const err = await this.tryInsert(batch);
      if (err === null) return;
      const reason = classifyFailure(err);
      if (reason === 'data' || reason === 'timeout') return this.writeRowByRow(batch);
      const wait = this.opts.backoffMs[attempt];
      if (reason !== 'connect' || wait === undefined || this.aborted) {
        return this.giveUp(batch, reason, err);
      }
      await (this.opts.sleep ?? defaultSleep)(wait);
    }
  }

  /** One attempt per row, so one bad row costs one row (verdict A3, A9). */
  private async writeRowByRow(batch: readonly AuditRow[]): Promise<void> {
    for (const [i, row] of batch.entries()) {
      if (this.aborted) return this.giveUp(batch.slice(i), 'other', new Error('shutdown'));
      const err = await this.tryInsert([row]);
      if (err !== null) this.giveUp([row], classifyFailure(err), err);
    }
  }

  // A synchronous throw from the driver is caught like a rejection (A6).
  private async tryInsert(rows: readonly AuditRow[]): Promise<unknown> {
    try {
      const { text, params } = buildInsert(rows);
      await this.db.query(text, params);
      return null;
    } catch (err) {
      return err ?? new Error('audit insert failed');
    }
  }

  private giveUp(rows: readonly AuditRow[], reason: FailureReason, err: unknown): void {
    this.opts.failed(reason, rows.length);
    const ids = rows.slice(0, 5).map((row) => row[0]);
    const message = err instanceof Error ? err.message : String(err);
    this.opts.warn(
      `audit_log write failed: ${rows.length} row(s), reason=${reason}, req=${ids.join(',')}: ${message}`,
    );
  }
}
