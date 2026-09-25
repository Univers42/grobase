// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { afterEach, beforeEach, describe, expect, it } from '@jest/globals';
import { ExecutionContext, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHmac, randomBytes, randomUUID } from 'node:crypto';
import {
  canonicalIdentityString,
  resolveRequestIdentity,
  signIdentityEnvelope,
} from './request-identity';
import type { VerifiedRequestIdentity } from '../interfaces/user-context.interface';
import { AuthGuard } from '../guards/auth.guard';
import { OptionalAuthGuard } from '../guards/optional-auth.guard';
import { ServiceTokenGuard } from '../guards/service-token.guard';
import { NonceSetClient, RedisNonceStore } from './nonce-store';

// Security harness for the signed identity envelope — the trust boundary that
// lets strict-mode services accept a caller's tenant/user/role. We exercise:
//   - a valid envelope verifies and yields the stamped identity
//   - a TAMPERED signature / payload is rejected (HMAC integrity)
//   - replayed nonces are rejected, stale issued-at is rejected (skew window)
//   - malformed signatures are rejected
//   - strict vs compat mode for RAW (unsigned) identity headers
//   - the envelope NEVER trusts a client-supplied signature without the key
// All behaviour read from request-identity.ts; asserts pin the real contract.

// The signing secret is generated per run (not a hardcoded literal) so the
// createHmac calls below carry no embedded credential — Sonar S6437. KID is the
// key id; HMAC_KEY is the `<kid>:<secret>` env form the production parser expects.
const KID = 'k1';
const SECRET = randomBytes(24).toString('hex');
const HMAC_KEY = `${KID}:${SECRET}`;
// A different per-run secret, used below to forge a signature from an UNKNOWN key.
const WRONG_SECRET = randomBytes(24).toString('hex');

interface FakeReq {
  headers: Record<string, string | string[] | undefined>;
  method: string;
  url: string;
  originalUrl: string;
}

function reqWith(headers: Record<string, string | string[] | undefined>): FakeReq {
  return {
    headers,
    method: 'POST',
    url: '/query/v1/db-1/notes',
    originalUrl: '/query/v1/db-1/notes',
  };
}

function baseIdentity(): VerifiedRequestIdentity {
  return {
    tenantId: 't-1',
    projectId: 't-1',
    appId: 'app-1',
    userId: 'api-key:abc',
    role: 'authenticated',
    roleNames: ['authenticated'],
    scopes: ['read', 'write'],
    authMethod: 'kong-hmac',
  };
}

const ORIGINAL_ENV = { ...process.env };

beforeEach(() => {
  process.env.INTERNAL_IDENTITY_HMAC_KEYS = HMAC_KEY;
  process.env.IDENTITY_HEADER_MODE = 'strict';
  delete process.env.NODE_ENV;
  delete process.env.INTERNAL_IDENTITY_MAX_SKEW_MS;
});

afterEach(() => {
  process.env = { ...ORIGINAL_ENV };
});

describe('signIdentityEnvelope + resolveRequestIdentity (round-trip)', () => {
  it('a freshly signed envelope verifies and yields the stamped identity', async () => {
    const req = reqWith({});
    const headers = signIdentityEnvelope(req, {
      tenantId: 't-1',
      userId: 'api-key:abc',
      role: 'authenticated',
      appId: 'app-1',
      scopes: ['read', 'write'],
    });
    const verifyReq = reqWith(headers);
    const identity = await resolveRequestIdentity(verifyReq, true);
    expect(identity).toBeDefined();
    expect(identity?.tenantId).toBe('t-1');
    expect(identity?.userId).toBe('api-key:abc');
    expect(identity?.role).toBe('authenticated');
    expect(identity?.scopes).toEqual(['read', 'write']);
    expect(identity?.authMethod).toBe('kong-hmac');
  });

  it('throws when no signing key is configured (refuses to forge trust)', () => {
    delete process.env.INTERNAL_IDENTITY_HMAC_KEYS;
    delete process.env.INTERNAL_IDENTITY_HMAC_SECRET;
    expect(() =>
      signIdentityEnvelope(reqWith({}), {
        tenantId: 't',
        userId: 'u',
        role: 'authenticated',
        appId: 'a',
      }),
    ).toThrow();
  });

  // signature is bound to method+path: replaying it on a different route fails.
  it('an envelope signed for one path does not verify on another (path binding)', async () => {
    const signed = signIdentityEnvelope(reqWith({}), {
      tenantId: 't-1',
      userId: 'u',
      role: 'authenticated',
      appId: 'a',
    });
    const otherPath: FakeReq = {
      headers: signed,
      method: 'POST',
      url: '/query/v1/db-1/OTHER',
      originalUrl: '/query/v1/db-1/OTHER',
    };
    await expect(resolveRequestIdentity(otherPath, true)).rejects.toThrow(UnauthorizedException);
  });

  // Privilege escalation: ApiKeyMiddleware signs an envelope for whoever presents
  // a valid api key and assigns it onto the SAME req the client controlled, so any
  // header the envelope does not overwrite survives into the verified identity.
  // roleNames reaches RolesGuard + the ABAC PDP; scopes reaches the api-key admin
  // short-circuit — neither may be client-supplied.
  it('a client-supplied x-baas-roles / x-baas-scopes cannot survive envelope signing', async () => {
    const req = reqWith({
      'x-baas-roles': 'service_role',
      'x-baas-scopes': 'admin',
    });
    const envelope = signIdentityEnvelope(req, {
      tenantId: 't-1',
      userId: 'api-key:abc',
      role: 'authenticated',
      appId: 'api-key',
      scopes: [],
    });
    for (const [name, value] of Object.entries(envelope)) req.headers[name] = value;

    const identity = await resolveRequestIdentity(req, true);
    expect(identity?.roleNames).toEqual(['authenticated']);
    expect(identity?.scopes).toEqual([]);
  });
});

