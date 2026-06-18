// API key auth middleware.
//
// Exchanges an `X-Baas-Api-Key` header for tenant headers by calling
// tenant-control's /v1/keys/verify endpoint. On success, sets:
//   X-Baas-Tenant-Id   = <verified slug>
//   X-Baas-User-Id     = api-key:<key uuid>  (synthetic actor id)
//   X-Baas-Scopes      = comma-joined scopes
// Downstream code (the existing identity-resolution pipeline + rust proxy
// HMAC signing) treats those headers identically to a JWT-derived envelope.
//
// Behaviour:
//   - If X-Baas-Tenant-Id is ALREADY set on the request, the middleware is a
//     no-op (signed envelope from gateway wins).
//   - If X-Baas-Api-Key is absent, also a no-op (let JWT / other auth run).
//   - If the key is invalid → 401 with reason.
//   - Network failure → 503 (don't 5xx; the gateway can retry).
//
// Config:
//   TENANT_CONTROL_URL              http://tenant-control:3022
//   INTERNAL_SERVICE_TOKEN          shared with tenant-control
//   API_KEY_VERIFY_TIMEOUT_MS       default 2000

import { Injectable, NestMiddleware, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Request, Response, NextFunction } from 'express';
import { createHmac, timingSafeEqual } from 'node:crypto';
import * as http from 'node:http';
import { signIdentityEnvelope } from '../identity/request-identity';
import { serviceAuthHeaders } from '../security/service-auth';

interface VerifyResponse {
  valid: boolean;
  tenant_id?: string;
  key_id?: string;
  scopes?: string[];
  reason?: string;
}

/** The owner identity an app key resolves to: either the app key itself
 *  (`api-key:<keyId>`) or — when a verified GoTrue user JWT rides alongside —
 *  the user (`user:<sub>`), carrying the JWT's role for the F2 admin bypass. */
interface OwnerIdentity {
  userId: string;
  role: string;
}

@Injectable()
export class ApiKeyMiddleware implements NestMiddleware {
  private readonly logger = new Logger(ApiKeyMiddleware.name);
  private readonly verifyUrl: string;
  private readonly serviceToken: string;
  private readonly timeoutMs: number;
  // TTL cache so repeat requests in a burst skip the network roundtrip. The TTL
  // is the revocation-staleness window; env-configurable (default 30 s = the
  // prior hard-coded value, so behaviour is unchanged unless an operator opts in
  // to a longer cache to absorb sustained read bursts).
  private readonly cache = new Map<string, { exp: number; res: VerifyResponse }>();
  private readonly cacheTtlMs: number;
  // Dedicated non-pooling agent for the verify call. Global `fetch` (undici)
  // reuses keep-alive sockets to tenant-control; a fresh connection per call
  // cannot reuse a half-open/stale socket. Verify is cached, so the extra
  // handshake is amortized away. (Hardening against stale-keepalive wedges; not
  // a cure for the separate sparse-verify event-loop stall under heavy edge load.)
  private readonly agent: http.Agent;
  // GoTrue HS256 secret — verifies a user Bearer JWT for per-user owner-scoping.
  // Empty (unset) → the user-JWT branch is inert and the app key stays the owner.
  private readonly jwtSecret: string;

  constructor(config: ConfigService) {
    // internal/loopback only — not externally exposed
    const scheme = 'http';
    const tenantControlUrl = config.get<string>(
      'TENANT_CONTROL_URL',
      `${scheme}://tenant-control:3022`,
    );
    this.verifyUrl = tenantControlUrl + '/v1/keys/verify';
    this.serviceToken = config.get<string>('INTERNAL_SERVICE_TOKEN', '');
    this.timeoutMs = Number(config.get('API_KEY_VERIFY_TIMEOUT_MS', '2000'));
    this.cacheTtlMs = Number(config.get('API_KEY_VERIFY_CACHE_TTL_MS', '30000'));
    this.jwtSecret = config.get<string>('GOTRUE_JWT_SECRET', '') || config.get<string>('JWT_SECRET', '');
    this.agent = new http.Agent({ keepAlive: false });
  }

  async use(req: Request, res: Response, next: NextFunction): Promise<void> {
    const apiKey = pickHeader(req, 'x-baas-api-key') ?? pickHeader(req, 'apikey');
    if (!apiKey) return next();

    // If the caller already provided a verified tenant envelope (signed
    // gateway), respect that and skip key verification.
    if (pickHeader(req, 'x-baas-tenant-id')) return next();

    let verify: VerifyResponse;
    try {
      verify = await this.verify(apiKey);
    } catch (err) {
      this.logger.warn(`api-key verify failed: ${(err as Error).message}`);
      res
        .status(503)
        .json({ error: 'auth_verify_unavailable', message: 'tenant-control unreachable' });
      return;
    }

    if (!verify.valid) {
      res.status(401).json({ error: 'invalid_api_key', reason: verify.reason ?? 'invalid' });
      return;
    }

    // Per-user owner-scoping: when a verified GoTrue user JWT rides alongside
    // the app key, the OWNER is the user (`user:<sub>`) and the JWT's role flows
    // through (so an `admin` JWT triggers the data plane's F2 bypass). Absent or
    // unverifiable JWT → the app key is the owner = the pre-existing behavior.
    const owner = this.resolveOwner(req, verify);

    // Mint a signed identity envelope so strict-mode AuthGuard accepts the
    // api-key caller (raw identity headers are rejected in strict mode). It is
    // self-signed over the same canonical string + key set the verifier uses.
    try {
      const envelope = signIdentityEnvelope(req, {
        tenantId: verify.tenant_id!,
        userId: owner.userId,
        role: owner.role,
        appId: 'api-key',
        scopes: verify.scopes ?? [],
      });
      for (const [name, value] of Object.entries(envelope)) {
        req.headers[name] = value;
      }
    } catch (err) {
      this.logger.error(`identity envelope signing failed: ${(err as Error).message}`);
      res
        .status(500)
        .json({ error: 'identity_unavailable', message: 'identity signing key not configured' });
      return;
    }
    next();
  }

