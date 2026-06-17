import { UnauthorizedException } from '@nestjs/common';
import type { Request } from 'express';
import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import type { UserContext, VerifiedRequestIdentity } from '../interfaces/user-context.interface';

type HeaderRequest = Pick<Request, 'headers' | 'method' | 'url' | 'originalUrl'>;
type IdentityHeaderMode = 'compat' | 'strict';

interface IdentityKey {
  kid: string;
  secret: string;
}

const seenNonces = new Map<string, number>();
const DEFAULT_SKEW_MS = 30_000;

export function resolveRequestIdentity(
  req: HeaderRequest,
  requireIdentity = true,
): VerifiedRequestIdentity | undefined {
  const signedIdentity = readSignedIdentity(req);
  if (signedIdentity) return signedIdentity;

  const mode = identityHeaderMode();
  const legacyIdentity = readLegacyIdentity(req);
  if (legacyIdentity && mode === 'compat') return legacyIdentity;
  if (legacyIdentity && mode === 'strict') {
    throw new UnauthorizedException('Raw identity headers are not trusted in strict mode');
  }
  if (requireIdentity) {
    throw new UnauthorizedException('Missing verified identity envelope');
  }
  return undefined;
}

export function serviceIdentityFromHeaders(req: HeaderRequest, serviceId: string): VerifiedRequestIdentity {
  const tenantId = header(req, 'x-baas-tenant-id') ?? header(req, 'x-tenant-id');
  if (!tenantId) throw new UnauthorizedException('Service token requires tenant scope');
  const projectId = header(req, 'x-baas-project-id') ?? header(req, 'x-project-id') ?? tenantId;
  const appId = header(req, 'x-baas-app-id') ?? header(req, 'x-app-id') ?? 'internal';
  const scopes = splitList(header(req, 'x-baas-scopes') ?? header(req, 'x-service-scopes'));
  return {
    tenantId,
    projectId,
    appId,
    serviceId,
    role: 'service_role',
    roleNames: ['service_role'],
    scopes,
    authMethod: 'service-token',
  };
}

export function identityToUserContext(identity: VerifiedRequestIdentity, email = ''): UserContext {
  return {
    id: identity.userId ?? identity.tenantId,
    email,
    role: identity.role,
    tenantId: identity.tenantId,
    projectId: identity.projectId,
    appId: identity.appId,
    scopes: identity.scopes,
    authMethod: identity.authMethod,
  };
}

export function canonicalIdentityString(req: HeaderRequest, identity: VerifiedRequestIdentity, iat: string, nonce: string): string {
  return [
    `method=${(req.method ?? 'GET').toUpperCase()}`,
    `path=${req.originalUrl ?? req.url ?? '/'}`,
    `tenant=${identity.tenantId}`,
    `project=${identity.projectId}`,
    `user=${identity.userId ?? ''}`,
    `role=${identity.role}`,
    `app=${identity.appId}`,
    `iat=${iat}`,
    `nonce=${nonce}`,
    `body_sha256=${header(req, 'x-baas-body-sha256') ?? 'UNSIGNED-PAYLOAD'}`,
  ].join('\n');
}

/**
 * Mint a signed identity envelope for a server-side trust boundary that has
 * already authenticated the caller by another means (e.g. ApiKeyMiddleware after
 * verifying an X-Baas-Api-Key). It signs over the SAME canonical string + key
 * set that {@link readSignedIdentity} verifies, so strict-mode AuthGuard accepts
 * it. Returns lower-cased header names ready to assign onto `req.headers`.
 *
 * Throws if no signing key is configured (the deployment is then unauthenticated
 * by design and the caller should surface a 5xx rather than forge trust).
 */
export function signIdentityEnvelope(
  req: HeaderRequest,
  input: {
    tenantId: string;
    userId: string;
    role: string;
    appId: string;
    projectId?: string;
    scopes?: string[];
  },
): Record<string, string> {
  const keys = identityKeys();
  if (keys.length === 0) {
    throw new Error('INTERNAL_IDENTITY_HMAC_KEYS/SECRET is not configured for envelope signing');
  }
  const key = keys[0]; // sign with the primary key; verifier accepts any configured key
  const iat = String(Date.now());
  const nonce = randomUUID();
  const identity: VerifiedRequestIdentity = {
    tenantId: input.tenantId,
    projectId: input.projectId ?? input.tenantId,
    appId: input.appId,
    userId: input.userId,
    role: input.role,
    roleNames: [input.role],
    scopes: input.scopes ?? [],
    authMethod: 'kong-hmac',
  };
  const canonical = canonicalIdentityString(req, identity, iat, nonce);
  const sig = createHmac('sha256', key.secret).update(canonical).digest('hex');
  const headers: Record<string, string> = {
    'x-baas-tenant-id': identity.tenantId,
    'x-baas-project-id': identity.projectId,
    'x-baas-user-id': identity.userId ?? '',
    'x-baas-role': identity.role,
    'x-baas-app-id': identity.appId,
    'x-baas-issued-at': iat,
    'x-baas-nonce': nonce,
    'x-baas-key-id': key.kid,
    'x-baas-signature': `v1=${sig}`,
  };
  if (identity.scopes.length) headers['x-baas-scopes'] = identity.scopes.join(',');
  return headers;
}

