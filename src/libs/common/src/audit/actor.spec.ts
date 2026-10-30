import { describe, expect, it, jest } from '@jest/globals';
import type {
  VerifiedAuthMethod,
  VerifiedRequestIdentity,
} from '../interfaces/user-context.interface';
import { auditActor } from './actor';
import { AuditService } from './audit.service';
import { isUuid } from './request-id';

const SUB = '00000000-0000-4000-8000-000000000001';
const TENANT = '00000000-0000-4000-8000-000000000002';
const KEY_ID = '00000000-0000-4000-8000-000000000003';

function identity(
  authMethod: VerifiedAuthMethod,
  userId: string | undefined,
  role = 'authenticated',
): VerifiedRequestIdentity {
  return {
    tenantId: TENANT,
    projectId: 'p',
    appId: 'a',
    userId,
    role,
    roleNames: [],
    scopes: [],
    authMethod,
  };
}

describe('auditActor (ADR 0020 mapping)', () => {
  it.each([
    ['kong-hmac user:<uuid>', identity('kong-hmac', `user:${SUB}`, 'admin'), SUB, 'admin'],
    ['kong-hmac api-key:<id>', identity('kong-hmac', `api-key:${KEY_ID}`), null, 'authenticated'],
    ['kong-hmac empty api-key:', identity('kong-hmac', 'api-key:'), null, 'authenticated'],
    ['kong-hmac bare user:', identity('kong-hmac', 'user:'), null, 'authenticated'],
    ['kong-hmac user:not-a-uuid', identity('kong-hmac', 'user:not-a-uuid'), null, 'authenticated'],
    ['kong-hmac bare uuid (no prefix)', identity('kong-hmac', SUB), null, 'authenticated'],
    [
      'kong-hmac User: (case-sensitive)',
      identity('kong-hmac', `User:${SUB}`),
      null,
      'authenticated',
    ],
    ['jwt uuid sub', identity('jwt', SUB), SUB, 'authenticated'],
    ['jwt non-uuid sub', identity('jwt', 'tenant-slug'), null, 'authenticated'],
    ['legacy-header bare uuid', identity('legacy-header', SUB), SUB, 'authenticated'],
    [
      'legacy-header never strips user:',
      identity('legacy-header', `user:${SUB}`),
      null,
      'authenticated',
    ],
    [
      'service-token never the tenant id',
      identity('service-token', undefined, 'service_role'),
      null,
      'service_role',
    ],
    ['mtls', identity('mtls', SUB), null, null],
  ])('%s', (_name, id, actorId, actorRole) => {
    expect(auditActor(id)).toEqual({ actorId, actorRole });
  });

  it('no identity → NULL actor', () => {
    expect(auditActor(undefined)).toEqual({ actorId: null, actorRole: null });
  });

  it('never yields the tenant id when userId is absent', () => {
    for (const m of ['kong-hmac', 'jwt', 'legacy-header', 'service-token', 'mtls'] as const) {
      expect(auditActor(identity(m, undefined)).actorId).not.toBe(TENANT);
    }
  });
});

describe('AuditService.record actor_id and payload', () => {
  async function insertParams(entry: Parameters<AuditService['record']>[0]): Promise<unknown[]> {
    const svc = new AuditService();
    const query = jest.fn(async () => ({ rows: [] }));
    (svc as unknown as { pool: { query: typeof query } }).pool = { query };
    await svc.record(entry);
    return (query.mock.calls[0] as unknown as [string, unknown[]])[1];
  }

  it.each(['kong-hmac', 'jwt', 'legacy-header', 'service-token', 'mtls'] as const)(
    'binds $2 as a UUID or NULL for %s',
    async (method) => {
      for (const userId of [`user:${SUB}`, `api-key:${KEY_ID}`, SUB, 'x', undefined]) {
        const params = await insertParams({
          requestId: 'req-1',
          ...auditActor(identity(method, userId)),
          action: 'POST',
          resource: '/x',
        });
        expect(params[1] === null || isUuid(params[1] as string)).toBe(true);
      }
    },
  );

  it('redacts nested secret-named keys', async () => {
    const params = await insertParams({
      requestId: 'req-1',
      action: 'POST',
      resource: '/x',
      payload: { data: { password: 'x', rows: [{ api_key: 'k', ok: 1 }] }, token: 't' },
    });
    expect(JSON.parse(params[5] as string)).toEqual({
      data: { password: '[REDACTED]', rows: [{ api_key: '[REDACTED]', ok: 1 }] },
      token: '[REDACTED]',
    });
  });

  it('truncates past the depth limit instead of storing it unscanned', async () => {
    const params = await insertParams({
      requestId: 'req-1',
      action: 'POST',
      resource: '/x',
      payload: { a: { b: { c: { d: { secret: 's' } } } }, n: 'v' },
    });
    expect(JSON.parse(params[5] as string)).toEqual({
      a: { b: { c: { d: '[TRUNCATED]' } } },
      n: 'v',
    });
  });

  it('caps the entry count', async () => {
    const wide = Object.fromEntries(Array.from({ length: 300 }, (_, i) => [`k${i}`, i]));
    const params = await insertParams({
      requestId: 'r',
      action: 'POST',
      resource: '/x',
      payload: wide,
    });
    const stored = JSON.parse(params[5] as string) as Record<string, unknown>;
    expect(Object.keys(stored)).toHaveLength(257);
    expect(stored['[TRUNCATED]']).toBe(44);
  });
});
