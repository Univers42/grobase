import { describe, expect, it, jest } from '@jest/globals';
import { BadRequestException, ConflictException, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { ObjectId } from 'mongodb';
import type { MongoService } from '@mini-baas/database';
import type { Counter } from 'prom-client';
import { CollectionsService } from './collections.service';

// The projection and compare-and-swap surface of PATCH and list, over one in-memory
// document. The fake evaluates the filter the service hands the driver (equality and
// `$in`) and applies `$set` in one step, as Mongo's findOneAndUpdate does per document.

type Doc = Record<string, unknown>;

function matches(doc: Doc, filter: Doc): boolean {
  return Object.entries(filter).every(([key, want]) => {
    const have = doc[key];
    if (want instanceof ObjectId) return have instanceof ObjectId && have.equals(want);
    if (want && typeof want === 'object' && '$in' in want)
      return (want.$in as unknown[]).includes(have);
    return have === want;
  });
}

function project(doc: Doc, projection?: Record<string, 1>): Doc {
  if (!projection) return { ...doc };
  const out: Doc = { _id: doc._id };
  for (const field of Object.keys(projection)) if (field in doc) out[field] = doc[field];
  return out;
}

function build(seed: Doc) {
  const docs: Doc[] = [seed];
  const finds: Array<{ filter: Doc; projection?: Record<string, 1> }> = [];
  const collection = {
    find: jest.fn((filter: Doc, options?: { projection?: Record<string, 1> }) => {
      finds.push({ filter, projection: options?.projection });
      const rows = docs
        .filter((doc) => matches(doc, filter))
        .map((doc) => project(doc, options?.projection));
      const cursor = {
        sort: () => cursor,
        skip: () => cursor,
        limit: () => cursor,
        toArray: async () => rows,
      };
      return cursor;
    }),
    countDocuments: jest.fn(
      async (filter: Doc) => docs.filter((doc) => matches(doc, filter)).length,
    ),
    findOne: jest.fn(async (filter: Doc) => docs.find((doc) => matches(doc, filter)) ?? null),
    findOneAndUpdate: jest.fn(
      async (filter: Doc, update: { $set: Doc }, options: { projection?: Record<string, 1> }) => {
        await new Promise((tick) => setImmediate(tick));
        const doc = docs.find((row) => matches(row, filter));
        if (!doc) return null;
        Object.assign(doc, update.$set);
        return project(doc, options.projection);
      },
    ),
  };
  const db = { collection: jest.fn(() => collection) };
  const mongo = { getDb: jest.fn(() => db) } as unknown as MongoService;
  const config = { get: (_k: string, def?: string) => def } as unknown as ConfigService;
  const counter = { inc: jest.fn() } as unknown as Counter<string>;
  return { service: new CollectionsService(mongo, config, counter), docs, finds };
}

const OWNER = 'user-1';
const boardId = new ObjectId();
const board = (): Doc => ({
  _id: boardId,
  owner_id: OWNER,
  slug: 's1',
  title: 'Plan',
  rev: 3,
  elements: ['big'],
});

describe('PATCH compare-and-swap', () => {
  it('applies while the guarded field still matches, comparing a numeric value by number', async () => {
    const h = build(board());
    const out = await h.service.patch(
      'hydrawn_boards',
      OWNER,
      boardId.toHexString(),
      { rev: 4 },
      {
        ifField: 'rev',
        ifValue: '3',
      },
    );
    expect(out.rev).toBe(4);
    expect(h.docs[0].rev).toBe(4);
  });

  it('answers 409 when the field moved and 404 when the document is absent', async () => {
    const h = build(board());
    const stale = h.service.patch(
      'hydrawn_boards',
      OWNER,
      boardId.toHexString(),
      { rev: 9 },
      {
        ifField: 'rev',
        ifValue: '2',
      },
    );
    await expect(stale).rejects.toBeInstanceOf(ConflictException);
    expect(h.docs[0].rev).toBe(3);

    const missing = h.service.patch(
      'hydrawn_boards',
      OWNER,
      new ObjectId().toHexString(),
      { rev: 4 },
      {
        ifField: 'rev',
        ifValue: '3',
      },
    );
    await expect(missing).rejects.toBeInstanceOf(NotFoundException);
  });

  it("never matches another owner's document, which reads as absent", async () => {
    const h = build(board());
    const foreign = h.service.patch(
      'hydrawn_boards',
      'user-2',
      boardId.toHexString(),
      { rev: 4 },
      {
        ifField: 'rev',
        ifValue: '3',
      },
    );
    await expect(foreign).rejects.toBeInstanceOf(NotFoundException);
  });

  it('does not read a padded number as that number', async () => {
    const h = build(board());
    const padded = h.service.patch(
      'hydrawn_boards',
      OWNER,
      boardId.toHexString(),
      { rev: 4 },
      {
        ifField: 'rev',
        ifValue: '03',
      },
    );
    await expect(padded).rejects.toBeInstanceOf(ConflictException);
  });

  it('lets exactly one of 20 concurrent writers of the same rev through', async () => {
    const h = build(board());
    const results = await Promise.allSettled(
      Array.from({ length: 20 }, (_, writer) =>
        h.service.patch(
          'hydrawn_boards',
          OWNER,
          boardId.toHexString(),
          { rev: 4, title: `w${writer}` },
          {
            ifField: 'rev',
            ifValue: '3',
          },
        ),
      ),
    );
    const won = results.filter((result) => result.status === 'fulfilled');
    const lost = results.filter(
      (result) => result.status === 'rejected' && result.reason instanceof ConflictException,
    );
    expect(won).toHaveLength(1);
    expect(lost).toHaveLength(19);
    expect(h.docs[0].rev).toBe(4);
  });

  it('refuses half a guard and unsafe guard fields', async () => {
    const h = build(board());
    const id = boardId.toHexString();
    await expect(
      h.service.patch('hydrawn_boards', OWNER, id, {}, { ifField: 'rev' }),
    ).rejects.toBeInstanceOf(BadRequestException);
    await expect(
      h.service.patch('hydrawn_boards', OWNER, id, {}, { ifField: 'owner_id', ifValue: OWNER }),
    ).rejects.toBeInstanceOf(BadRequestException);
  });
});

describe('fields projection', () => {
  it('returns only the named fields and the id after a PATCH', async () => {
    const h = build(board());
    const out = await h.service.patch(
      'hydrawn_boards',
      OWNER,
      boardId.toHexString(),
      { title: 'New' },
      {
        fields: 'slug,title',
      },
    );
    expect(out).toEqual({ id: boardId.toHexString(), slug: 's1', title: 'New' });
  });

  it('projects a list and keeps the owner scope', async () => {
    const h = build(board());
    const out = await h.service.findAll('hydrawn_boards', OWNER, {
      limit: 10,
      offset: 0,
      fields: 'slug,rev',
    });
    expect(out.data).toEqual([{ id: boardId.toHexString(), slug: 's1', rev: 3 }]);
    expect(h.finds[0]).toEqual({ filter: { owner_id: OWNER }, projection: { slug: 1, rev: 1 } });
  });

  it('refuses owner_id, _id, operators and dotted paths as fields', async () => {
    const h = build(board());
    for (const fields of ['owner_id', 'slug,_id', '$where', 'a.b']) {
      await expect(
        h.service.findAll('hydrawn_boards', OWNER, { limit: 10, offset: 0, fields }),
      ).rejects.toBeInstanceOf(BadRequestException);
    }
  });
});
