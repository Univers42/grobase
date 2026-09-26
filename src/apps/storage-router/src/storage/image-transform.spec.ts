import { describe, expect, it } from '@jest/globals';
import { UnprocessableEntityException } from '@nestjs/common';
import type { ConfigService } from '@nestjs/config';
import sharp from 'sharp';
import { applyTransform } from './image-transform';
import { StorageService } from './storage.service';

/** A solid-colour PNG of w×h — tiny on disk whatever its pixel count. */
function png(w: number, h: number): Promise<Buffer> {
  return sharp({ create: { width: w, height: h, channels: 3, background: '#336699' } })
    .png()
    .toBuffer();
}

/** A storage service whose S3 GetObject answers `bytes` as `contentType`. */
function serviceServing(bytes: Buffer, contentType: string): StorageService {
  const config = { get: (_k: string, d?: unknown) => d } as unknown as ConfigService;
  const service = new StorageService(config);
  const s3 = {
    send: async () => ({
      Body: { transformToByteArray: async () => bytes },
      ContentType: contentType,
    }),
  };
  Object.assign(service as unknown as Record<string, unknown>, { s3 });
  return service;
}

describe('applyTransform refuses an image too large to decode in the service (L-6)', () => {
  it('resizes a normal image inside the box', async () => {
    const out = await applyTransform(await png(100, 80), { width: 64 }, 'image/png');
    expect((await sharp(out.body).metadata()).width).toBe(64);
  });

  it('rejects an image above the pixel cap before decoding it (decompression bomb)', async () => {
    await expect(applyTransform(await png(8000, 7000), { width: 64 }, 'image/png')).rejects.toThrow(
      /pixel limit/i,
    );
  });
});

describe('a transform of an unusable image is a 422, not a 500 (L-6)', () => {
  it('getObject maps the transform failure to UnprocessableEntity', async () => {
    const service = serviceServing(Buffer.from('not an image at all'), 'image/png');
    await expect(
      service.getObject('b', 'x.png', 'u1', undefined, { width: 64 }),
    ).rejects.toBeInstanceOf(UnprocessableEntityException);
  });
});
