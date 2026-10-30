import { afterEach, beforeEach, describe, expect, it, jest } from '@jest/globals';
import { Logger } from '@nestjs/common';
import { createHmac, randomBytes } from 'node:crypto';
import { register } from 'prom-client';
import type { VerifiedRequestIdentity } from '../interfaces/user-context.interface';
import { resolveRequestIdentity } from './request-identity';
import { resetStrictShadowForTest, shadowStrict, type ShadowRequest } from './strict-shadow';

// IDENTITY_STRICT_SHADOW (devil SS2–SS8): every case runs the real strict resolve
// through resolveRequestIdentity, so the shadow judges what a strict flip would do.
const JWT_SECRET = randomBytes(24).toString('hex');
const ISSUER = 'https://localhost:8443/auth/v1';
const METRIC = 'mini_baas_identity_strict_shadow_total';
const ENV_KEYS = [
  'IDENTITY_HEADER_MODE',
  'IDENTITY_STRICT_SHADOW',
  'GOTRUE_JWT_SECRET',
  'GOTRUE_JWT_ISSUER',
  'JWT_ALLOW_NO_ISSUER',
  'OTEL_SERVICE_NAME',
] as const;

function mintJwt(claims: Record<string, unknown>): string {
  const now = Math.floor(Date.now() / 1000);
  const part = (value: unknown): string => Buffer.from(JSON.stringify(value)).toString('base64url');
  const body = `${part({ alg: 'HS256', typ: 'JWT' })}.${part({ iat: now, exp: now + 600, iss: ISSUER, ...claims })}`;
  return `${body}.${createHmac('sha256', JWT_SECRET).update(body).digest('base64url')}`;
}

function routed(headers: Record<string, string>, path = '/v1/things/:id') {
  return {
    headers,
    method: 'GET',
    url: '/v1/things/1',
    originalUrl: '/v1/things/1',
    route: { path },
  };
}

const RAW = { 'x-user-id': 'user-7f3a', 'x-user-role': 'authenticated' };

async function counted(): Promise<Record<string, number>> {
  const metric = register.getSingleMetric(METRIC);
  const values = metric ? (await metric.get()).values : [];
  return Object.fromEntries(values.map((v) => [`${v.labels.result}/${v.labels.reason}`, v.value]));
}

describe('IDENTITY_STRICT_SHADOW judges compat raw-header accepts', () => {
  const saved = Object.fromEntries(ENV_KEYS.map((key) => [key, process.env[key]]));
  let warn: jest.SpiedFunction<Logger['warn']>;

  beforeEach(() => {
    Object.assign(process.env, {
      IDENTITY_HEADER_MODE: 'compat',
      IDENTITY_STRICT_SHADOW: '1',
      GOTRUE_JWT_SECRET: JWT_SECRET,
      GOTRUE_JWT_ISSUER: ISSUER,
      OTEL_SERVICE_NAME: 'shadow-spec',
    });
    delete process.env.JWT_ALLOW_NO_ISSUER;
    register.resetMetrics();
    resetStrictShadowForTest();
    warn = jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
  });

  afterEach(() => {
    warn.mockRestore();
    for (const key of ENV_KEYS) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  });

  const table: Array<[string, () => Record<string, string>, string]> = [
    ['no bearer', () => RAW, 'would_reject/no_bearer'],
    [
      'an invalid bearer',
      () => ({ ...RAW, authorization: 'Bearer not.a.jwt' }),
      'would_reject/bearer_invalid',
    ],
    [
      'a matching JWT',
      () => ({ ...RAW, authorization: `Bearer ${mintJwt({ sub: 'user-7f3a' })}` }),
      'would_accept/match',
    ],
    [
      'a JWT for another tenant',
      () => ({
        ...RAW,
        'x-baas-tenant-id': 'tenant-raw',
        authorization: `Bearer ${mintJwt({ sub: 'user-7f3a' })}`,
      }),
      'would_reject/mismatch',
    ],
  ];

  it.each(table)('counts %s and still returns the compat identity', async (_name, headers, key) => {
    const identity = await resolveRequestIdentity(routed(headers()), true);
    expect(identity?.authMethod).toBe('legacy-header');
    expect(await counted()).toEqual({ [key]: 1 });
  });

  it('names the differing fields and never a value', async () => {
    const token = mintJwt({ sub: 'user-7f3a' });
    const req = routed({
      ...RAW,
      'x-baas-tenant-id': 'tenant-raw',
      authorization: `Bearer ${token}`,
    });
    await resolveRequestIdentity(req, true);
    expect(warn).toHaveBeenCalledTimes(1);
    const line = String(warn.mock.calls[0]?.[0]);
    expect(line).toBe(
      'identity: would_reject service=shadow-spec route=/v1/things/:id reason=mismatch fields=tenantId,projectId',
    );
    for (const value of ['user-7f3a', 'tenant-raw', token]) expect(line).not.toContain(value);
  });

  it('reports unverifiable when strict cannot run (no pinned issuer)', async () => {
    delete process.env.GOTRUE_JWT_ISSUER;
    const req = routed({ ...RAW, authorization: `Bearer ${mintJwt({ sub: 'user-7f3a' })}` });
    await expect(resolveRequestIdentity(req, true)).resolves.toMatchObject({ userId: 'user-7f3a' });
    expect(await counted()).toEqual({ 'would_reject/unverifiable': 1 });
  });

  it('logs one line per key per 60 s, while the counter keeps the volume', async () => {
    const now = jest.spyOn(Date, 'now').mockReturnValue(1_000_000);
    await resolveRequestIdentity(routed(RAW), true);
    await resolveRequestIdentity(routed(RAW), true);
    expect(warn).toHaveBeenCalledTimes(1);
    now.mockReturnValue(1_060_000);
    await resolveRequestIdentity(routed(RAW), true);
    now.mockRestore();
    expect(warn).toHaveBeenCalledTimes(2);
    expect(await counted()).toEqual({ 'would_reject/no_bearer': 3 });
  });

  it('skips a resolve that is not on a route (app-level middleware)', async () => {
    const { route: _route, ...unrouted } = routed(RAW);
    await resolveRequestIdentity(unrouted, true);
    expect(await counted()).toEqual({});
    expect(warn).not.toHaveBeenCalled();
  });
});

describe('shadowStrict, the primitive', () => {
  const compat = {
    userId: 'u',
    tenantId: 't',
    authMethod: 'legacy-header',
  } as VerifiedRequestIdentity;
  const req: ShadowRequest = { headers: {}, route: { path: '/x' } };

  afterEach(() => {
    delete process.env.IDENTITY_STRICT_SHADOW;
  });

  it('never calls the judge with the flag off', () => {
    delete process.env.IDENTITY_STRICT_SHADOW;
    const judge = jest.fn(() => undefined);
    expect(shadowStrict(req, compat, judge)).toBe(compat);
    expect(judge).not.toHaveBeenCalled();
  });

  it('never throws, whatever the judge does', () => {
    process.env.IDENTITY_STRICT_SHADOW = 'true';
    const judge = jest.fn((): VerifiedRequestIdentity | undefined => {
      throw new Error('boom');
    });
    expect(shadowStrict(req, compat, judge)).toBe(compat);
    expect(judge).toHaveBeenCalledTimes(1);
  });
});
