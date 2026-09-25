// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { describe, expect, it } from '@jest/globals';
import type { ConfigService } from '@nestjs/config';
import { QueryService } from './query.service';

// `resourceIdFromFilter` is a pure private helper (it reads only its argument,
// never `this`), so exercise it through a prototype-only instance — no need for
// the service's heavy DI constructor and its many injected dependencies.
type WithHelper = {
  resourceIdFromFilter(filter: Record<string, unknown> | undefined): string | undefined;
};

describe('QueryService.resourceIdFromFilter', () => {
  const svc = Object.create(QueryService.prototype) as unknown as WithHelper;
  const call = (filter: Record<string, unknown> | undefined) => svc.resourceIdFromFilter(filter);

  it('returns undefined for missing / undefined / null ids', () => {
    expect(call(undefined)).toBeUndefined();
    expect(call({})).toBeUndefined();
    expect(call({ id: null })).toBeUndefined();
  });

  it('passes a string id through unchanged', () => {
    expect(call({ id: 'abc' })).toBe('abc');
  });

  it('stringifies number / boolean / bigint primitives', () => {
    expect(call({ id: 42 })).toBe('42');
    expect(call({ id: true })).toBe('true');
    expect(call({ id: 10n })).toBe('10');
  });

  it('JSON-encodes a composite (object) id', () => {
    expect(call({ id: { a: 1 } })).toBe('{"a":1}');
  });
});

describe('QueryService.isStaticMount', () => {
  const STATIC_DB = '22222222-2222-4222-8222-222222222222';
  const mounts = JSON.stringify({
    [STATIC_DB]: { engine: 'postgresql', connection_string: 'postgres://static/db' },
  });
  const config = {
    getOrThrow: () => 'http://adapter-registry:3020',
    get: (key: string, def?: unknown) => (key === 'DATA_PLANE_MOUNTS' ? mounts : def),
  } as unknown as ConfigService;
  const unused = {} as never;
  const svc = new QueryService(config, unused, unused, unused, unused, unused);

  it('is true only for a dbId in the DATA_PLANE_MOUNTS table', () => {
    expect(svc.isStaticMount(STATIC_DB)).toBe(true);
    expect(svc.isStaticMount('33333333-3333-4333-8333-333333333333')).toBe(false);
  });
});

// H-5: an `admin`-scoped app key skips the ABAC PDP entirely. That is by design
// (m139 pins API_KEY_ABAC_ENABLED off), but until now it left no trace, so a
// reader of the logs could not tell "the PDP allowed this" from "the PDP never
// ran". These assert the bypass is announced, rate-limited so an admin key under
// load cannot flood the log, and that the DECISION itself is unchanged.
describe('QueryService admin-scope ABAC bypass is observable (H-5)', () => {
  const config = {
    getOrThrow: () => 'http://adapter-registry:3020',
    get: (_key: string, def?: unknown) => def,
  } as unknown as ConfigService;
  const unused = {} as never;

  type Decider = {
    decideByApiKeyScope(
      identity: Record<string, unknown>,
      op: string,
    ): { allow: boolean; reason: string } | undefined;
    logger: { log(message: string): void };
  };

  function decider(): { svc: Decider; lines: string[] } {
    const svc = new QueryService(
      config,
      unused,
      unused,
      unused,
      unused,
      unused,
    ) as unknown as Decider;
    const lines: string[] = [];
    svc.logger = { log: (message: string) => lines.push(message) };
    return { svc, lines };
  }

  const adminIdentity = (userId = 'api-key:k1') => ({
    authMethod: 'kong-hmac',
    userId,
    appId: 'api-key',
    tenantId: 't-1',
    scopes: ['admin'],
  });

  it('announces the bypass, naming the tenant and subject', () => {
    const { svc, lines } = decider();
    expect(svc.decideByApiKeyScope(adminIdentity(), 'delete')).toEqual({
      allow: true,
      reason: 'api-key admin scope',
    });
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain('t-1');
    expect(lines[0]).toContain('api-key:k1');
  });

  it('logs a repeat subject once, not once per request', () => {
    const { svc, lines } = decider();
    for (let i = 0; i < 25; i++) svc.decideByApiKeyScope(adminIdentity(), 'insert');
    expect(lines).toHaveLength(1);
  });

  it('logs each distinct subject separately', () => {
    const { svc, lines } = decider();
    svc.decideByApiKeyScope(adminIdentity('api-key:k1'), 'get');
    svc.decideByApiKeyScope(adminIdentity('api-key:k2'), 'get');
    expect(lines).toHaveLength(2);
  });

  it('says nothing for a non-admin scope — the PDP path is not a bypass', () => {
    const { svc, lines } = decider();
    const identity = { ...adminIdentity(), scopes: ['read'] };
    expect(svc.decideByApiKeyScope(identity, 'list')).toEqual({
      allow: true,
      reason: 'api-key read scope',
    });
    expect(svc.decideByApiKeyScope(identity, 'delete')?.allow).toBe(false);
    expect(lines).toHaveLength(0);
  });
});
