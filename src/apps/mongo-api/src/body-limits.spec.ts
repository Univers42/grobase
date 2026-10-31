import { afterAll, beforeAll, describe, expect, it, jest } from '@jest/globals';
import { Logger } from '@nestjs/common';
import type { AddressInfo } from 'node:net';
import type { Server } from 'node:http';
import express from 'express';
import {
  DEFAULT_BIG_JSON_LIMIT,
  bigJsonLimit,
  documentsCollection,
  hasVerifiedIdentity,
  jsonBodyParser,
  parseBigCollections,
} from './body-limits';

describe('parseBigCollections', () => {
  it('reads a comma list and reports malformed names', () => {
    const big = parseBigCollections(' hydrawn_boards, ,bad name,a-b ');
    expect([...big.names]).toEqual(['hydrawn_boards', 'a-b']);
    expect(big.rejected).toEqual(['bad name']);
    expect(parseBigCollections(undefined)).toEqual({ names: new Set(), rejected: [] });
  });
});

describe('bigJsonLimit', () => {
  it('falls back to the default when unset, empty or not a size', () => {
    expect(bigJsonLimit(undefined)).toBe(DEFAULT_BIG_JSON_LIMIT);
    expect(bigJsonLimit('')).toBe(DEFAULT_BIG_JSON_LIMIT);
    expect(bigJsonLimit('  ')).toBe(DEFAULT_BIG_JSON_LIMIT);
    expect(bigJsonLimit('banana')).toBe(DEFAULT_BIG_JSON_LIMIT);
    expect(bigJsonLimit(' 4mb ')).toBe('4mb');
  });
});

describe('hasVerifiedIdentity', () => {
  const request = (headers: Record<string, string>) =>
    ({ headers, method: 'POST', url: '/', originalUrl: '/' }) as unknown as express.Request;

  it('refuses a request with no identity and one with a forged bearer', async () => {
    expect(await hasVerifiedIdentity(request({}))).toBe(false);
    expect(await hasVerifiedIdentity(request({ authorization: 'Bearer a.b.c' }))).toBe(false);
    expect(await hasVerifiedIdentity(request({ 'x-baas-signature': 'v1=00' }))).toBe(false);
  });

  // SS7: the peek resolves before routing, so IDENTITY_STRICT_SHADOW never judges or
  // logs it — AuthGuard's resolve on the same request is the one that counts.
  it('is never judged by the strict shadow', async () => {
    const saved = [process.env.IDENTITY_HEADER_MODE, process.env.IDENTITY_STRICT_SHADOW];
    Object.assign(process.env, { IDENTITY_HEADER_MODE: 'compat', IDENTITY_STRICT_SHADOW: '1' });
    const warn = jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    try {
      expect(await hasVerifiedIdentity(request({ 'x-user-id': 'user-1' }))).toBe(true);
      expect(warn).not.toHaveBeenCalled();
    } finally {
      warn.mockRestore();
      for (const [key, value] of [
        ['IDENTITY_HEADER_MODE', saved[0]],
        ['IDENTITY_STRICT_SHADOW', saved[1]],
      ] as const) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
    }
  });
});

describe('documentsCollection', () => {
  it('names the collection of a documents route only', () => {
    expect(documentsCollection('/collections/hydrawn_boards/documents')).toBe('hydrawn_boards');
    expect(documentsCollection('/collections/hydrawn_boards/documents/abc')).toBe('hydrawn_boards');
    expect(documentsCollection('/collections/hydrawn_boards/documentsX')).toBeNull();
    expect(documentsCollection('/admin/indexes/hydrawn_boards')).toBeNull();
  });

  it('decodes the name and matches the prefix in any case, as Express routes', () => {
    expect(documentsCollection('/collections/hydrawn%5Fboards/documents')).toBe('hydrawn_boards');
    expect(documentsCollection('/COLLECTIONS/hydrawn_boards/Documents/x')).toBe('hydrawn_boards');
    expect(documentsCollection('/collections/%E0/documents')).toBeNull();
    expect(documentsCollection('/collections/a%2Fb/documents')).toBeNull();
  });
});

describe('jsonBodyParser over HTTP', () => {
  let server: Server;
  let base: string;

  beforeAll(async () => {
    const app = express();
    const signedIn = async (req: express.Request) => req.headers['x-test-auth'] === 'yes';
    app.use(jsonBodyParser(parseBigCollections('hydrawn_boards').names, '8mb', signedIn));
    app.use((req, res) => {
      res.json({ bytes: JSON.stringify(req.body ?? null).length });
    });
    app.use(
      (
        err: { status?: number },
        _req: express.Request,
        res: express.Response,
        _next: express.NextFunction,
      ) => {
        res.status(err.status ?? 500).json({ status: err.status });
      },
    );
    server = app.listen(0);
    await new Promise((ready) => server.once('listening', ready));
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  afterAll(async () => {
    await new Promise((closed) => server.close(closed));
  });

  const post = (path: string, bytes: number, auth = 'yes') =>
    fetch(`${base}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-test-auth': auth },
      body: JSON.stringify({ data: { blob: 'x'.repeat(bytes) } }),
    });

  it('accepts 1 MB on a big collection', async () => {
    const res = await post('/collections/hydrawn_boards/documents', 1_000_000);
    expect(res.status).toBe(200);
  });

  it('accepts 1 MB on a big collection document route (PATCH path shape)', async () => {
    const res = await post('/collections/hydrawn_boards/documents/abc', 1_000_000);
    expect(res.status).toBe(200);
  });

  it('keeps 100 KB everywhere else', async () => {
    expect((await post('/collections/notes/documents', 1_000_000)).status).toBe(413);
    expect((await post('/admin/indexes/hydrawn_boards', 1_000_000)).status).toBe(413);
    expect((await post('/collections/notes/documents', 50_000)).status).toBe(200);
  });

  it('keeps 100 KB on a big collection for an unverified caller', async () => {
    const res = await post('/collections/hydrawn_boards/documents', 1_000_000, 'no');
    expect(res.status).toBe(413);
  });

  it('gives the big limit to an encoded collection name', async () => {
    const res = await post('/collections/hydrawn%5Fboards/documents', 1_000_000);
    expect(res.status).toBe(200);
  });

  it('refuses more than the big limit', async () => {
    const res = await post('/collections/hydrawn_boards/documents', 9 * 1024 * 1024);
    expect(res.status).toBe(413);
  });
});
