import { createHmac, timingSafeEqual } from 'node:crypto';

/** Clock skew tolerated on a user JWT's iat/nbf, in seconds. */
const JWT_CLOCK_SKEW_S = 60;

/**
 * The claims of a GoTrue user JWT this codebase acts on. `app_metadata` is
 * GoTrue's operator-writable claim bag (a user cannot set it through the auth
 * API), which is why the tenant/project binding is read from there and never
 * from a top-level claim a self-signup could influence.
 */
export interface UserJwtClaims {
  sub?: string;
  role?: string;
  iss?: string;
  exp?: unknown;
  iat?: unknown;
  nbf?: unknown;
  app_metadata?: { tenant_id?: string; project_id?: string };
}

export interface UserJwtOptions {
  /** Re-admits a token with no `exp` (M-3's escape hatch, JWT_ALLOW_NO_EXP=1). */
  allowNoExp?: boolean;
  /** When non-empty, `iss` must equal one of these (M-4). */
  issuers?: string[];
}

/**
 * Verify a GoTrue HS256 JWT against `secret` and return its claims, or null if
 * the signature/format is invalid, its time claims don't hold, or its issuer is
 * not allowed. Stdlib-only (HMAC-SHA256 + constant-time compare) — no
 * `jsonwebtoken` dependency.
 *
 * An empty `secret` always returns null: a deployment that configured no secret
 * cannot verify anything, and must not be talked into trusting an unsigned token.
 */
export function verifyUserJwt(
  token: string,
  secret: string,
  options: UserJwtOptions = {},
): UserJwtClaims | null {
  if (!secret) return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [h, p, sig] = parts;
  const expected = createHmac('sha256', secret).update(`${h}.${p}`).digest('base64url');
  const a = Buffer.from(sig);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
  try {
    const claims = JSON.parse(Buffer.from(p, 'base64url').toString('utf8')) as UserJwtClaims;
    return claimsHold(claims, options) ? claims : null;
  } catch {
    return null;
  }
}

/**
 * The bearer token of an `Authorization: Bearer <jwt>` header, or undefined when
 * the header is absent or carries another scheme. Split out so both the api-key
 * middleware and the identity resolver agree on what counts as a bearer token.
 */
export function bearerToken(authorization: string | undefined): string | undefined {
  if (!authorization || !authorization.toLowerCase().startsWith('bearer ')) return undefined;
  return authorization.slice(7).trim() || undefined;
}

/**
 * True iff the token is inside its validity window (M-3) and issued by an
 * allowed issuer (M-4): `exp` is required (a token without one would never
 * expire — `allowNoExp` opts out) and must be in the future; `iat` and `nbf`,
 * when present, must not be later than now plus JWT_CLOCK_SKEW_S, so a token
 * minted "in the future" is not accepted early.
 */
function claimsHold(claims: UserJwtClaims, options: UserJwtOptions): boolean {
  const issuers = options.issuers ?? [];
  if (issuers.length > 0 && (typeof claims.iss !== 'string' || !issuers.includes(claims.iss))) {
    return false;
  }
  const now = Date.now() / 1000;
  const exp = claims.exp;
  if (exp === undefined ? !options.allowNoExp : typeof exp !== 'number' || exp < now) return false;
  return [claims.iat, claims.nbf].every(
    (t) => t === undefined || (typeof t === 'number' && t <= now + JWT_CLOCK_SKEW_S),
  );
}
