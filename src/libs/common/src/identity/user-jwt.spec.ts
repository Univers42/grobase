import { describe, expect, it } from '@jest/globals';
import { createHmac, randomBytes } from 'node:crypto';
import { bearerToken, verifyUserJwt, type UserJwtOptions } from './user-jwt';

// These cases moved here with the verifier itself (H-19): the primitive used to
// be a private method on ApiKeyMiddleware, reached by casting, and is now the
// shared identity library both the api-key route and the bearer-JWT identity
// rung call. The M-3 time-claim contract below is unchanged; the issuer cases
// (M-4) are new surface the extraction exposes.
const SECRET = randomBytes(24).toString('hex');
const NOW = () => Math.floor(Date.now() / 1000);

type Claims = Record<string, unknown>;

/** Mint an HS256 JWT over `claims` with SECRET, the way GoTrue signs one. */
function mint(claims: Claims, secret: string = SECRET): string {
  const enc = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const body = `${enc({ alg: 'HS256', typ: 'JWT' })}.${enc(claims)}`;
  return `${body}.${createHmac('sha256', secret).update(body).digest('base64url')}`;
}

function verify(token: string, options: UserJwtOptions = {}) {
  return verifyUserJwt(token, SECRET, options);
}

describe('verifyUserJwt time claims (M-3)', () => {
  it('accepts a signed token with a future exp and a present iat', () => {
    expect(verify(mint({ sub: 'u1', iat: NOW(), exp: NOW() + 600 }))?.sub).toBe('u1');
  });

  it('rejects an expired token', () => {
    expect(verify(mint({ sub: 'u1', iat: NOW() - 7200, exp: NOW() - 3600 }))).toBeNull();
  });

  it('rejects a token with no exp — it would never expire', () => {
    expect(verify(mint({ sub: 'u1', iat: NOW() }))).toBeNull();
  });

  it('rejects a token issued in the future beyond the clock skew', () => {
    expect(verify(mint({ sub: 'u1', iat: NOW() + 3600, exp: NOW() + 7200 }))).toBeNull();
  });

  it('rejects a token that is not yet valid (nbf in the future)', () => {
    expect(
      verify(mint({ sub: 'u1', iat: NOW(), nbf: NOW() + 3600, exp: NOW() + 7200 })),
    ).toBeNull();
  });

  it('tolerates a small clock skew on iat', () => {
    expect(verify(mint({ sub: 'u1', iat: NOW() + 20, exp: NOW() + 600 }))?.sub).toBe('u1');
  });

  it('allowNoExp restores the old acceptance of a non-expiring token (opt-out)', () => {
    expect(verify(mint({ sub: 'u1', iat: NOW() }), { allowNoExp: true })?.sub).toBe('u1');
  });

  it('rejects a bad signature regardless of claims', () => {
    const t = mint({ sub: 'u1', iat: NOW(), exp: NOW() + 600 });
    expect(verify(`${t.slice(0, -2)}xx`)).toBeNull();
  });

  it('rejects a token signed with another secret', () => {
    expect(
      verify(mint({ sub: 'u1', exp: NOW() + 600 }, randomBytes(24).toString('hex'))),
    ).toBeNull();
  });

  it('rejects everything when no secret is configured', () => {
    expect(verifyUserJwt(mint({ sub: 'u1', exp: NOW() + 600 }), '')).toBeNull();
  });
});

describe('verifyUserJwt issuer pinning (M-4)', () => {
  const issuers = ['https://localhost:8443/auth/v1'];

  it('accepts a token from a listed issuer', () => {
    const t = mint({ sub: 'u1', exp: NOW() + 600, iss: issuers[0] });
    expect(verify(t, { issuers })?.sub).toBe('u1');
  });

  it('rejects a token from an unlisted issuer', () => {
    const t = mint({ sub: 'u1', exp: NOW() + 600, iss: 'https://evil.example/auth/v1' });
    expect(verify(t, { issuers })).toBeNull();
  });

  it('rejects a token with no iss at all once issuers are pinned', () => {
    expect(verify(mint({ sub: 'u1', exp: NOW() + 600 }), { issuers })).toBeNull();
  });

  it('ignores iss entirely when no issuers are pinned (default)', () => {
    const t = mint({ sub: 'u1', exp: NOW() + 600, iss: 'https://anything.example' });
    expect(verify(t)?.sub).toBe('u1');
  });
});

describe('bearerToken', () => {
  const cases: Array<[string, string | undefined, string | undefined]> = [
    ['a bearer token', 'Bearer abc.def.ghi', 'abc.def.ghi'],
    ['a lower-cased scheme', 'bearer abc', 'abc'],
    ['surrounding whitespace', 'Bearer   abc  ', 'abc'],
    ['another scheme', 'Basic abc', undefined],
    ['an empty bearer', 'Bearer   ', undefined],
    ['an absent header', undefined, undefined],
  ];
  it.each(cases)('handles %s', (_name, header, expected) => {
    expect(bearerToken(header)).toBe(expected);
  });
});
