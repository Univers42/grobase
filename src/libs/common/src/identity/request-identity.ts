import { UnauthorizedException } from '@nestjs/common';
import type { Request } from 'express';
import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import type { UserContext, VerifiedRequestIdentity } from '../interfaces/user-context.interface';
import { defaultNonceStore, type NonceStore } from './nonce-store';
import { bearerToken, verifyUserJwt } from './user-jwt';

type HeaderRequest = Pick<Request, 'headers' | 'method' | 'url' | 'originalUrl'>;
type IdentityHeaderMode = 'compat' | 'strict';

interface IdentityKey {
  kid: string;
  secret: string;
}

const DEFAULT_SKEW_MS = 30_000;

/**
 * Resolves the caller's verified identity, in descending order of trust: a
 * signed HMAC envelope, then (compat mode only) legacy raw headers, then a
 * bearer GoTrue JWT. `nonceStore` is the replay cache — defaults to the
 * process-wide store selected by IDENTITY_NONCE_STORE. Async: callers MUST await
 * it, since an un-awaited Promise is truthy and would pass any guard.
 *
 * The legacy rung is tried BEFORE the JWT rung on purpose (H-19): in compat mode
 * a request carrying both resolves exactly as it did before the JWT path
 * existed, so the live baseline is byte-identical. In strict mode legacy headers
 * resolve to nothing, so the JWT is what the request is judged on and the raw
 * headers Kong sets are simply ignored rather than fatal.
 */
export async function resolveRequestIdentity(
  req: HeaderRequest,
  requireIdentity = true,
  nonceStore: NonceStore = defaultNonceStore(),
): Promise<VerifiedRequestIdentity | undefined> {
  const signedIdentity = await readSignedIdentity(req, nonceStore);
  if (signedIdentity) return signedIdentity;

  const mode = identityHeaderMode();
  const legacyIdentity = readLegacyIdentity(req);
  if (legacyIdentity && mode === 'compat') return legacyIdentity;

  const jwtIdentity = readBearerJwtIdentity(req, mode);
  if (jwtIdentity) return jwtIdentity;

  if (legacyIdentity && mode === 'strict') {
    throw new UnauthorizedException('Raw identity headers are not trusted in strict mode');
  }
  if (requireIdentity) {
    throw new UnauthorizedException('Missing verified identity envelope');
  }
  return undefined;
}

