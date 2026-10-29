import { describe, expect, it } from '@jest/globals';
import type { VerifiedRequestIdentity } from '@mini-baas/common';
import { apiKeyScopes, hasApiKeyScope } from './api-key-scope';

const identity = (over: Partial<VerifiedRequestIdentity>): VerifiedRequestIdentity => ({
  tenantId: 't-1',
  projectId: 'p-1',
  appId: 'api-key',
  userId: 'api-key:k1',
  role: 'authenticated',
  roleNames: [],
  scopes: ['read'],
  authMethod: 'kong-hmac',
  ...over,
});

describe('apiKeyScopes', () => {
  it('returns the scopes of a Kong-signed key owner', () => {
    expect([...(apiKeyScopes(identity({ scopes: ['read', 'write'] })) ?? [])]).toEqual([
      'read',
      'write',
    ]);
  });

  it('returns the scopes of a user riding an app key', () => {
    expect(apiKeyScopes(identity({ userId: 'user:u1', scopes: ['write'] }))?.has('write')).toBe(
      true,
    );
  });

  it('is undefined for a user that is not under an app key', () => {
    expect(apiKeyScopes(identity({ userId: 'user:u1', appId: 'osionos' }))).toBeUndefined();
  });

  // A legacy-header caller sets X-User-Id / X-App-Id / X-Scopes itself — Kong
  // does not clear the last two — so only the kong-hmac envelope is trusted.
  it.each(['legacy-header', 'jwt', 'service-token', 'mtls'] as const)(
    'is undefined for %s even when it claims an admin app key',
    (authMethod) => {
      expect(
        apiKeyScopes(identity({ authMethod, userId: 'user:x', scopes: ['admin'] })),
      ).toBeUndefined();
    },
  );

  it('is undefined with no identity', () => {
    expect(apiKeyScopes(undefined)).toBeUndefined();
  });
});

describe('hasApiKeyScope', () => {
  it('admin satisfies every scope, like the data plane require_scope', () => {
    const admin = new Set(['admin']);
    expect(hasApiKeyScope(admin, 'read')).toBe(true);
    expect(hasApiKeyScope(admin, 'write')).toBe(true);
  });

  it('matches scopes exactly: apikey:admin is not admin', () => {
    expect(hasApiKeyScope(new Set(['apikey:admin']), 'write')).toBe(false);
    expect(hasApiKeyScope(new Set(['read']), 'write')).toBe(false);
    expect(hasApiKeyScope(new Set(['write']), 'write')).toBe(true);
  });
});
