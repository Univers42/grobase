// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { beforeEach, describe, expect, it, jest } from '@jest/globals';
import { ConfigService } from '@nestjs/config';
import { MongoService } from '@mini-baas/database';
import { AnalyticsEvent, EventsService } from './events.service';

// A hand-rolled Mongo collection/db double — only the surface EventsService
// touches. The partial shape is NOT assignable to the real driver types, so the
// `as unknown as` casts below are genuinely necessary (not redundant).
function makeMongo(sampleDocs: AnalyticsEvent[]) {
  // A flat, self-returning cursor double so the find().sort().limit().toArray()
  // chain stays one level deep (avoids Sonar S2004 deep-nesting on inline arrows).
  const cursor = {
    sort: () => cursor,
    limit: () => cursor,
    toArray: async () => sampleDocs,
  };
  const statRows = [
    { _id: 'view', count: 3 },
    { _id: 'click', count: 2 },
  ];
  const collection = {
    createIndex: jest.fn(async () => 'idx'),
    insertOne: jest.fn(async () => ({ acknowledged: true, insertedId: 'id-1' })),
    find: jest.fn(() => cursor),
    aggregate: jest.fn(() => ({ toArray: async () => statRows })),
    distinct: jest.fn(async () => ['view', 'click']),
  };
  const db = { collection: jest.fn(() => collection) };
  const mongo = { getDb: () => db, isHealthy: jest.fn(async () => true) };
  return { mongo, db, collection };
}

describe('EventsService', () => {
  const sample: AnalyticsEvent = { eventType: 'view', timestamp: new Date(), data: { path: '/' } };
  let svc: EventsService;
  let collection: ReturnType<typeof makeMongo>['collection'];

  beforeEach(async () => {
    const m = makeMongo([sample]);
    collection = m.collection;
    const config = { get: (_key: string, def?: unknown) => def };
    svc = new EventsService(m.mongo as unknown as MongoService, config as unknown as ConfigService);
    await svc.onModuleInit(); // resolves the collection + ensures indexes
  });

  it('onModuleInit ensures the TTL + compound indexes', () => {
    expect(collection.createIndex).toHaveBeenCalledTimes(2);
  });

  it('track inserts the event with a server timestamp', async () => {
    await svc.track(sample);
    expect(collection.insertOne).toHaveBeenCalledTimes(1);
  });

  it('getByType applies the since filter and returns the rows', async () => {
    const rows = await svc.getByType('view', { since: new Date('2020-01-01'), limit: 10 });
    expect(rows).toEqual([sample]);
    expect(collection.find).toHaveBeenCalledTimes(1);
  });

  it('getStats reduces the aggregation into a type→count map', async () => {
    const stats = await svc.getStats(7);
    expect(stats).toEqual({ view: 3, click: 2 });
  });

  it('getDistinctTypes returns the distinct event types', async () => {
    await expect(svc.getDistinctTypes()).resolves.toEqual(['view', 'click']);
  });

  it('isHealthy delegates to the mongo connection', async () => {
    await expect(svc.isHealthy()).resolves.toBe(true);
  });
});