function readSignedIdentity(req: HeaderRequest): VerifiedRequestIdentity | undefined {
  const signatureHeader = header(req, 'x-baas-signature');
  if (!signatureHeader) return undefined;

  const tenantId = requiredHeader(req, 'x-baas-tenant-id');
  const userId = requiredHeader(req, 'x-baas-user-id');
  const role = requiredHeader(req, 'x-baas-role');
  const appId = requiredHeader(req, 'x-baas-app-id');
  const iat = requiredHeader(req, 'x-baas-issued-at');
  const nonce = requiredHeader(req, 'x-baas-nonce');
  const projectId = header(req, 'x-baas-project-id') ?? tenantId;

  ensureFreshIssuedAt(iat);
  const identity: VerifiedRequestIdentity = {
    tenantId,
    projectId,
    appId,
    userId,
    role,
    roleNames: Array.from(new Set([...splitList(header(req, 'x-baas-roles')), role])),
    scopes: splitList(header(req, 'x-baas-scopes')),
    authMethod: 'kong-hmac',
  };

  const keys = identityKeys();
  if (keys.length === 0) {
    throw new UnauthorizedException('Identity signature keys are not configured');
  }
  const signature = parseSignature(signatureHeader);
  const requestedKid = header(req, 'x-baas-key-id');
  const canonical = canonicalIdentityString(req, identity, iat, nonce);
  const matchedKey = keys.find((key) => (!requestedKid || key.kid === requestedKid) && verifyHmac(key.secret, canonical, signature));
  if (!matchedKey) {
    throw new UnauthorizedException('Invalid identity envelope signature');
  }
  rememberNonce(matchedKey.kid, nonce);
  return identity;
}

function readLegacyIdentity(req: HeaderRequest): VerifiedRequestIdentity | undefined {
  const userId = header(req, 'x-user-id');
  if (!userId) return undefined;
  const tenantId = header(req, 'x-baas-tenant-id') ?? header(req, 'x-tenant-id') ?? userId;
  const projectId = header(req, 'x-baas-project-id') ?? header(req, 'x-project-id') ?? tenantId;
  const appId = header(req, 'x-baas-app-id') ?? header(req, 'x-app-id') ?? 'legacy';
  const role = header(req, 'x-user-role') ?? 'authenticated';
  return {
    tenantId,
    projectId,
    appId,
    userId,
    role,
    roleNames: [role],
    scopes: splitList(header(req, 'x-baas-scopes') ?? header(req, 'x-scopes')),
    authMethod: 'legacy-header',
  };
}

function header(req: HeaderRequest, name: string): string | undefined {
  const value = req.headers[name.toLowerCase()];
  if (Array.isArray(value)) return value[0];
  return value;
}

function requiredHeader(req: HeaderRequest, name: string): string {
  const value = header(req, name);
  if (!value) throw new UnauthorizedException(`Missing ${name} header`);
  return value;
}

function splitList(value: string | undefined): string[] {
  return (value ?? '')
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function identityHeaderMode(): IdentityHeaderMode {
  const configured = process.env['IDENTITY_HEADER_MODE']?.toLowerCase();
  if (configured === 'strict') return 'strict';
  if (configured === 'compat') return 'compat';
  return process.env['NODE_ENV'] === 'production' ? 'strict' : 'compat';
}

function identityKeys(): IdentityKey[] {
  const raw = process.env['INTERNAL_IDENTITY_HMAC_KEYS'] ?? process.env['INTERNAL_IDENTITY_HMAC_SECRET'] ?? '';
  return raw
    .split(',')
    .map((part, index) => {
      const value = part.trim();
      if (!value) return undefined;
      const separator = value.indexOf(':');
      if (separator > 0) {
        return { kid: value.slice(0, separator), secret: value.slice(separator + 1) };
      }
      return { kid: `default-${index}`, secret: value };
    })
    .filter((key): key is IdentityKey => Boolean(key?.secret));
}

function parseSignature(raw: string): string {
  const match = /^v1=([0-9a-fA-F]{64})$/.exec(raw);
  if (!match) throw new UnauthorizedException('Malformed identity signature');
  return match[1].toLowerCase();
}

function verifyHmac(secret: string, canonical: string, expectedHex: string): boolean {
  const actual = createHmac('sha256', secret).update(canonical).digest('hex');
  const actualBuffer = Buffer.from(actual, 'hex');
  const expectedBuffer = Buffer.from(expectedHex, 'hex');
  return actualBuffer.length === expectedBuffer.length && timingSafeEqual(actualBuffer, expectedBuffer);
}

function ensureFreshIssuedAt(iat: string): void {
  const issuedAt = Number(iat);
  const maxSkew = Number(process.env['INTERNAL_IDENTITY_MAX_SKEW_MS'] ?? DEFAULT_SKEW_MS);
  if (!Number.isFinite(issuedAt) || Math.abs(Date.now() - issuedAt) > maxSkew) {
    throw new UnauthorizedException('Expired identity envelope');
  }
}

function rememberNonce(kid: string, nonce: string): void {
  const now = Date.now();
  const maxSkew = Number(process.env['INTERNAL_IDENTITY_MAX_SKEW_MS'] ?? DEFAULT_SKEW_MS);
  for (const [key, seenAt] of seenNonces.entries()) {
    if (now - seenAt > maxSkew) seenNonces.delete(key);
  }
  const nonceKey = `${kid}:${nonce}`;
  if (seenNonces.has(nonceKey)) {
    throw new UnauthorizedException('Replayed identity envelope');
  }
  seenNonces.set(nonceKey, now);
}