// Build a fully-signed header set by hand so individual fields can be tampered.
function signedHeaders(
  req: FakeReq,
  overrides: Partial<Record<string, string>> = {},
  identity: VerifiedRequestIdentity = baseIdentity(),
): Record<string, string> {
  const iat = String(Date.now());
  const nonce = randomUUID();
  const canonical = canonicalIdentityString(req, identity, iat, nonce);
  const sig = createHmac('sha256', SECRET).update(canonical).digest('hex');
  return {
    'x-baas-tenant-id': identity.tenantId,
    'x-baas-project-id': identity.projectId,
    'x-baas-user-id': identity.userId ?? '',
    'x-baas-role': identity.role,
    'x-baas-app-id': identity.appId,
    'x-baas-issued-at': iat,
    'x-baas-nonce': nonce,
    'x-baas-key-id': KID,
    'x-baas-scopes': identity.scopes.join(','),
    'x-baas-signature': `v1=${sig}`,
    ...overrides,
  };
}

describe('signed-envelope integrity (HMAC tamper detection)', () => {
  it('accepts a correctly-signed envelope', async () => {
    const req = reqWith({});
    const id = await resolveRequestIdentity(reqWith(signedHeaders(req)), true);
    expect(id?.tenantId).toBe('t-1');
  });

  // tampering any signed field invalidates the signature
  const tamperFields: Array<[string, string]> = [
    ['x-baas-tenant-id', 'attacker-tenant'],
    ['x-baas-user-id', 'api-key:victim'],
    ['x-baas-role', 'service_role'],
    ['x-baas-app-id', 'forged-app'],
    ['x-baas-issued-at', String(Date.now() + 5)],
    ['x-baas-nonce', randomUUID()],
    ['x-baas-project-id', 'other-project'],
    // authorization inputs, not just identity: roleNames feeds RolesGuard and the
    // ABAC PDP, scopes feeds the api-key admin short-circuit in query.service.
    ['x-baas-scopes', 'admin'],
    ['x-baas-roles', 'service_role'],
  ];
  it.each(tamperFields)('rejects envelope with tampered %s', async (field, value) => {
    const req = reqWith({});
    const headers = signedHeaders(req, { [field]: value });
    await expect(resolveRequestIdentity(reqWith(headers), true)).rejects.toThrow(
      UnauthorizedException,
    );
  });

  // forged / malformed signatures
  const badSignatures: string[] = [
    'v1=0000000000000000000000000000000000000000000000000000000000000000',
    'v1=deadbeef', // too short
    'v1=' + 'f'.repeat(64), // right length, wrong value
    'v2=' + 'a'.repeat(64), // wrong version prefix
    'badprefix',
    '',
    'v1=', // empty hex
    'v1=GGGG' + 'a'.repeat(60), // non-hex chars
    'v1=' + 'a'.repeat(63), // 63 chars (odd length)
    'v1=' + 'a'.repeat(128), // overlong
  ];
  it.each(badSignatures)('rejects malformed/forged signature %p', async (sig) => {
    const headers = signedHeaders(reqWith({}), { 'x-baas-signature': sig });
    await expect(resolveRequestIdentity(reqWith(headers), true)).rejects.toThrow(
      UnauthorizedException,
    );
  });

  it('rejects when no signing key is configured server-side', async () => {
    const headers = signedHeaders(reqWith({}));
    delete process.env.INTERNAL_IDENTITY_HMAC_KEYS;
    delete process.env.INTERNAL_IDENTITY_HMAC_SECRET;
    await expect(resolveRequestIdentity(reqWith(headers), true)).rejects.toThrow(
      UnauthorizedException,
    );
  });

  it('a signature from an UNKNOWN key is rejected', async () => {
    const req = reqWith({});
    const iat = String(Date.now());
    const nonce = randomUUID();
    const id = baseIdentity();
    const canonical = canonicalIdentityString(req, id, iat, nonce);
    const sig = createHmac('sha256', WRONG_SECRET).update(canonical).digest('hex');
    const headers = {
      ...signedHeaders(req),
      'x-baas-issued-at': iat,
      'x-baas-nonce': nonce,
      'x-baas-signature': `v1=${sig}`,
    };
    await expect(resolveRequestIdentity(reqWith(headers), true)).rejects.toThrow(
      UnauthorizedException,
    );
  });
});

