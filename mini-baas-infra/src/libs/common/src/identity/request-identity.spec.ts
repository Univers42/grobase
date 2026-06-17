// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { afterEach, beforeEach, describe, expect, it } from '@jest/globals';
import { UnauthorizedException } from '@nestjs/common';
import { createHmac, randomBytes, randomUUID } from 'node:crypto';
import {
  canonicalIdentityString,
  resolveRequestIdentity,
  signIdentityEnvelope,
} from './request-identity';
import type { VerifiedRequestIdentity } from '../interfaces/user-context.interface';

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
  return { headers, method: 'POST', url: '/query/v1/db-1/notes', originalUrl: '/query/v1/db-1/notes' };
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
  it('a freshly signed envelope verifies and yields the stamped identity', () => {
    const req = reqWith({});
    const headers = signIdentityEnvelope(req, {
      tenantId: 't-1',
      userId: 'api-key:abc',
      role: 'authenticated',
      appId: 'app-1',
      scopes: ['read', 'write'],
    });
    const verifyReq = reqWith(headers);
    const identity = resolveRequestIdentity(verifyReq, true);
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
        tenantId: 't', userId: 'u', role: 'authenticated', appId: 'a',
      }),
    ).toThrow();
  });

  // signature is bound to method+path: replaying it on a different route fails.
  it('an envelope signed for one path does not verify on another (path binding)', () => {
    const signed = signIdentityEnvelope(reqWith({}), {
      tenantId: 't-1', userId: 'u', role: 'authenticated', appId: 'a',
    });
    const otherPath: FakeReq = {
      headers: signed,
      method: 'POST',
      url: '/query/v1/db-1/OTHER',
      originalUrl: '/query/v1/db-1/OTHER',
    };
    expect(() => resolveRequestIdentity(otherPath, true)).toThrow(UnauthorizedException);
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
  it('accepts a correctly-signed envelope', () => {
    const req = reqWith({});
    const id = resolveRequestIdentity(reqWith(signedHeaders(req)), true);
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
  ];
  it.each(tamperFields)('rejects envelope with tampered %s', (field, value) => {
    const req = reqWith({});
    const headers = signedHeaders(req, { [field]: value });
    expect(() => resolveRequestIdentity(reqWith(headers), true)).toThrow(UnauthorizedException);
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
  it.each(badSignatures)('rejects malformed/forged signature %p', (sig) => {
    const headers = signedHeaders(reqWith({}), { 'x-baas-signature': sig });
    expect(() => resolveRequestIdentity(reqWith(headers), true)).toThrow(UnauthorizedException);
  });

  it('rejects when no signing key is configured server-side', () => {
    const headers = signedHeaders(reqWith({}));
    delete process.env.INTERNAL_IDENTITY_HMAC_KEYS;
    delete process.env.INTERNAL_IDENTITY_HMAC_SECRET;
    expect(() => resolveRequestIdentity(reqWith(headers), true)).toThrow(UnauthorizedException);
  });

  it('a signature from an UNKNOWN key is rejected', () => {
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
    expect(() => resolveRequestIdentity(reqWith(headers), true)).toThrow(UnauthorizedException);
  });
});

describe('signed-envelope freshness & replay protection', () => {
  it('rejects a stale issued-at outside the skew window', () => {
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
    expect(() => resolveRequestIdentity(reqWith(headers), true)).toThrow(UnauthorizedException);
  });

  const badIat = ['not-a-number', '', 'NaN', 'Infinity', '1e999'];
  it.each(badIat)('rejects non-finite issued-at %p', (iat) => {
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
    expect(() => resolveRequestIdentity(reqWith(headers), true)).toThrow(UnauthorizedException);
  });

  it('rejects a replayed nonce (same envelope cannot be used twice)', () => {
    const req = reqWith({});
    const headers = signedHeaders(req);
    // first use succeeds
    expect(resolveRequestIdentity(reqWith(headers), true)?.tenantId).toBe('t-1');
    // identical headers again → replay
    expect(() => resolveRequestIdentity(reqWith({ ...headers }), true)).toThrow(UnauthorizedException);
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
  it.each(requiredHeaders)('rejects an envelope missing %s', (missing) => {
    const headers = signedHeaders(reqWith({}));
    delete headers[missing];
    expect(() => resolveRequestIdentity(reqWith(headers), true)).toThrow(UnauthorizedException);
  });
});

describe('raw (unsigned) identity headers — strict vs compat', () => {
  it('STRICT mode rejects raw x-user-id headers (no signature)', () => {
    process.env.IDENTITY_HEADER_MODE = 'strict';
    const req = reqWith({ 'x-user-id': 'u-1', 'x-baas-tenant-id': 't-1' });
    expect(() => resolveRequestIdentity(req, true)).toThrow(UnauthorizedException);
  });

  it('COMPAT mode accepts raw x-user-id headers (legacy path)', () => {
    process.env.IDENTITY_HEADER_MODE = 'compat';
    const req = reqWith({ 'x-user-id': 'u-1', 'x-baas-tenant-id': 't-1', 'x-user-role': 'authenticated' });
    const id = resolveRequestIdentity(req, true);
    expect(id?.userId).toBe('u-1');
    expect(id?.tenantId).toBe('t-1');
    expect(id?.authMethod).toBe('legacy-header');
  });

  it('production defaults to strict (NODE_ENV=production, no explicit mode)', () => {
    delete process.env.IDENTITY_HEADER_MODE;
    process.env.NODE_ENV = 'production';
    const req = reqWith({ 'x-user-id': 'u-1', 'x-baas-tenant-id': 't-1' });
    expect(() => resolveRequestIdentity(req, true)).toThrow(UnauthorizedException);
  });

  it('throws when identity is required but entirely absent', () => {
    process.env.IDENTITY_HEADER_MODE = 'strict';
    expect(() => resolveRequestIdentity(reqWith({}), true)).toThrow(UnauthorizedException);
  });

  it('returns undefined when identity is optional and absent (no throw)', () => {
    process.env.IDENTITY_HEADER_MODE = 'strict';
    expect(resolveRequestIdentity(reqWith({}), false)).toBeUndefined();
  });
});
