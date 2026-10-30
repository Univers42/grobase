import { describe, expect, it } from '@jest/globals';
import {
  AuditBatchWriter,
  AuditDb,
  AuditRow,
  AuditWriterOptions,
  FailureReason,
  buildInsert,
  classifyFailure,
} from './audit-writer';

// grobase#81, devil verdict A1–A9: each test names the condition it proves.
type Insert = (rows: AuditRow[]) => Promise<void>;

function pgError(code: string | undefined, message = 'pg error'): Error {
  return Object.assign(new Error(message), { code });
}

function rowsOf(params: unknown[]): AuditRow[] {
  const rows: AuditRow[] = [];
  for (let i = 0; i < params.length; i += 8) rows.push(params.slice(i, i + 8) as AuditRow);
  return rows;
}

function harness(insert: Insert, overrides: Partial<AuditWriterOptions> = {}) {
  const stored: AuditRow[] = [];
  const failed: Partial<Record<FailureReason, number>> = {};
  const counts = { dropped: 0, queries: 0, warns: [] as string[] };
  const db: AuditDb = {
    // Not async: an Insert that throws synchronously throws out of query (A6).
    query: (_text, params) => {
      counts.queries++;
      return insert(rowsOf(params)).then(() => {
        stored.push(...rowsOf(params));
      });
    },
  };
  const writer = new AuditBatchWriter(db, {
    maxRows: 10_000,
    maxBytes: 8 * 1024 * 1024,
    batchRows: 100,
    backoffMs: [500, 1_000, 2_000],
    failed: (reason, rows) => (failed[reason] = (failed[reason] ?? 0) + rows),
    dropped: (rows) => (counts.dropped += rows),
    warn: (message) => counts.warns.push(message),
    sleep: async () => {},
    ...overrides,
  });
  return { writer, stored, failed, counts };
}

const row = (id: number, payload = '{"a":1}'): AuditRow => [
  `id-${id}`,
  null,
  'service_role',
  'POST',
  '/x',
  payload,
  null,
  'ua',
];
const tick = () => new Promise((resolve) => setImmediate(resolve));

