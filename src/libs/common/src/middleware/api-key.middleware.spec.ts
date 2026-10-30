import { afterEach, beforeEach, describe, expect, it } from '@jest/globals';
import { ConfigService } from '@nestjs/config';
import { createHmac, randomBytes } from 'node:crypto';
import type { Request } from 'express';
import { ApiKeyMiddleware } from './api-key.middleware';

// grobase#82: the user JWT riding alongside an app key is held to the same
// issuer list as the bearer-JWT rung; a foreign issuer leaves the key the owner.
const SECRET = randomBytes(24).toString('hex');
const ISSUER = 'https://auth.example.test/auth/v1';
const NOW = () => Math.floor(Date.now() / 1000);

interface Owner {
  userId: string;
  role: string;
}
type ResolveOwner = (req: Request, verify: { valid: boolean; key_id?: string }) => Owner;

function mint(claims: Record<string, unknown>): string {
  const enc = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const body = `${enc({ alg: 'HS256', typ: 'JWT' })}.${enc(claims)}`;
  return `${body}.${createHmac('sha256', SECRET).update(body).digest('base64url')}`;
}

function ownerFor(iss: string | undefined): Owner {
  const mw = new ApiKeyMiddleware(new ConfigService({ GOTRUE_JWT_SECRET: SECRET }));
  const token = mint({ sub: 'u1', role: 'admin', iss, iat: NOW(), exp: NOW() + 600 });
  const req = { headers: { authorization: `Bearer ${token}` } } as unknown as Request;
  const resolve = (mw as unknown as { resolveOwner: ResolveOwner }).resolveOwner.bind(mw);
  return resolve(req, { valid: true, key_id: 'k1' });
}

describe('ApiKeyMiddleware owner issuer pin (grobase#82)', () => {
  const saved = { ...process.env };
  beforeEach(() => {
    process.env.GOTRUE_JWT_ISSUER = ISSUER;
    delete process.env.JWT_ALLOW_NO_ISSUER;
  });
  afterEach(() => {
    process.env = { ...saved };
  });

  it('a token from the pinned issuer makes the user the owner', () => {
    expect(ownerFor(ISSUER)).toEqual({ userId: 'user:u1', role: 'admin' });
  });

  it('a token from another issuer leaves the app key the owner', () => {
    const fallback = { userId: 'api-key:k1', role: 'authenticated' };
    expect(ownerFor('https://evil.example.test/auth/v1')).toEqual(fallback);
    expect(ownerFor(undefined)).toEqual(fallback);
  });

  it('no issuer configured: the JWT is ignored, not trusted, and the key still works', () => {
    delete process.env.GOTRUE_JWT_ISSUER;
    expect(ownerFor(ISSUER)).toEqual({ userId: 'api-key:k1', role: 'authenticated' });
  });

  it('JWT_ALLOW_NO_ISSUER=1 keeps the pre-#82 behavior', () => {
    delete process.env.GOTRUE_JWT_ISSUER;
    process.env.JWT_ALLOW_NO_ISSUER = '1';
    expect(ownerFor('https://any.example.test')).toEqual({ userId: 'user:u1', role: 'admin' });
  });
});