export function serviceIdentityFromHeaders(
  req: HeaderRequest,
  serviceId: string,
): VerifiedRequestIdentity {
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

/**
 * The signed message of an identity envelope: every field a downstream authorizer
 * may act on. `roles` and `scopes` are part of it because they are authorization
 * inputs, not decoration — `roleNames` reaches RolesGuard and the ABAC PDP, and
 * `scopes` reaches the api-key admin short-circuit in query.service. Leaving
 * either unsigned let a caller holding a valid api key bolt `X-Baas-Roles:
 * service_role` onto the envelope ApiKeyMiddleware had just minted for them.
 *
 * Both lists are deduped and sorted so the signature binds the SET, independent
 * of header ordering, and so signer and verifier derive the same string from the
 * same grant. `roles` is the union of `roleNames` and `role`, matching how
 * {@link readSignedIdentity} rebuilds it from headers.
 */
export function canonicalIdentityString(
  req: HeaderRequest,
  identity: VerifiedRequestIdentity,
  iat: string,
  nonce: string,
): string {
  return [
    `method=${(req.method ?? 'GET').toUpperCase()}`,
    `path=${req.originalUrl ?? req.url ?? '/'}`,
    `tenant=${identity.tenantId}`,
    `project=${identity.projectId}`,
    `user=${identity.userId ?? ''}`,
    `role=${identity.role}`,
    `roles=${canonicalList([...(identity.roleNames ?? []), identity.role])}`,
    `scopes=${canonicalList(identity.scopes ?? [])}`,
    `app=${identity.appId}`,
    `iat=${iat}`,
    `nonce=${nonce}`,
    `body_sha256=${header(req, 'x-baas-body-sha256') ?? 'UNSIGNED-PAYLOAD'}`,
  ].join('\n');
}

/**
 * Normalises a grant list into its canonical signed form: deduped, sorted,
 * comma-joined. Order-insensitive by design — a reordered header is the same
 * grant, while an ADDED or removed entry is a different one.
 */
function canonicalList(values: string[]): string {
  return Array.from(new Set(values)).sort().join(',');
}

/**
 * Mint a signed identity envelope for a server-side trust boundary that has
 * already authenticated the caller by another means (e.g. ApiKeyMiddleware after
 * verifying an X-Baas-Api-Key). It signs over the SAME canonical string + key
 * set that {@link readSignedIdentity} verifies, so strict-mode AuthGuard accepts
 * it. Returns lower-cased header names ready to assign onto `req.headers`.
 *
 * EVERY header the verifier reads is returned, `x-baas-roles` and `x-baas-scopes`
 * included even when empty: the caller assigns these onto the request the client
 * controlled, so an omitted key would leave a client-supplied copy in place.
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
    'x-baas-roles': identity.roleNames.join(','),
    'x-baas-scopes': identity.scopes.join(','),
    'x-baas-signature': `v1=${sig}`,
  };
  return headers;
}

async function readSignedIdentity(
  req: HeaderRequest,
  nonceStore: NonceStore,
): Promise<VerifiedRequestIdentity | undefined> {
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
  const matchedKey = keys.find(
    (key) =>
      (!requestedKid || key.kid === requestedKid) && verifyHmac(key.secret, canonical, signature),
  );
  if (!matchedKey) {
    throw new UnauthorizedException('Invalid identity envelope signature');
  }
  await rememberNonce(nonceStore, matchedKey.kid, nonce);
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

/**
 * The identity of a caller presenting an `Authorization: Bearer <GoTrue JWT>`,
 * or undefined when there is no such token, no secret to verify it with, or the
 * token does not hold up. This is the signer H-19 was missing: before it, only
 * the api-key route could produce an identity strict mode accepts, so flipping
 * strict would have 401'd every JWT caller.
 *
 * Active in strict mode unconditionally (strict without it rejects everything),
 * and in compat mode only under IDENTITY_JWT_BEARER_ENABLED=1, so the default
 * deployment keeps its exact current accept set while the path is exercised.
 *
 * It yields the same `userId` (the raw `sub`) and `appId` (`legacy`) that
 * readLegacyIdentity derives from the X-User-* headers Kong sets for this same
 * token. Storage object keys and mongo `owner_id` are built from `userId`, so
 * any other shape would hide every row a user already owns once strict is on.
 *
 * Trust boundaries this path holds:
 *   - tenant/project come from `app_metadata`, which GoTrue does not let a user
 *     write, falling back to `sub` (a user is their own tenant) — never from a
 *     client header.
 *   - `roleNames`/`scopes` are derived from the token alone. The raw
 *     x-baas-roles / x-baas-scopes headers are authorization inputs the client
 *     controls and are deliberately not read here (see N-12).
 *   - `sub` is required, which is also what rejects the anon and service_role
 *     project keys: they are subject-less tokens signed with the same secret.
 *   - the issuer must be pinned, for the reason `tenants.RequireIssuer` gives on
 *     the Go side: `JWT_SECRET` is shared, so other HS256 tokens exist that are
 *     not user sessions. A cross-app realtime token
 *     (`appchannels/mint.go:realtimeClaims`) carries a TENANT SLUG as its `sub`
 *     and would otherwise resolve here to a full identity for that tenant.
 */
function readBearerJwtIdentity(
  req: HeaderRequest,
  mode: IdentityHeaderMode,
): VerifiedRequestIdentity | undefined {
  const token = bearerToken(header(req, 'authorization'));
  if (!token) return undefined;
  if (mode !== 'strict' && !envFlag('IDENTITY_JWT_BEARER_ENABLED')) return undefined;
  const claims = verifyUserJwt(token, userJwtSecret(), {
    allowNoExp: envFlag('JWT_ALLOW_NO_EXP'),
    issuers: requiredIssuers(),
  });
  if (!claims?.sub) return undefined;
  const role = claims.role || 'authenticated';
  const tenantId = claims.app_metadata?.tenant_id || claims.sub;
  return {
    tenantId,
    projectId: claims.app_metadata?.project_id || tenantId,
    appId: 'legacy',
    userId: claims.sub,
    role,
    roleNames: [role],
    scopes: [],
    authMethod: 'jwt',
  };
}

function userJwtSecret(): string {
  return process.env['GOTRUE_JWT_SECRET'] || process.env['JWT_SECRET'] || '';
}

/**
 * The issuers a bearer user JWT may carry, refusing to run without one — the TS
 * half of `tenants.RequireIssuer` (Go) and of realtime's issuer allow-list
 * (m201). Compose defaults GOTRUE_JWT_ISSUER to API_EXTERNAL_URL on every
 * service that verifies a user token; JWT_ALLOW_NO_ISSUER=1 is the named
 * escape hatch, and the only way to accept a token on `iss` alone.
 *
 * Throws rather than returning empty so a misconfigured deployment says which
 * variable is missing instead of 401-ing every JWT caller anonymously.
 */
function requiredIssuers(): string[] {
  const issuers = splitList(process.env['GOTRUE_JWT_ISSUER']);
  if (issuers.length > 0 || envFlag('JWT_ALLOW_NO_ISSUER')) return issuers;
  throw new UnauthorizedException(
    'GOTRUE_JWT_ISSUER is empty: set it (compose defaults it to API_EXTERNAL_URL) or JWT_ALLOW_NO_ISSUER=1 to run without issuer verification',
  );
}

function envFlag(name: string): boolean {
  return /^(1|true)$/i.test(String(process.env[name] ?? '').trim());
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
  const raw =
    process.env['INTERNAL_IDENTITY_HMAC_KEYS'] ??
    process.env['INTERNAL_IDENTITY_HMAC_SECRET'] ??
    '';
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
  return (
    actualBuffer.length === expectedBuffer.length && timingSafeEqual(actualBuffer, expectedBuffer)
  );
}

function maxSkewMs(): number {
  const raw = Number(process.env['INTERNAL_IDENTITY_MAX_SKEW_MS'] ?? DEFAULT_SKEW_MS);
  return Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_SKEW_MS;
}

function ensureFreshIssuedAt(iat: string): void {
  const issuedAt = Number(iat);
  if (!Number.isFinite(issuedAt) || Math.abs(Date.now() - issuedAt) > maxSkewMs()) {
    throw new UnauthorizedException('Expired identity envelope');
  }
}

/**
 * Rejects a nonce the store has already seen. It is kept for 2x the skew window:
 * an envelope issued up to `skew` in the future stays fresh until iat + skew.
 */
async function rememberNonce(store: NonceStore, kid: string, nonce: string): Promise<void> {
  if (!(await store.remember(kid, nonce, 2 * maxSkewMs()))) {
    throw new UnauthorizedException('Replayed identity envelope');
  }
}
