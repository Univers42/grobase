import type { VerifiedRequestIdentity } from '@mini-baas/common';

export type ApiKeyScope = 'read' | 'write' | 'admin';

/**
 * The app key's scopes when the caller is an app-key caller Kong signed for —
 * the key itself (`api-key:<id>`) or a user riding it (`user:<sub>`, appId
 * `api-key`) — and `undefined` for every other caller.
 *
 * Only the kong-hmac envelope is trusted: a legacy-header caller sets
 * X-User-Id / X-App-Id / X-Scopes itself, and Kong does not clear the last two.
 */
export function apiKeyScopes(
  identity: VerifiedRequestIdentity | undefined,
): ReadonlySet<string> | undefined {
  if (identity?.authMethod !== 'kong-hmac') return undefined;
  const isApiKeyOwner = identity.userId?.startsWith('api-key:');
  const isUserUnderApiKey = identity.userId?.startsWith('user:') && identity.appId === 'api-key';
  if (!isApiKeyOwner && !isUserUnderApiKey) return undefined;
  return new Set(identity.scopes ?? []);
}

/** `admin` satisfies every scope, as the data plane's `require_scope` does. */
export function hasApiKeyScope(scopes: ReadonlySet<string>, needed: ApiKeyScope): boolean {
  return scopes.has('admin') || scopes.has(needed);
}
