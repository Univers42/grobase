import { describe, expect, it } from '@jest/globals';
import type { ConfigService } from '@nestjs/config';
import { createHmac } from 'node:crypto';
import { ApiKeyMiddleware } from './api-key.middleware';

const SECRET = 'jwt-test-secret-at-least-32-characters-long';
const NOW = () => Math.floor(Date.now() / 1000);

type Claims = Record<string, unknown>;
type JwtVerifier = { verifyUserJwt(token: string): Claims | null };

/** Mint an HS256 JWT over `claims` with SECRET, the way GoTrue signs one. */
function mint(claims: Claims): string {
  const enc = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const body = `${enc({ alg: 'HS256', typ: 'JWT' })}.${enc(claims)}`;
  return `${body}.${createHmac('sha256', SECRET).update(body).digest('base64url')}`;
}

/** The middleware's private JWT verifier, built from a config map. */
function verifier(env: Record<string, string> = {}): JwtVerifier {
  const all: Record<string, string> = { GOTRUE_JWT_SECRET: SECRET, ...env };
  const config = { get: (k: string, d?: unknown) => all[k] ?? d } as unknown as ConfigService;
  return new ApiKeyMiddleware(config) as unknown as JwtVerifier;
}

describe('ApiKeyMiddleware user-JWT verification (M-3)', () => {
  it('accepts a signed token with a future exp and a present iat', () => {
    expect(verifier().verifyUserJwt(mint({ sub: 'u1', iat: NOW(), exp: NOW() + 600 }))?.sub).toBe(
      'u1',
    );
  });

  it('rejects an expired token', () => {
    expect(
      verifier().verifyUserJwt(mint({ sub: 'u1', iat: NOW() - 7200, exp: NOW() - 3600 })),
    ).toBeNull();
  });

  it('rejects a token with no exp — it would never expire', () => {
    expect(verifier().verifyUserJwt(mint({ sub: 'u1', iat: NOW() }))).toBeNull();
  });

  it('rejects a token issued in the future beyond the clock skew', () => {
    expect(
      verifier().verifyUserJwt(mint({ sub: 'u1', iat: NOW() + 3600, exp: NOW() + 7200 })),
    ).toBeNull();
  });

  it('rejects a token that is not yet valid (nbf in the future)', () => {
    expect(
      verifier().verifyUserJwt(
        mint({ sub: 'u1', iat: NOW(), nbf: NOW() + 3600, exp: NOW() + 7200 }),
      ),
    ).toBeNull();
  });

  it('tolerates a small clock skew on iat', () => {
    expect(
      verifier().verifyUserJwt(mint({ sub: 'u1', iat: NOW() + 20, exp: NOW() + 600 }))?.sub,
    ).toBe('u1');
  });

  it('JWT_ALLOW_NO_EXP=1 restores the old acceptance of a non-expiring token (opt-out)', () => {
    expect(
      verifier({ JWT_ALLOW_NO_EXP: '1' }).verifyUserJwt(mint({ sub: 'u1', iat: NOW() }))?.sub,
    ).toBe('u1');
  });

  it('rejects a bad signature regardless of claims', () => {
    const t = mint({ sub: 'u1', iat: NOW(), exp: NOW() + 600 });
    expect(verifier().verifyUserJwt(`${t.slice(0, -2)}xx`)).toBeNull();
  });
});
