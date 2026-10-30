import { describe, expect, it, jest } from '@jest/globals';
import { AuditService } from './audit.service';
import { isUuid, requestIdUuid, uuidV5 } from './request-id';

const KONG_UUID = '61e4b18d-2dfe-4d8d-95f5-6988ff443eaf';

describe('requestIdUuid', () => {
  it('matches the RFC 4122 v5 vector (DNS namespace, www.example.com)', () => {
    expect(uuidV5('www.example.com', '6ba7b810-9dad-11d1-80b4-00c04fd430c8')).toBe(
      '2ed6657d-e927-568b-95e1-2665a8aea6a2',
    );
  });

  it('keeps every Kong uuid#counter request distinct (never strips the counter)', () => {
    const first = requestIdUuid(`${KONG_UUID}#41649`);
    const second = requestIdUuid(`${KONG_UUID}#41650`);
    expect(first).not.toBe(second);
    expect(first).not.toBe(KONG_UUID);
    expect(isUuid(first) && isUuid(second)).toBe(true);
  });

  it('is deterministic, so audit_log and the outbox store the same id', () => {
    expect(requestIdUuid(`${KONG_UUID}#7`)).toBe(requestIdUuid(`${KONG_UUID}#7`));
  });

  it('stores a bare UUID unchanged', () => {
    expect(requestIdUuid(KONG_UUID)).toBe(KONG_UUID);
  });

  it.each([['req-1'], ['x'.repeat(16 * 1024)], ['']])('maps garbage %# to a valid UUID', (raw) => {
    expect(isUuid(requestIdUuid(raw))).toBe(true);
  });
});

describe('AuditService.record request_id', () => {
  it('binds $1 as a UUID for a Kong uuid#counter header', async () => {
    const svc = new AuditService();
    const query = jest.fn(async () => ({ rows: [] }));
    (svc as unknown as { pool: { query: typeof query } }).pool = { query };
    await svc.record({ requestId: `${KONG_UUID}#41649`, action: 'POST', resource: 'widget' });
    const params = query.mock.calls[0] as unknown as [string, unknown[]];
    expect(params[1][0]).toBe(requestIdUuid(`${KONG_UUID}#41649`));
    expect(isUuid(params[1][0] as string)).toBe(true);
  });
});
