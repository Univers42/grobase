// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { afterEach, beforeEach, describe, expect, it } from '@jest/globals';
import type { UserContext, VerifiedAuthMethod } from '@mini-baas/common';
import type { Request } from 'express';
import { StorageController } from './storage.controller';
import type { StorageService } from './storage.service';

// N-13: the usage meter's tenant dimension is an authorization-grade value —
// under QUOTA_ENFORCEMENT it decides WHOSE quota the bytes consume. A
// `legacy-header` identity took it from a raw X-Baas-Tenant-Id, which Kong
// strips only on /functions/ and /query/, so on /storage/v1 any authenticated
// caller could bill (and throttle) another tenant. Owner scoping is by user id
// and was never affected — these tests pin the metering dimension only.

const OWNER = 'user-me';
const VICTIM = 'tenant-someone-else';

function userWith(authMethod: VerifiedAuthMethod): UserContext {
  return {
    id: OWNER,
    email: 'me@example.test',
    role: 'authenticated',
    tenantId: VICTIM,
    authMethod,
  };
}

function reqWith(body: Buffer): Request {
  return {
    body,
    path: `/storage/v1/object/bucket-1/notes.txt`,
    url: `/storage/v1/object/bucket-1/notes.txt`,
    headers: { 'content-type': 'application/octet-stream' },
  } as unknown as Request;
}

/** Captures the `tenantId` argument putObject was called with. */
function capturingService(): { service: StorageService; calls: Array<string | undefined> } {
  const calls: Array<string | undefined> = [];
  const service = {
    putObject: async (
      _bucket: string,
      _key: string,
      _userId: string,
      _body: Buffer,
      _contentType?: string,
      tenantId?: string,
    ) => {
      calls.push(tenantId);
      return { bucket: _bucket, key: _key, size: _body.byteLength };
    },
  } as unknown as StorageService;
  return { service, calls };
}

const ORIGINAL_ENV = { ...process.env };

beforeEach(() => {
  delete process.env.STORAGE_METER_TRUST_RAW_TENANT;
});

afterEach(() => {
  process.env = { ...ORIGINAL_ENV };
});

describe('upload metering dimension', () => {
  it('does NOT meter against a tenant taken from raw identity headers', async () => {
    const { service, calls } = capturingService();
    await new StorageController(service).upload(
      userWith('legacy-header'),
      'bucket-1',
      reqWith(Buffer.from('hello')),
    );
    expect(calls).toEqual([undefined]);
  });

  const verified: VerifiedAuthMethod[] = ['kong-hmac', 'service-token', 'jwt', 'mtls'];
  it.each(verified)('meters against the tenant of a %s identity', async (authMethod) => {
    const { service, calls } = capturingService();
    await new StorageController(service).upload(
      userWith(authMethod),
      'bucket-1',
      reqWith(Buffer.from('hello')),
    );
    expect(calls).toEqual([VICTIM]);
  });

  it.each(['1', 'true', 'TRUE'])(
    'STORAGE_METER_TRUST_RAW_TENANT=%p restores the raw-header dimension',
    async (optOut) => {
      process.env.STORAGE_METER_TRUST_RAW_TENANT = optOut;
      const { service, calls } = capturingService();
      await new StorageController(service).upload(
        userWith('legacy-header'),
        'bucket-1',
        reqWith(Buffer.from('hello')),
      );
      expect(calls).toEqual([VICTIM]);
    },
  );

  it.each(['0', 'false', '', 'yes'])(
    'STORAGE_METER_TRUST_RAW_TENANT=%p is not an opt-out',
    async (notOptOut) => {
      process.env.STORAGE_METER_TRUST_RAW_TENANT = notOptOut;
      const { service, calls } = capturingService();
      await new StorageController(service).upload(
        userWith('legacy-header'),
        'bucket-1',
        reqWith(Buffer.from('hello')),
      );
      expect(calls).toEqual([undefined]);
    },
  );
});
