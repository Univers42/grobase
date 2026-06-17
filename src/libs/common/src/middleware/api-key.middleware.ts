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
import { signIdentityEnvelope } from '../identity/request-identity';
import { serviceAuthHeaders } from '../security/service-auth';

interface VerifyResponse {
  valid: boolean;
  tenant_id?: string;
  key_id?: string;
  scopes?: string[];
  reason?: string;
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

  constructor(config: ConfigService) {
    // internal/loopback only — not externally exposed
    const scheme = 'http';
    const tenantControlUrl = config.get<string>('TENANT_CONTROL_URL', `${scheme}://tenant-control:3022`);
    this.verifyUrl = tenantControlUrl + '/v1/keys/verify';
    this.serviceToken = config.get<string>('INTERNAL_SERVICE_TOKEN', '');
    this.timeoutMs = Number(config.get('API_KEY_VERIFY_TIMEOUT_MS', '2000'));
    this.cacheTtlMs = Number(config.get('API_KEY_VERIFY_CACHE_TTL_MS', '30000'));
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
      res.status(503).json({ error: 'auth_verify_unavailable', message: 'tenant-control unreachable' });
      return;
    }

    if (!verify.valid) {
      res.status(401).json({ error: 'invalid_api_key', reason: verify.reason ?? 'invalid' });
      return;
    }

    // Mint a signed identity envelope so strict-mode AuthGuard accepts the
    // api-key caller (raw identity headers are rejected in strict mode). It is
    // self-signed over the same canonical string + key set the verifier uses.
    try {
      const envelope = signIdentityEnvelope(req, {
        tenantId: verify.tenant_id!,
        userId: `api-key:${verify.key_id ?? ''}`,
        role: 'authenticated',
        appId: 'api-key',
        scopes: verify.scopes ?? [],
      });
      for (const [name, value] of Object.entries(envelope)) {
        req.headers[name] = value;
      }
    } catch (err) {
      this.logger.error(`identity envelope signing failed: ${(err as Error).message}`);
      res.status(500).json({ error: 'identity_unavailable', message: 'identity signing key not configured' });
      return;
    }
    next();
  }

  private async verify(key: string): Promise<VerifyResponse> {
    const cached = this.cache.get(key);
    const now = Date.now();
    if (cached && cached.exp > now) return cached.res;

    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), this.timeoutMs);
    try {
      const payload = JSON.stringify({ key });
      const resp = await fetch(this.verifyUrl, {
        method: 'POST',
        signal: ctrl.signal,
        headers: {
          'Content-Type': 'application/json',
          // hmac mode signs the exact payload string sent below (audit O1).
          ...serviceAuthHeaders(this.serviceToken, 'POST', '/v1/keys/verify', payload),
        },
        body: payload,
      });
      // Both 200 (valid) and 401 (invalid but well-formed) return JSON.
      if (resp.status !== 200 && resp.status !== 401) {
        throw new Error(`unexpected status ${resp.status}`);
      }
      const body = (await resp.json()) as VerifyResponse;
      this.cache.set(key, { exp: now + this.cacheTtlMs, res: body });
      this.pruneCache(now);
      return body;
    } finally {
      clearTimeout(t);
    }
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
