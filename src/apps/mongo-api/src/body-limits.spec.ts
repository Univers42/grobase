import { afterAll, beforeAll, describe, expect, it } from '@jest/globals';
import type { AddressInfo } from 'node:net';
import type { Server } from 'node:http';
import express from 'express';
import { documentsCollection, jsonBodyParser, parseBigCollections } from './body-limits';

describe('parseBigCollections', () => {
  it('reads a comma list and drops malformed names', () => {
    expect([...parseBigCollections(' hydrawn_boards, ,bad name,a-b ')]).toEqual([
      'hydrawn_boards',
      'a-b',
    ]);
    expect(parseBigCollections(undefined).size).toBe(0);
  });
});

describe('documentsCollection', () => {
  it('names the collection of a documents route only', () => {
    expect(documentsCollection('/collections/hydrawn_boards/documents')).toBe('hydrawn_boards');
    expect(documentsCollection('/collections/hydrawn_boards/documents/abc')).toBe('hydrawn_boards');
    expect(documentsCollection('/collections/hydrawn_boards/documentsX')).toBeNull();
    expect(documentsCollection('/admin/indexes/hydrawn_boards')).toBeNull();
  });
});

describe('jsonBodyParser over HTTP', () => {
  let server: Server;
  let base: string;

  beforeAll(async () => {
    const app = express();
    app.use(jsonBodyParser(parseBigCollections('hydrawn_boards'), '8mb'));
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

  const post = (path: string, bytes: number) =>
    fetch(`${base}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
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

  it('refuses more than the big limit', async () => {
    const res = await post('/collections/hydrawn_boards/documents', 9 * 1024 * 1024);
    expect(res.status).toBe(413);
  });
});
