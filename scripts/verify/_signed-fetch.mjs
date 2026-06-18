// File: scripts/verify/_signed-fetch.mjs
// Helper for verify scripts running inside NestJS service containers.
// Produces an HMAC-signed identity envelope that satisfies
// libs/common/src/identity/request-identity.ts in strict mode.
//
// Embedded into bash heredocs by `make baas-verify-mX --live` flows.
// Reads the same INTERNAL_IDENTITY_HMAC_SECRET env var that the NestJS
// services consume via env_file: [.env].
import { createHmac, randomUUID } from 'node:crypto';

const SECRET =
  process.env.INTERNAL_IDENTITY_HMAC_SECRET ||
  (process.env.INTERNAL_IDENTITY_HMAC_KEYS || '').split(',')[0]?.split(':').slice(-1)[0] ||
  '';

if (!SECRET) {
  throw new Error('INTERNAL_IDENTITY_HMAC_SECRET (or INTERNAL_IDENTITY_HMAC_KEYS) must be set for signed verify requests');
}

export function signedHeaders(method, url, identity = {}) {
  const u = new URL(url);
  const path = (u.pathname || '/') + (u.search || '');
  const iat = String(Date.now());
  const nonce = randomUUID();
  const userId = identity.userId || identity.id || '';
  const tenantId = identity.tenantId || userId;
  const projectId = identity.projectId || tenantId;
  const role = identity.role || 'authenticated';
  const appId = identity.appId || 'verify';
  const canonical = [
    `method=${method.toUpperCase()}`,
    `path=${path}`,
    `tenant=${tenantId}`,
    `project=${projectId}`,
    `user=${userId}`,
    `role=${role}`,
    `app=${appId}`,
    `iat=${iat}`,
    `nonce=${nonce}`,
    `body_sha256=UNSIGNED-PAYLOAD`,
  ].join('\n');
  const sig = createHmac('sha256', SECRET).update(canonical).digest('hex');
  return {
    'X-Baas-Tenant-Id': tenantId,
    'X-Baas-Project-Id': projectId,
    'X-Baas-User-Id': userId,
    'X-Baas-Role': role,
    'X-Baas-App-Id': appId,
    'X-Baas-Issued-At': iat,
    'X-Baas-Nonce': nonce,
    'X-Baas-Signature': `v1=${sig}`,
  };
}

export async function signedFetch(url, options = {}, identity = {}) {
  const method = (options.method || 'GET').toUpperCase();
  const signed = signedHeaders(method, url, identity);
  return fetch(url, {
    ...options,
    method,
    headers: { ...options.headers, ...signed },
  });
}