  /**
   * Resolve a cleartext api-key to its verification result, caching for
   * cacheTtlMs. hmac mode signs the exact payload string sent (audit O1). Both
   * 200 (valid) and 401 (invalid-but-well-formed) carry a JSON body; any other
   * status throws (caller maps to 503).
   */
  private async verify(key: string): Promise<VerifyResponse> {
    const cached = this.cache.get(key);
    const now = Date.now();
    if (cached && cached.exp > now) return cached.res;

    const payload = JSON.stringify({ key });
    const headers = {
      'Content-Type': 'application/json',
      ...serviceAuthHeaders(this.serviceToken, 'POST', '/v1/keys/verify', payload),
    };
    const { status, raw } = await this.postVerify(payload, headers);
    if (status !== 200 && status !== 401) {
      throw new Error(`unexpected status ${status}`);
    }
    const body = JSON.parse(raw) as VerifyResponse;
    this.cache.set(key, { exp: now + this.cacheTtlMs, res: body });
    this.pruneCache(now);
    return body;
  }

  /**
   * Resolve the OWNER for the request. A verified GoTrue user Bearer JWT makes
   * the user the owner (`user:<sub>`) and carries its role (so `role:admin`
   * reaches the data plane's F2 bypass); otherwise the app key is the owner
   * (`api-key:<keyId>`, role `authenticated`) — the pre-existing behavior.
   */
  private resolveOwner(req: Request, verify: VerifyResponse): OwnerIdentity {
    const fallback: OwnerIdentity = {
      userId: `api-key:${verify.key_id ?? ''}`,
      role: 'authenticated',
    };
    const auth = pickHeader(req, 'authorization');
    if (!auth || !auth.toLowerCase().startsWith('bearer ') || !this.jwtSecret) return fallback;
    const claims = this.verifyUserJwt(auth.slice(7).trim());
    if (!claims?.sub) return fallback;
    return { userId: `user:${claims.sub}`, role: claims.role || 'authenticated' };
  }

  /**
   * Verify a GoTrue HS256 JWT against jwtSecret and return its claims, or null
   * if the signature/format is invalid or the token is expired. Stdlib-only
   * (HMAC-SHA256 + constant-time compare) — no jsonwebtoken dependency.
   */
  private verifyUserJwt(token: string): { sub?: string; role?: string } | null {
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const [h, p, sig] = parts;
    const expected = createHmac('sha256', this.jwtSecret).update(`${h}.${p}`).digest('base64url');
    const a = Buffer.from(sig);
    const b = Buffer.from(expected);
    if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
    try {
      const claims = JSON.parse(Buffer.from(p, 'base64url').toString('utf8'));
      if (typeof claims.exp === 'number' && claims.exp * 1000 < Date.now()) return null;
      return claims;
    } catch {
      return null;
    }
  }

  /**
   * POST the verify payload over the dedicated non-pooling agent, resolving
   * {status, raw-body}. timeoutMs caps the socket; a timeout/error rejects so
   * the caller returns 503. Fresh connection each call — no stale keep-alive.
   */
  private postVerify(
    payload: string,
    headers: Record<string, string>,
  ): Promise<{ status: number; raw: string }> {
    const url = new URL(this.verifyUrl);
    return new Promise((resolve, reject) => {
      const req = http.request(
        {
          hostname: url.hostname,
          port: url.port,
          path: url.pathname,
          method: 'POST',
          agent: this.agent,
          timeout: this.timeoutMs,
          headers: { ...headers, 'Content-Length': Buffer.byteLength(payload) },
        },
        (res) => {
          let raw = '';
          res.setEncoding('utf8');
          res.on('data', (c) => (raw += c));
          res.on('end', () => resolve({ status: res.statusCode ?? 0, raw }));
        },
      );
      req.on('timeout', () => req.destroy(new Error('This operation was aborted')));
      req.on('error', reject);
      req.end(payload);
    });
  }

  private pruneCache(now: number): void {
    if (this.cache.size < 256) return;
    for (const [k, v] of this.cache.entries()) {
      if (v.exp <= now) this.cache.delete(k);
    }
  }
}

function pickHeader(req: Request, name: string): string | undefined {
  const v = req.headers[name];
  if (Array.isArray(v)) return v[0];
  return v;
}
