// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { afterEach, describe, expect, it } from '@jest/globals';
import { ConfigService } from '@nestjs/config';
import { HttpService } from '@nestjs/axios';
import { of } from 'rxjs';
import { computeServiceAuth } from '@mini-baas/common';
import {
  assertOriginOnly,
  RustDataPlaneProxy,
  type RustProxyContext,
} from './rust-data-plane.proxy';

// The constructor only reads config (it never touches HttpService), so a config
// double + an empty http double fully exercises the URL/flag/engine resolution.
function make(env: Record<string, string> = {}, http: unknown = {}): RustDataPlaneProxy {
  const config = {
    get: (key: string, def?: unknown) => env[key] ?? def,
  } as unknown as ConfigService;
  return new RustDataPlaneProxy(config, http as HttpService);
}

describe('RustDataPlaneProxy constructor', () => {
  it('builds with the default in-cluster data-plane URL (forwarding off)', () => {
    expect(make()).toBeDefined();
  });

  it('honours RUST_DATA_PLANE_FORWARD + a custom engine allowlist from config', () => {
    expect(
      make({
        RUST_DATA_PLANE_FORWARD: 'true',
        RUST_DATA_PLANE_FORWARD_ENGINES: 'postgresql, mysql ,',
        RUST_DATA_PLANE_URL: 'https://dp:9999',
      }),
    ).toBeDefined();
  });
});

describe('RUST_DATA_PLANE_URL is an origin', () => {
  it('accepts scheme://host:port with or without the trailing slash', () => {
    expect(() => assertOriginOnly('http://data-plane-router-rust:4011')).not.toThrow();
    expect(() => assertOriginOnly('https://dp:9999/')).not.toThrow();
  });

  it('refuses a path or a query, which would break every signed call', () => {
    expect(() => assertOriginOnly('http://dp:4011/prefix')).toThrow(/must be an origin/);
    expect(() => assertOriginOnly('http://dp:4011/?x=1')).toThrow(/must be an origin/);
    expect(() => make({ RUST_DATA_PLANE_URL: 'http://dp:4011/api' })).toThrow(/must be an origin/);
  });
});

describe('postJson signs the bytes it sends', () => {
  const saved = process.env.SERVICE_TOKEN_MODE;
  afterEach(() => {
    if (saved === undefined) delete process.env.SERVICE_TOKEN_MODE;
    else process.env.SERVICE_TOKEN_MODE = saved;
  });

  type Sent = { url: string; body: unknown; headers: Record<string, string> };
  function capture(): { http: unknown; sent: Sent[] } {
    const sent: Sent[] = [];
    const http = {
      post: (url: string, body: unknown, opts: { headers: Record<string, string> }) => {
        sent.push({ url, body, headers: opts.headers });
        return of({ data: { rows: [], affected_rows: 0 } });
      },
    };
    return { http, sent };
  }
  const context: RustProxyContext = {
    databaseId: 'db1',
    engine: 'postgresql',
    tenantId: 't1',
    userId: 'u1',
    credentialReference: 'ref',
    credentialVersion: '1',
    connectionString: 'postgres://example/db',
  };

  it('in hmac mode: a string body, JSON content type, and a v1 signature over that string', async () => {
    process.env.SERVICE_TOKEN_MODE = 'hmac';
    const { http, sent } = capture();
    const proxy = make({ ADAPTER_REGISTRY_SERVICE_TOKEN: 'test-token' }, http);
    await proxy.execute(context, 'notes', 'list', {} as never);

    const [{ url, body, headers }] = sent;
    expect(url).toBe('http://data-plane-router-rust:4011/v1/query');
    expect(typeof body).toBe('string');
    expect(headers['Content-Type']).toBe('application/json');
    expect(headers['X-Service-Token']).toBeUndefined();
    // computeServiceAuth matches the Rust golden vectors byte for byte
    // (service-auth.spec.ts), so equality here means the Rust verifier accepts it.
    const ts = Number(headers['X-Service-Auth'].split('.')[1]);
    expect(headers['X-Service-Auth']).toBe(
      computeServiceAuth('test-token', 'POST', '/v1/query', body as string, ts),
    );
  });

  it('outside hmac mode: the static token, as before', async () => {
    delete process.env.SERVICE_TOKEN_MODE;
    const { http, sent } = capture();
    await make({ ADAPTER_REGISTRY_SERVICE_TOKEN: 'tok' }, http).execute(
      context,
      'notes',
      'list',
      {} as never,
    );
    expect(sent[0].headers['X-Service-Token']).toBe('tok');
    expect(sent[0].headers['X-Service-Auth']).toBeUndefined();
  });

  it('with no token configured: no auth header at all', async () => {
    process.env.SERVICE_TOKEN_MODE = 'hmac';
    const { http, sent } = capture();
    await make({}, http).execute(context, 'notes', 'list', {} as never);
    expect(Object.keys(sent[0].headers)).toEqual(['Content-Type']);
  });
});
