// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { afterEach, describe, expect, it, jest } from '@jest/globals';
import { ConfigService } from '@nestjs/config';
import { ProbeService } from './probe.service';
import type { QueryService } from './query.service';
import type { RustDataPlaneProxy, RustEngineProbe } from '../proxy/rust-data-plane.proxy';

describe('ProbeService', () => {
  const probeResult = (over: Partial<RustEngineProbe> = {}): RustEngineProbe => ({
    server_version: '16.2',
    tls: 'encrypted',
    ...over,
  });

  /** A service whose QueryService (isStaticMount/resolveConnection) and proxy
   *  (probe) are doubles — `mount` overrides the resolved mount, `probe` the
   *  data plane's answer, `config` the env knobs. */
  function build(
    opts: {
      config?: Record<string, string>;
      mount?: Record<string, unknown>;
      probe?: Partial<RustEngineProbe>;
    } = {},
  ) {
    const config = {
      get: (key: string, def?: string) => opts.config?.[key] ?? def,
    } as unknown as ConfigService;
    const query = {
      isStaticMount: jest.fn(() => false),
      resolveConnection: jest.fn(async () => ({
        engine: 'postgresql',
        connection_string: 'postgres://example/db',
        isolation: 'shared_rls',
        revision: 1,
        ...opts.mount,
      })),
    };
    const proxy = {
      probe: jest.fn(async () => probeResult(opts.probe)),
    };
    const service = new ProbeService(
      config,
      query as unknown as QueryService,
      proxy as unknown as RustDataPlaneProxy,
    );
    return { service, query, proxy };
  }

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('returns {dbId, engine, server_version, tls} for a network mount, never the DSN', async () => {
    const { service, query, proxy } = build({ mount: { location: 'network' } });
    const result = await service.probe('db-1', 'user-1', { tenantId: 't-1' } as never);

    expect(query.resolveConnection).toHaveBeenCalledWith('db-1', 't-1');
    expect(proxy.probe).toHaveBeenCalledWith(
      expect.objectContaining({
        databaseId: 'db-1',
        engine: 'postgresql',
        tenantId: 't-1',
        userId: 'user-1',
        connectionString: 'postgres://example/db',
        isolation: 'shared_rls',
      }),
    );
    expect(result).toEqual({
      dbId: 'db-1',
      engine: 'postgresql',
      server_version: '16.2',
      tls: 'encrypted',
    });
    expect(result).not.toHaveProperty('connection_string');
    expect(JSON.stringify(result)).not.toContain('postgres://');
  });

  it("hides a platform mount's version; the TLS posture passes through", async () => {
    const { service } = build({ mount: { location: 'platform' }, probe: { tls: 'verified' } });
    const result = await service.probe('db-1', 'user-1', { tenantId: 't-1' } as never);
    expect(result.server_version).toBe('platform');
    expect(result.tls).toBe('verified');
  });

  it('masks the version as unknown when the location is absent or unknown', async () => {
    const absent = build();
    const a = await absent.service.probe('db-1', 'user-1', { tenantId: 't-1' } as never);
    expect(a.server_version).toBe('unknown');
    const unknown = build({ mount: { location: 'unknown' } });
    const u = await unknown.service.probe('db-1', 'user-1', { tenantId: 't-1' } as never);
    expect(u.server_version).toBe('unknown');
  });

  it('refuses a static mount before resolving or probing', async () => {
    const { service, query, proxy } = build();
    query.isStaticMount.mockReturnValue(true);
    await expect(
      service.probe('db-1', 'user-1', { tenantId: 't-1' } as never),
    ).rejects.toMatchObject({ status: 404 });
    expect(query.resolveConnection).not.toHaveBeenCalled();
    expect(proxy.probe).not.toHaveBeenCalled();
  });

  it('serves a second call within the TTL from cache; a new revision misses', async () => {
    const { service, query, proxy } = build({ mount: { location: 'network' } });
    const identity = { tenantId: 't-1' } as never;
    await service.probe('db-1', 'user-1', identity);
    await service.probe('db-1', 'user-1', identity);
    expect(proxy.probe).toHaveBeenCalledTimes(1); // same revision → cached
    // A credential rotation forks the pool → a fresh probe, not the old answer.
    query.resolveConnection.mockImplementationOnce(async () => ({
      engine: 'postgresql',
      connection_string: 'postgres://example/db',
      isolation: 'shared_rls',
      revision: 2,
      location: 'network',
    }));
    await service.probe('db-1', 'user-1', identity);
    expect(proxy.probe).toHaveBeenCalledTimes(2); // new revision → cache miss
  });

  it('clamps a zero TTL to 30s: the second call still hits the cache (devil G4 P10)', async () => {
    const { service, proxy } = build({ config: { QUERY_ROUTER_PROBE_CACHE_TTL_MS: '0' } });
    const identity = { tenantId: 't-1' } as never;
    await service.probe('db-1', 'user-1', identity);
    await service.probe('db-1', 'user-1', identity);
    expect(proxy.probe).toHaveBeenCalledTimes(1);
  });

  it('falls back to 30s for a non-numeric TTL, so entries still expire', async () => {
    const { service, proxy } = build({ config: { QUERY_ROUTER_PROBE_CACHE_TTL_MS: 'soon' } });
    const identity = { tenantId: 't-1' } as never;
    const start = Date.now();
    const clock = jest.spyOn(Date, 'now').mockReturnValue(start);
    await service.probe('db-1', 'user-1', identity);
    clock.mockReturnValue(start + 30_001);
    await service.probe('db-1', 'user-1', identity);
    clock.mockRestore();
    expect(proxy.probe).toHaveBeenCalledTimes(2);
  });

  it('carries tls_version only when the data plane sent one', async () => {
    const withTls = build({ probe: { tls_version: 'TLSv1.3' } });
    const result = await withTls.service.probe('db-1', 'user-1', { tenantId: 't-1' } as never);
    expect(result.tls_version).toBe('TLSv1.3');
    const withoutTls = build();
    const bare = await withoutTls.service.probe('db-1', 'user-1', { tenantId: 't-1' } as never);
    expect(bare).not.toHaveProperty('tls_version');
  });

  it('does not cache a failed probe — the next call probes again', async () => {
    const { service, proxy } = build({ mount: { location: 'network' } });
    const identity = { tenantId: 't-1' } as never;
    proxy.probe.mockImplementationOnce(() => Promise.reject(new Error('data plane down')));
    await expect(service.probe('db-1', 'user-1', identity)).rejects.toThrow('data plane down');
    const result = await service.probe('db-1', 'user-1', identity);
    expect(proxy.probe).toHaveBeenCalledTimes(2);
    expect(result.server_version).toBe('16.2');
  });
});
