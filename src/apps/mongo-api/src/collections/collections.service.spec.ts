// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { afterEach, beforeEach, describe, expect, it, jest } from '@jest/globals';
import { BadRequestException, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { ObjectId } from 'mongodb';
import type { MongoService } from '@mini-baas/database';
import type { Counter } from 'prom-client';
import { CollectionsService } from './collections.service';

// Security harness for the Mongo collection façade: NoSQL-injection rejection
// (`$`-operators and dotted keys in filters), collection-name allow-listing,
// and per-request owner-scoping. Behaviour read from collections.service.ts —
// the asserts below pin what the code ACTUALLY does, not an idealised contract.

interface FakeCursor {
  sort: jest.Mock;
  skip: jest.Mock;
  limit: jest.Mock;
  toArray: jest.Mock;
}

function build() {
  // Capture every query handed to the driver so owner-scoping is observable.
  const findQueries: Array<Record<string, unknown>> = [];
  const countQueries: Array<Record<string, unknown>> = [];
  const insertedDocs: Array<Record<string, unknown>> = [];
  const findOneFilters: Array<Record<string, unknown>> = [];
  const updateFilters: Array<Record<string, unknown>> = [];
  const deleteFilters: Array<Record<string, unknown>> = [];

  const cursor: FakeCursor = {
    sort: jest.fn(() => cursor),
    skip: jest.fn(() => cursor),
    limit: jest.fn(() => cursor),
    toArray: jest.fn(async () => [] as Array<Record<string, unknown>>),
  };

  const collection = {
    find: jest.fn((q: Record<string, unknown>) => {
      findQueries.push(q);
      return cursor;
    }),
    countDocuments: jest.fn(async (q: Record<string, unknown>) => {
      countQueries.push(q);
      return 0;
    }),
    insertOne: jest.fn(async (doc: Record<string, unknown>) => {
      insertedDocs.push(doc);
      return { insertedId: new ObjectId() };
    }),
    findOne: jest.fn(async (q: Record<string, unknown>) => {
      findOneFilters.push(q);
      return null;
    }),
    findOneAndUpdate: jest.fn(async (q: Record<string, unknown>) => {
      updateFilters.push(q);
      return null;
    }),
    deleteOne: jest.fn(async (q: Record<string, unknown>) => {
      deleteFilters.push(q);
      return { deletedCount: 0 };
    }),
    createIndex: jest.fn(async () => 'idx'),
  };

  const db = {
    collection: jest.fn(() => collection),
    listCollections: jest.fn(() => ({ toArray: async () => [{ name: 'mock_catalog' }] })),
    createCollection: jest.fn(async () => collection),
  };

  const mongo = { getDb: jest.fn(() => db) } as unknown as MongoService;
  const config = { get: (_k: string, def?: string) => def } as unknown as ConfigService;
  const counter = { inc: jest.fn() } as unknown as Counter<string>;

  const service = new CollectionsService(mongo, config, counter);
  return {
    service,
    collection,
    findQueries,
    countQueries,
    insertedDocs,
    findOneFilters,
    updateFilters,
    deleteFilters,
  };
}

afterEach(() => {
  jest.restoreAllMocks();
});

describe('CollectionsService — collection-name allow-listing', () => {
  let h: ReturnType<typeof build>;
  beforeEach(() => {
    h = build();
  });

  const validNames = [
    'notes',
    'a',
    'A1',
    'user_data',
    'my-collection',
    'x'.repeat(64),
    '123',
    'foo_bar-1',
  ];
  it.each(validNames)('accepts collection name %p', async (name) => {
    await expect(h.service.findAll(name, 'u-1', { limit: 10, offset: 0 })).resolves.toBeDefined();
  });

  const badNames = [
    '', // empty
    'x'.repeat(65), // 65 chars > 64
    'has space',
    'with.dot',
    'with$dollar',
    'semi;colon',
    'quote"x',
    "tick'x",
    'slash/x',
    String.raw`back\slash`,
    'paren(x)',
    'brace{x}',
    'pipe|x',
    'star*x',
    'percent%x',
    'at@x',
    'newline\nx',
    'tab\tx',
    'null\0byte',
    '../escape',
    'café', // non-ASCII letter
    '名前', // unicode
    'drop;table',
    '$where',
    'a.b.c',
  ];
  it.each(badNames)('rejects collection name %p', async (name) => {
    await expect(h.service.findAll(name, 'u-1', { limit: 10, offset: 0 })).rejects.toBeInstanceOf(
      BadRequestException,
    );
  });
});

describe('CollectionsService — Mongo operator / NoSQL-injection rejection', () => {
  let h: ReturnType<typeof build>;
  beforeEach(() => {
    h = build();
  });

  // Each is a JSON string for the `filter` query param. All must be REJECTED
  // with BadRequestException (never reach the driver).
  const maliciousFilters: string[] = [
    // top-level $-operators as field keys
    '{"$where":"this.x==1"}',
    '{"$or":[{"a":1}]}',
    '{"$and":[{"a":1}]}',
    '{"$expr":{"$eq":["$a","$b"]}}',
    '{"$nor":[{"a":1}]}',
    '{"$text":{"$search":"x"}}',
    '{"$comment":"x"}',
    // nested $-operators inside a value
    '{"age":{"$ne":null}}',
    '{"age":{"$gt":0}}',
    '{"age":{"$gte":0}}',
    '{"age":{"$lt":99}}',
    '{"name":{"$regex":".*"}}',
    '{"name":{"$in":["a","b"]}}',
    '{"name":{"$nin":["a"]}}',
    '{"x":{"$exists":true}}',
    '{"x":{"$type":"string"}}',
    '{"x":{"$elemMatch":{"y":1}}}',
    '{"x":{"$size":1}}',
    '{"x":{"$mod":[2,0]}}',
    '{"x":{"$all":[1,2]}}',
    // deeply nested $-operator
    '{"a":{"b":{"$ne":1}}}',
    '{"a":{"b":{"c":{"$gt":0}}}}',
    // $-operator inside an array element
    '{"a":[{"$ne":1}]}',
    '{"a":[1,{"b":{"$gt":0}}]}',
    '{"a":[[{"$where":"1"}]]}',
    // dotted field keys (path traversal into nested docs)
    '{"a.b":1}',
    '{"a.b.c":1}',
    '{"owner_id.x":1}',
    '{"x":{"a.b":1}}',
    '{"x":[{"a.b":1}]}',
    // forbidden direct fields
    '{"_id":"x"}',
    '{"owner_id":"someone-else"}',
    // $-operator as the only key
    '{"$gt":1}',
  ];

  it.each(maliciousFilters)('rejects malicious filter %p', async (filter) => {
    await expect(
      h.service.findAll('notes', 'u-1', { limit: 10, offset: 0, filter }),
    ).rejects.toBeInstanceOf(BadRequestException);
    // the driver must never have been queried with the poisoned filter
    expect(h.collection.find).not.toHaveBeenCalled();
  });

  // Malformed JSON must also be rejected (not crash, not pass through).
  const malformedJson: string[] = [
    'not json',
    '{',
    '{"a":}',
    "{'a':1}", // single quotes are invalid JSON
    '[1,2,3]', // array is not a plain object
    '"string"',
    '42',
    'true',
    'null',
    'undefined',
  ];
  it.each(malformedJson)('rejects malformed/non-object filter %p', async (filter) => {
    await expect(
      h.service.findAll('notes', 'u-1', { limit: 10, offset: 0, filter }),
    ).rejects.toBeInstanceOf(BadRequestException);
  });

  // Plain field filters PASS and are AND-merged with the owner scope.
  const benignFilters: Array<[string, Record<string, unknown>]> = [
    ['{"title":"hello"}', { title: 'hello' }],
    ['{"status":"open"}', { status: 'open' }],
    ['{"count":5}', { count: 5 }],
    ['{"active":true}', { active: true }],
    ['{"a":1,"b":"two"}', { a: 1, b: 'two' }],
    ['{"nested":{"inner":"v"}}', { nested: { inner: 'v' } }],
    ['{"tags":["x","y"]}', { tags: ['x', 'y'] }],
    ['{}', {}],
  ];
  it.each(benignFilters)('accepts benign filter %p', async (filter, expectedSubset) => {
    await h.service.findAll('notes', 'u-7', { limit: 10, offset: 0, filter });
    expect(h.collection.find).toHaveBeenCalledTimes(1);
    const query = h.findQueries[0];
    // owner scope is always present and benign field merged on top
    expect(query.owner_id).toBe('u-7');
    for (const [k, v] of Object.entries(expectedSubset)) {
      expect(query[k]).toEqual(v);
    }
  });

  // A client filter must NOT be able to override the owner scope.
  it('a client filter cannot widen access — owner_id is rejected outright', async () => {
    await expect(
      h.service.findAll('notes', 'victim', {
        limit: 10,
        offset: 0,
        filter: '{"owner_id":"attacker"}',
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(h.collection.find).not.toHaveBeenCalled();
  });

  // sort field is also run through the safe-field-name guard
  const badSorts = ['$where:asc', 'a.b:desc', '_id:asc', 'owner_id:desc', '$gt:asc'];
  it.each(badSorts)('rejects unsafe sort field %p', async (sort) => {
    await expect(
      h.service.findAll('notes', 'u-1', { limit: 10, offset: 0, sort }),
    ).rejects.toBeInstanceOf(BadRequestException);
  });
});

describe('CollectionsService — per-request owner-scoping & tenant isolation', () => {
  let h: ReturnType<typeof build>;
  beforeEach(() => {
    h = build();
  });

  it('findAll always scopes by the server-supplied userId', async () => {
    await h.service.findAll('notes', 'owner-A', { limit: 5, offset: 0 });
    expect(h.findQueries[0]).toEqual({ owner_id: 'owner-A' });
    expect(h.countQueries[0]).toEqual({ owner_id: 'owner-A' });
  });

  it('create stamps owner_id from the request identity and strips client _id/owner_id', async () => {
    await h.service.create('notes', 'real-owner', {
      title: 't',
      _id: 'forged-id',
      owner_id: 'forged-owner',
      extra: 1,
    });
    const doc = h.insertedDocs[0];
    expect(doc.owner_id).toBe('real-owner'); // server identity wins
    expect(doc._id).toBeUndefined(); // client _id stripped
    expect(doc.title).toBe('t');
    expect(doc.extra).toBe(1);
    expect(doc.created_at).toBeInstanceOf(Date);
    expect(doc.updated_at).toBeInstanceOf(Date);
  });

  it('findOne scopes by both _id and the owner (no cross-tenant read)', async () => {
    const id = new ObjectId().toHexString();
    await expect(h.service.findOne('notes', 'owner-A', id)).rejects.toBeInstanceOf(
      NotFoundException,
    );
    const filter = h.findOneFilters[0];
    expect(filter.owner_id).toBe('owner-A');
    expect((filter._id as ObjectId).toHexString()).toBe(id);
  });

  it('patch scopes the update by owner and never lets the client move ownership', async () => {
    const id = new ObjectId().toHexString();
    await expect(
      h.service.patch('notes', 'owner-A', id, { title: 'x', owner_id: 'attacker', _id: 'forged' }),
    ).rejects.toBeInstanceOf(NotFoundException);
    const filter = h.updateFilters[0];
    expect(filter.owner_id).toBe('owner-A'); // scope unchanged
  });

  it('remove scopes the delete by owner', async () => {
    const id = new ObjectId().toHexString();
    await expect(h.service.remove('notes', 'owner-A', id)).rejects.toBeInstanceOf(
      NotFoundException,
    );
    expect(h.deleteFilters[0]).toEqual({ _id: expect.any(ObjectId), owner_id: 'owner-A' });
  });

  // invalid ObjectId on the id-taking ops must 400 before any driver call
  const badIds = ['not-an-objectid', '123', '', 'zzzzzzzzzzzzzzzzzzzzzzzz', '../../etc', '$ne'];
  it.each(badIds)('findOne rejects malformed document id %p', async (id) => {
    await expect(h.service.findOne('notes', 'u-1', id)).rejects.toBeInstanceOf(BadRequestException);
    expect(h.collection.findOne).not.toHaveBeenCalled();
  });
  it.each(badIds)('patch rejects malformed document id %p', async (id) => {
    await expect(h.service.patch('notes', 'u-1', id, { x: 1 })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    expect(h.collection.findOneAndUpdate).not.toHaveBeenCalled();
  });
  it.each(badIds)('remove rejects malformed document id %p', async (id) => {
    await expect(h.service.remove('notes', 'u-1', id)).rejects.toBeInstanceOf(BadRequestException);
    expect(h.collection.deleteOne).not.toHaveBeenCalled();
  });

  it('two users querying the same collection get isolated scopes', async () => {
    await h.service.findAll('notes', 'alice', { limit: 5, offset: 0 });
    await h.service.findAll('notes', 'bob', { limit: 5, offset: 0 });
    expect(h.findQueries[0].owner_id).toBe('alice');
    expect(h.findQueries[1].owner_id).toBe('bob');
  });
});