describe('signed-envelope freshness & replay protection', () => {
  it.each(['abc', '-5', 'Infinity'])(
    'a malformed skew %p falls back to the default window, never disables it',
    async (skew) => {
      process.env.INTERNAL_IDENTITY_MAX_SKEW_MS = skew;
      const req = reqWith({});
      const iat = String(Date.now() - 3_600_000);
      const nonce = randomUUID();
      const canonical = canonicalIdentityString(req, baseIdentity(), iat, nonce);
      const sig = createHmac('sha256', SECRET).update(canonical).digest('hex');
      const headers = {
        ...signedHeaders(req),
        'x-baas-issued-at': iat,
        'x-baas-nonce': nonce,
        'x-baas-signature': `v1=${sig}`,
      };
      await expect(resolveRequestIdentity(reqWith(headers), true)).rejects.toThrow(
        UnauthorizedException,
      );
    },
  );

  it('rejects a stale issued-at outside the skew window', async () => {
    process.env.INTERNAL_IDENTITY_MAX_SKEW_MS = '1000';
    const req = reqWith({});
    const id = baseIdentity();
    const iat = String(Date.now() - 60_000); // 60s old, window is 1s
    const nonce = randomUUID();
    const canonical = canonicalIdentityString(req, id, iat, nonce);
    const sig = createHmac('sha256', SECRET).update(canonical).digest('hex');
    const headers = {
      ...signedHeaders(req),
      'x-baas-issued-at': iat,
      'x-baas-nonce': nonce,
      'x-baas-signature': `v1=${sig}`,
    };
    await expect(resolveRequestIdentity(reqWith(headers), true)).rejects.toThrow(
      UnauthorizedException,
    );
  });

  const badIat = ['not-a-number', '', 'NaN', 'Infinity', '1e999'];
  it.each(badIat)('rejects non-finite issued-at %p', async (iat) => {
    const req = reqWith({});
    const id = baseIdentity();
    const nonce = randomUUID();
    const canonical = canonicalIdentityString(req, id, iat, nonce);
    const sig = createHmac('sha256', SECRET).update(canonical).digest('hex');
    const headers = {
      ...signedHeaders(req),
      'x-baas-issued-at': iat,
      'x-baas-nonce': nonce,
      'x-baas-signature': `v1=${sig}`,
    };
    await expect(resolveRequestIdentity(reqWith(headers), true)).rejects.toThrow(
      UnauthorizedException,
    );
  });

  it('rejects a replayed nonce (same envelope cannot be used twice)', async () => {
    const req = reqWith({});
    const headers = signedHeaders(req);
    // first use succeeds
    expect((await resolveRequestIdentity(reqWith(headers), true))?.tenantId).toBe('t-1');
    // identical headers again → replay
    await expect(resolveRequestIdentity(reqWith({ ...headers }), true)).rejects.toThrow(
      UnauthorizedException,
    );
  });
});

describe('signed-envelope required-header enforcement', () => {
  const requiredHeaders = [
    'x-baas-tenant-id',
    'x-baas-user-id',
    'x-baas-role',
    'x-baas-app-id',
    'x-baas-issued-at',
    'x-baas-nonce',
  ];
  it.each(requiredHeaders)('rejects an envelope missing %s', async (missing) => {
    const headers = signedHeaders(reqWith({}));
    delete headers[missing];
    await expect(resolveRequestIdentity(reqWith(headers), true)).rejects.toThrow(
      UnauthorizedException,
    );
  });
});

