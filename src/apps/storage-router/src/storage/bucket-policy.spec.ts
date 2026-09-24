import { describe, expect, it, jest } from '@jest/globals';
import { ForbiddenException } from '@nestjs/common';
import type { ConfigService } from '@nestjs/config';
import type { Request } from 'express';

jest.mock('@aws-sdk/s3-request-presigner', () => ({
  getSignedUrl: jest.fn(async () => 'https://s3.example/presigned'),
}));
import { BucketPolicy } from './bucket-policy';
import { StorageController } from './storage.controller';
import { StorageService } from './storage.service';

const DENY_ALL = {
  STORAGE_BUCKET_POLICY_ENABLED: '1',
  STORAGE_BUCKET_POLICY: '{"*":{"deny":["*"]}}',
};
const USER = { id: 'u-1', email: 'u@example.test', role: 'authenticated' };

/** A storage controller whose service carries `policy` and a stub S3 client. */
function controllerWith(policy: BucketPolicy | undefined): StorageController {
  const config = { get: (_k: string, d?: unknown) => d } as unknown as ConfigService;
  const service = new StorageService(config);
  Object.assign(service as unknown as Record<string, unknown>, {
    policy,
    s3: {},
    defaultExpires: 3600,
  });
  return new StorageController(service);
}

/** The Express request the presign route sees for /storage/v1/sign/<bucket>/<path>. */
function signRequest(bucket: string): Request {
  return { path: `/storage/v1/sign/${bucket}/doc.txt` } as unknown as Request;
}

describe('BucketPolicy — a rule is looked up as an OWN property only (M-12)', () => {
  it('a "*" deny covers buckets named after Object.prototype members', () => {
    const policy = BucketPolicy.fromConfig(DENY_ALL);
    for (const bucket of ['constructor', 'toString', 'hasOwnProperty', '__proto__', 'valueOf']) {
      expect(policy?.allows(bucket, 'read', { userId: 'u-1', role: 'authenticated' })).toBe(false);
      expect(policy?.allows(bucket, 'write', { userId: 'u-1', role: 'authenticated' })).toBe(false);
    }
  });

  it('an explicit rule for a normal bucket still wins over "*"', () => {
    const policy = BucketPolicy.fromConfig({
      STORAGE_BUCKET_POLICY_ENABLED: '1',
      STORAGE_BUCKET_POLICY: '{"*":{"deny":["*"]},"public":{"read":["*"]}}',
    });
    expect(policy?.allows('public', 'read', { userId: 'u-1', role: 'authenticated' })).toBe(true);
  });
});

describe('presign consults the bucket policy like every other route (M-12)', () => {
  it('a policy-denied principal gets 403, not a presigned GET', async () => {
    const ctl = controllerWith(BucketPolicy.fromConfig(DENY_ALL));
    await expect(
      ctl.presign(USER, 'docs', signRequest('docs'), { method: 'GET' }),
    ).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('a policy-denied principal gets 403, not a presigned PUT', async () => {
    const ctl = controllerWith(BucketPolicy.fromConfig(DENY_ALL));
    await expect(
      ctl.presign(USER, 'docs', signRequest('docs'), { method: 'PUT' }),
    ).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('policy flag OFF: presign is unchanged (byte-parity)', async () => {
    const ctl = controllerWith(undefined);
    const out = await ctl.presign(USER, 'docs', signRequest('docs'), { method: 'GET' });
    expect(out.signedUrl).toBe('https://s3.example/presigned');
  });
});
