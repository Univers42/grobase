import { afterEach, describe, expect, it, jest } from '@jest/globals';
import type { ConfigService } from '@nestjs/config';

const signed: Array<{ input: Record<string, unknown> }> = [];
jest.mock('@aws-sdk/s3-request-presigner', () => ({
  getSignedUrl: jest.fn(async (_client: unknown, command: { input: Record<string, unknown> }) => {
    signed.push(command);
    return 'https://s3.example/presigned';
  }),
}));
import { StorageService } from './storage.service';

/** A storage service whose S3 HeadObject answers `contentType`; counts the heads. */
function serviceStoring(contentType: string): { service: StorageService; heads: () => number } {
  let heads = 0;
  const config = { get: (_k: string, d?: unknown) => d } as unknown as ConfigService;
  const service = new StorageService(config);
  const s3 = {
    send: async () => {
      heads += 1;
      return { ContentType: contentType };
    },
  };
  Object.assign(service as unknown as Record<string, unknown>, { s3, defaultExpires: 3600 });
  return { service, heads: () => heads };
}

/** Presign a GET of x on bucket b with the guard flag set to `flag`. */
async function presignGet(
  service: StorageService,
  flag: string | undefined,
): Promise<Record<string, unknown>> {
  const before = process.env.STORAGE_ACTIVE_CONTENT_GUARD_ENABLED;
  if (flag === undefined) delete process.env.STORAGE_ACTIVE_CONTENT_GUARD_ENABLED;
  else process.env.STORAGE_ACTIVE_CONTENT_GUARD_ENABLED = flag;
  try {
    await service.presign('b', 'x', 'u1', { method: 'GET' });
  } finally {
    if (before === undefined) delete process.env.STORAGE_ACTIVE_CONTENT_GUARD_ENABLED;
    else process.env.STORAGE_ACTIVE_CONTENT_GUARD_ENABLED = before;
  }
  return signed[signed.length - 1].input;
}

afterEach(() => {
  signed.length = 0;
});

describe('presigned GETs get the active-content guard too (M-17/L-9)', () => {
  it('guard ON: an SVG is signed to download (attachment), not render', async () => {
    const { service } = serviceStoring('image/svg+xml');
    expect((await presignGet(service, '1')).ResponseContentDisposition).toBe('attachment');
  });

  it('guard ON: an HTML page is signed to download', async () => {
    const { service } = serviceStoring('text/html; charset=utf-8');
    expect((await presignGet(service, '1')).ResponseContentDisposition).toBe('attachment');
  });

  it('guard ON: a passive image keeps rendering inline', async () => {
    const { service } = serviceStoring('image/png');
    expect((await presignGet(service, '1')).ResponseContentDisposition).toBeUndefined();
  });

  it('guard OFF: no HEAD and no override — byte-parity', async () => {
    const { service, heads } = serviceStoring('image/svg+xml');
    expect((await presignGet(service, undefined)).ResponseContentDisposition).toBeUndefined();
    expect(heads()).toBe(0);
  });
});