describe('raw (unsigned) identity headers — strict vs compat', () => {
  it('STRICT mode rejects raw x-user-id headers (no signature)', async () => {
    process.env.IDENTITY_HEADER_MODE = 'strict';
    const req = reqWith({ 'x-user-id': 'u-1', 'x-baas-tenant-id': 't-1' });
    await expect(resolveRequestIdentity(req, true)).rejects.toThrow(UnauthorizedException);
  });

  it('COMPAT mode accepts raw x-user-id headers (legacy path)', async () => {
    process.env.IDENTITY_HEADER_MODE = 'compat';
    const req = reqWith({
      'x-user-id': 'u-1',
      'x-baas-tenant-id': 't-1',
      'x-user-role': 'authenticated',
    });
    const id = await resolveRequestIdentity(req, true);
    expect(id?.userId).toBe('u-1');
    expect(id?.tenantId).toBe('t-1');
    expect(id?.authMethod).toBe('legacy-header');
  });

  it('production defaults to strict (NODE_ENV=production, no explicit mode)', async () => {
    delete process.env.IDENTITY_HEADER_MODE;
    process.env.NODE_ENV = 'production';
    const req = reqWith({ 'x-user-id': 'u-1', 'x-baas-tenant-id': 't-1' });
    await expect(resolveRequestIdentity(req, true)).rejects.toThrow(UnauthorizedException);
  });

  it('throws when identity is required but entirely absent', async () => {
    process.env.IDENTITY_HEADER_MODE = 'strict';
    await expect(resolveRequestIdentity(reqWith({}), true)).rejects.toThrow(UnauthorizedException);
  });

  it('returns undefined when identity is optional and absent (no throw)', async () => {
    process.env.IDENTITY_HEADER_MODE = 'strict';
    await expect(resolveRequestIdentity(reqWith({}), false)).resolves.toBeUndefined();
  });
});

// H-14: the replay cache is a NonceStore port. A Redis-backed store is shared by
// every replica, so an envelope accepted by one replica is a replay on another.
function sharedRedis(): NonceSetClient {
  const keys = new Set<string>();
  return {
    set: async (key) => {
      if (keys.has(key)) return null;
      keys.add(key);
      return 'OK';
    },
  };
}

describe('signed-envelope replay across replicas (shared NonceStore)', () => {
  it('a nonce accepted by replica A is rejected by replica B', async () => {
    const client = sharedRedis();
    const replicaA = new RedisNonceStore(client);
    const replicaB = new RedisNonceStore(client);
    const headers = signedHeaders(reqWith({}));
    const first = await resolveRequestIdentity(reqWith(headers), true, replicaA);
    expect(first?.tenantId).toBe('t-1');
    await expect(resolveRequestIdentity(reqWith({ ...headers }), true, replicaB)).rejects.toThrow(
      UnauthorizedException,
    );
  });

  it('fails CLOSED (401) when the nonce store errors', async () => {
    const broken = new RedisNonceStore({
      set: async () => {
        throw new Error('ECONNREFUSED');
      },
    });
    const headers = signedHeaders(reqWith({}));
    await expect(resolveRequestIdentity(reqWith(headers), true, broken)).rejects.toThrow(
      UnauthorizedException,
    );
  });
});

function httpContext(req: FakeReq): ExecutionContext {
  return { switchToHttp: () => ({ getRequest: () => req }) } as unknown as ExecutionContext;
}

function noServiceToken(): ConfigService {
  return { get: () => undefined } as unknown as ConfigService;
}

describe('guards reject a replayed envelope (no missed await)', () => {
  const guards: Array<[string, () => { canActivate(ctx: ExecutionContext): unknown }]> = [
    ['AuthGuard', () => new AuthGuard()],
    ['OptionalAuthGuard', () => new OptionalAuthGuard()],
    ['ServiceTokenGuard', () => new ServiceTokenGuard(noServiceToken())],
  ];
  it.each(guards)('%s.canActivate: first use passes, replay is 401', async (_name, make) => {
    const guard = make();
    const headers = signedHeaders(reqWith({}));
    const firstReq = reqWith(headers);
    await expect(Promise.resolve(guard.canActivate(httpContext(firstReq)))).resolves.toBe(true);
    expect((firstReq as FakeReq & { identity?: VerifiedRequestIdentity }).identity?.tenantId).toBe(
      't-1',
    );
    const replay = Promise.resolve().then(() => guard.canActivate(httpContext(reqWith(headers))));
    await expect(replay).rejects.toThrow(UnauthorizedException);
  });
});