describe('AuditBatchWriter', () => {
  it('writes a burst of 1000 through a slow database without losing a row', async () => {
    const slow: Insert = () => new Promise((resolve) => setTimeout(resolve, 5));
    const { writer, stored, failed, counts } = harness(slow);
    for (let i = 0; i < 1000; i++) writer.enqueue(row(i));
    await writer.close(5_000);
    expect(stored).toHaveLength(1000);
    expect(stored.map((r) => r[0])).toEqual(Array.from({ length: 1000 }, (_, i) => `id-${i}`));
    // The first row flushes alone; the rest queue behind it in batches of 100.
    expect(counts.queries).toBe(11);
    expect(failed).toEqual({});
  });

  it('A1: bounds the buffer by bytes as well as rows', async () => {
    const never: Insert = () => new Promise(() => {});
    const maxBytes = 8 * 1024 * 1024;
    const { writer, counts } = harness(never, { maxBytes, maxRows: 10_000 });
    const big = JSON.stringify({ blob: 'x'.repeat(8 * 1024) });
    let accepted = 0;
    for (let i = 0; i < 20_000; i++) if (writer.enqueue(row(i, big))) accepted++;
    expect(writer.bufferedBytes).toBeLessThanOrEqual(maxBytes);
    expect(counts.dropped).toBe(20_000 - accepted);
    expect(accepted).toBeLessThan(600);
  });

  it('A2: an answer lost mid-statement is not retried, a connect timeout is', async () => {
    let calls = 0;
    const ambiguous: Insert = async () => {
      calls++;
      throw new Error('Connection terminated unexpectedly');
    };
    const a = harness(ambiguous);
    a.writer.enqueue(row(1));
    await a.writer.close(1_000);
    expect(calls).toBe(1);
    expect(a.failed).toEqual({ ambiguous: 1 });

    calls = 0;
    const connect: Insert = async () => {
      calls++;
      throw new Error('timeout exceeded when trying to connect');
    };
    const c = harness(connect);
    c.writer.enqueue(row(1));
    await c.writer.close(1_000);
    expect(calls).toBe(4);
    expect(c.failed).toEqual({ connect: 1 });
  });

  it('A2: a transient connect failure that recovers stores the batch once', async () => {
    let calls = 0;
    const flaky: Insert = async () => {
      if (++calls < 3) throw pgError('57P03', 'the database system is starting up');
    };
    const { writer, stored, failed } = harness(flaky);
    for (let i = 0; i < 50; i++) writer.enqueue(row(i));
    await writer.close(1_000);
    expect(stored).toHaveLength(50);
    expect(failed).toEqual({});
  });

  it('A3/A9: one bad row costs one row, not its batch', async () => {
    const rejectsNul: Insert = async (rows) => {
      if (rows.some((r) => r[5]?.includes('\\u0000'))) throw pgError('22P05');
    };
    const { writer, stored, failed } = harness(rejectsNul);
    for (let i = 0; i < 1000; i++) {
      writer.enqueue(row(i, i % 100 === 7 ? '{"s":"\\u0000"}' : '{"a":1}'));
    }
    await writer.close(5_000);
    expect(stored).toHaveLength(990);
    expect(failed).toEqual({ data: 10 });
  });

  it('A4: a statement timeout falls back to row by row', async () => {
    const tooBig: Insert = async (rows) => {
      if (rows.length > 1) throw pgError('57014', 'canceling statement due to statement timeout');
    };
    const { writer, stored, failed } = harness(tooBig);
    for (let i = 0; i < 100; i++) writer.enqueue(row(i));
    await writer.close(5_000);
    expect(stored).toHaveLength(100);
    expect(failed).toEqual({});
  });

  it('A6: a driver that throws synchronously is counted, never unhandled', async () => {
    const { writer, failed } = harness(() => {
      throw new TypeError('boom');
    });
    writer.enqueue(row(1));
    await writer.close(1_000);
    expect(failed).toEqual({ ambiguous: 1 });
  });

  it('A7: shutdown drains within its deadline, then counts the rest and refuses new rows', async () => {
    const never: Insert = () => new Promise(() => {});
    const { writer, counts } = harness(never);
    for (let i = 0; i < 250; i++) writer.enqueue(row(i));
    await writer.close(50);
    expect(counts.dropped).toBe(249);
    expect(writer.enqueue(row(999))).toBe(false);
    expect(counts.dropped).toBe(250);
  });

  it('A8: a give-up warning names at most 5 request ids and no payload', async () => {
    const down: Insert = async () => {
      throw pgError('42501', 'permission denied for table audit_log');
    };
    const { writer, counts, failed } = harness(down);
    for (let i = 0; i < 20; i++) writer.enqueue(row(i, '{"secret-looking":"payload"}'));
    await writer.close(1_000);
    expect(failed).toEqual({ other: 20 });
    expect(counts.warns).toHaveLength(2);
    expect(counts.warns[1]).toContain('19 row(s), reason=other, req=id-1,id-2,id-3,id-4,id-5:');
    expect(counts.warns.join()).not.toContain('payload');
  });

  it('a row enqueued while the flusher finishes is still written', async () => {
    const { writer, stored } = harness(async () => {});
    writer.enqueue(row(1));
    await tick();
    writer.enqueue(row(2));
    await writer.close(1_000);
    expect(stored.map((r) => r[0])).toEqual(['id-1', 'id-2']);
  });
});

describe('buildInsert / classifyFailure', () => {
  it('numbers 8 placeholders per row and casts only the payload', () => {
    const { text, params } = buildInsert([row(1), row(2)]);
    expect(params).toHaveLength(16);
    expect(text).toContain('($1, $2, $3, $4, $5, $6::jsonb, $7, $8)');
    expect(text).toContain('($9, $10, $11, $12, $13, $14::jsonb, $15, $16)');
  });

  it.each([
    [pgError('ECONNREFUSED'), 'connect'],
    [pgError('40P01'), 'connect'],
    [pgError('57014'), 'timeout'],
    [pgError('23505'), 'data'],
    [pgError('22P02'), 'data'],
    [pgError('28P01'), 'other'],
    [pgError(undefined, 'Connection terminated'), 'ambiguous'],
  ])('%s → %s', (err, reason) => {
    expect(classifyFailure(err)).toBe(reason);
  });
});
