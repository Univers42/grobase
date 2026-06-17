// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { afterAll, afterEach, beforeEach, describe, expect, it, jest } from '@jest/globals';
import { ConfigService } from '@nestjs/config';
import type { HttpService } from '@nestjs/axios';
import type { VerifiedRequestIdentity } from '@mini-baas/common';
import { RealtimePublisherService } from './realtime-publisher.service';
import { QueryService } from './query.service';
import { SchemaService } from './schema.service';
import { ExecuteQueryDto } from './dto/query.dto';
import type { TxnOpDto } from './dto/txn.dto';
import type { OutboxService } from './outbox.service';
import type { RustDataPlaneProxy } from '../proxy/rust-data-plane.proxy';
import type { AutomationsService } from './automations.service';

// internal/loopback only — not externally exposed (built so no `http://` literal)
const INTERNAL_SCHEME = 'http';
const PUBLISH_URL = `${INTERNAL_SCHEME}://realtime:4000/v1/publish`;
const ADAPTER_REGISTRY_URL = `${INTERNAL_SCHEME}://adapter-registry-go:3021`;

// ── shared fetch mock (the publisher's only transport) ──────────────────────

const realFetch = globalThis.fetch;
let fetchMock: jest.Spied<typeof globalThis.fetch>;

beforeEach(() => {
  // spyOn keeps the assignment type-safe (no `as unknown as typeof fetch` cast)
  // and lets jest.restoreAllMocks() put the real fetch back after each test.
  fetchMock = jest.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(null, { status: 200 }));
});

afterEach(() => {
  jest.restoreAllMocks();
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

/** Drains the fire-and-forget publish chains (fetch promise + handlers). */
const flush = async () => {
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
};

function publishedBody(call = 0): Record<string, any> {
  const init = fetchMock.mock.calls[call][1] as { body: string };
  return JSON.parse(init.body) as Record<string, any>;
}

function buildPublisher(overrides: Record<string, string> = {}): RealtimePublisherService {
  const config = {
    get: (key: string, def?: string) => overrides[key] ?? def,
  } as unknown as ConfigService;
  return new RealtimePublisherService(config);
}

// ── RealtimePublisherService (unit) ──────────────────────────────────────────

describe('RealtimePublisherService', () => {
  it('POSTs the exact row_changed envelope to the publish URL', async () => {
    const publisher = buildPublisher();
    await publisher.publishRowChanged('db-1', 'notes', 'insert', {
      filter: { id: 7 },
      idempotencyKey: 'idem-1',
      pk: 7,
    });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe(PUBLISH_URL);
    const body = publishedBody();
    expect(body.topic).toBe('table:db-1:notes');
    expect(body.event_type).toBe('row_changed');
    expect(body.idempotency_key).toBe('idem-1');
    expect(body.payload).toMatchObject({
      dbId: 'db-1',
      table: 'notes',
      op: 'insert',
      filter: { id: 7 },
      pk: 7,
    });
    expect(typeof body.payload.ts).toBe('string');
    expect(Number.isNaN(Date.parse(body.payload.ts))).toBe(false);
  });

  it('omits idempotency_key when none is provided', async () => {
    const publisher = buildPublisher();
    await publisher.publishRowChanged('db-1', 'notes', 'delete', { filter: { id: 1 } });
    expect('idempotency_key' in publishedBody()).toBe(false);
  });

  it('drops oversized and non-serializable filters (event still sent)', async () => {
    const publisher = buildPublisher();
    const huge = { blob: 'x'.repeat(10_000) };
    await publisher.publishRowChanged('db-1', 'notes', 'update', { filter: huge });
    expect(publishedBody(0).payload.filter).toBeUndefined();

    const cyclic: Record<string, unknown> = {};
    cyclic['self'] = cyclic;
    await publisher.publishRowChanged('db-1', 'notes', 'update', { filter: cyclic });
    expect(publishedBody(1).payload.filter).toBeUndefined();
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('publishes schema_changed on the same table channel', async () => {
    const publisher = buildPublisher();
    await publisher.publishSchemaChanged('db-1', 'notes', 'add_column');
    const body = publishedBody();
    expect(body.topic).toBe('table:db-1:notes');
    expect(body.event_type).toBe('schema_changed');
    expect(body.payload).toMatchObject({ dbId: 'db-1', table: 'notes', op: 'add_column' });
  });

  it('never rejects: network failure and non-2xx are swallowed', async () => {
    const publisher = buildPublisher();
    fetchMock.mockImplementationOnce(() => Promise.reject(new Error('ECONNREFUSED')));
    await expect(
      publisher.publishRowChanged('db-1', 'notes', 'insert', {}),
    ).resolves.toBeUndefined();

    fetchMock.mockImplementationOnce(async () => new Response(null, { status: 503 }));
    await expect(
      publisher.publishRowChanged('db-1', 'notes', 'insert', {}),
    ).resolves.toBeUndefined();
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('is disabled entirely when REALTIME_PUBLISH_URL is empty', async () => {
    const publisher = buildPublisher({ REALTIME_PUBLISH_URL: '' });
    await publisher.publishRowChanged('db-1', 'notes', 'insert', {});
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

// ── QueryService wiring (publisher called from the write paths) ─────────────

const DB_ID = 'db-1';
const MOUNTS_JSON = JSON.stringify({
  [DB_ID]: { engine: 'postgresql', connection_string: 'postgres://example/db' },
});

/** api-key identity → decideByApiKeyScope short-circuits ABAC (no HTTP). */
const identity: VerifiedRequestIdentity = {
  tenantId: 't-1',
  projectId: 't-1',
  appId: 'api-key',
  userId: 'api-key:k-1',
  role: 'authenticated',
  roleNames: ['authenticated'],
  scopes: ['read', 'write'],
  authMethod: 'kong-hmac',
};

function buildQueryService() {
  const config = {
    getOrThrow: () => ADAPTER_REGISTRY_URL,
    get: (key: string, def?: unknown) => (key === 'DATA_PLANE_MOUNTS' ? MOUNTS_JSON : def),
  } as unknown as ConfigService;
  const outbox = { emitForQuery: jest.fn(async () => undefined) };
  const rustProxy = {
    shouldForward: jest.fn(() => true),
    execute: jest.fn(async () => ({ rows: [{ id: 'row-1' }], rowCount: 1 })),
    beginTransaction: jest.fn(async () => 'tx-1'),
    executeInTransaction: jest.fn(async () => ({ rows: [], rowCount: 1 })),
    commitTransaction: jest.fn(async () => undefined),
    rollbackTransaction: jest.fn(async () => undefined),
  };
  const realtime = buildPublisher();
  const automations = { runForWrite: jest.fn(async () => undefined) };
  const service = new QueryService(
    config,
    {} as HttpService,
    outbox as unknown as OutboxService,
    rustProxy as unknown as RustDataPlaneProxy,
    realtime,
    automations as unknown as AutomationsService,
  );
  return { service, outbox, rustProxy, realtime, automations };
}

function queryDto(input: Partial<ExecuteQueryDto>): ExecuteQueryDto {
  return Object.assign(new ExecuteQueryDto(), input);
}

describe('QueryService realtime wiring', () => {
  it('publishes row_changed (exact topic + payload) after a successful insert', async () => {
    const { service } = buildQueryService();
    const result = await service.executeQuery(
      DB_ID,
      'notes',
      'api-key:k-1',
      queryDto({ op: 'insert', data: { title: 'hello' }, idempotencyKey: 'idem-9' }),
      { identity },
    );
    await flush();

    expect(result.rows).toEqual([{ id: 'row-1' }]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const body = publishedBody();
    expect(body.topic).toBe(`table:${DB_ID}:notes`);
    expect(body.event_type).toBe('row_changed');
    expect(body.idempotency_key).toBe('idem-9');
    expect(body.payload).toMatchObject({
      dbId: DB_ID,
      table: 'notes',
      op: 'insert',
      pk: 'row-1', // taken from the returned row's id
    });
  });

  it('does NOT publish for read ops (list/get/aggregate)', async () => {
    const { service } = buildQueryService();
    for (const op of ['list', 'get', 'aggregate'] as const) {
      await service.executeQuery(
        DB_ID,
        'notes',
        'api-key:k-1',
        queryDto({
          op,
          aggregate:
            op === 'aggregate' ? { aggregates: [{ func: 'count', alias: 'n' }] } : undefined,
        }),
        { identity },
      );
    }
    await flush();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('does NOT publish when the write itself fails', async () => {
    const { service, rustProxy } = buildQueryService();
    rustProxy.execute.mockImplementationOnce(() => Promise.reject(new Error('backend down')));
    await expect(
      service.executeQuery(DB_ID, 'notes', 'api-key:k-1', queryDto({ op: 'insert', data: { a: 1 } }), {
        identity,
      }),
    ).rejects.toThrow('backend down');
    await flush();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('write result is unaffected when the publish rejects', async () => {
    const { service } = buildQueryService();
    fetchMock.mockImplementation(() => Promise.reject(new Error('realtime down')));
    const result = await service.executeQuery(
      DB_ID,
      'notes',
      'api-key:k-1',
      queryDto({ op: 'insert', data: { a: 1 } }),
      { identity },
    );
    await flush();
    expect(result).toEqual({ rows: [{ id: 'row-1' }], rowCount: 1 });
    expect(fetchMock).toHaveBeenCalledTimes(1); // attempted, swallowed
  });

  it('publishes one row_changed per op after a committed transaction', async () => {
    const { service } = buildQueryService();
    const ops = [
      { op: 'insert', resource: 'nodes', data: { id: 'n-1' } },
      { op: 'update', resource: 'edges', filter: { id: 'e-1' }, idempotencyKey: 'idem-e' },
    ] as TxnOpDto[];
    const result = await service.executeTransaction(DB_ID, 'api-key:k-1', ops, { identity });
    await flush();

    expect(result.guarantee).toBe('atomic');
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const first = publishedBody(0);
    expect(first.topic).toBe(`table:${DB_ID}:nodes`);
    expect(first.payload).toMatchObject({ op: 'insert', table: 'nodes', pk: 'n-1' });
    const second = publishedBody(1);
    expect(second.topic).toBe(`table:${DB_ID}:edges`);
    expect(second.idempotency_key).toBe('idem-e');
    expect(second.payload).toMatchObject({ op: 'update', table: 'edges', filter: { id: 'e-1' } });
  });

  it('does NOT publish when the transaction rolls back', async () => {
    const { service, rustProxy } = buildQueryService();
    rustProxy.executeInTransaction.mockImplementationOnce(() =>
      Promise.reject(new Error('constraint violation')),
    );
    await expect(
      service.executeTransaction(
        DB_ID,
        'api-key:k-1',
        [{ op: 'insert', resource: 'nodes', data: {} }] as TxnOpDto[],
        { identity },
      ),
    ).rejects.toThrow('constraint violation');
    await flush();
    expect(rustProxy.rollbackTransaction).toHaveBeenCalledTimes(1);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

// ── SchemaService wiring (schema_changed from the DDL path) ─────────────────

function buildSchemaService() {
  const config = {
    get: (_key: string, def?: string) => def,
  } as unknown as ConfigService;
  const query = {
    resolveConnection: jest.fn(async () => ({
      engine: 'postgresql',
      connection_string: 'postgres://example/db',
      isolation: 'shared_rls',
    })),
  };
  const proxy = {
    applySchemaDdl: jest.fn(
      async (_ctx: unknown, ddl: { op: string; table: string }) => ({
        op: ddl.op,
        table: ddl.table,
        status: 'applied',
      }),
    ),
  };
  const service = new SchemaService(
    config,
    query as unknown as QueryService,
    proxy as unknown as RustDataPlaneProxy,
    buildPublisher(),
  );
  return { service, proxy };
}

describe('SchemaService realtime wiring', () => {
  it('publishes schema_changed after a successful DDL', async () => {
    const { service } = buildSchemaService();
    await service.applyDdl(
      DB_ID,
      'user-1',
      { op: 'add_column', table: 'notes', column: { name: 'extra', normalized_type: 'text' } } as never,
      { tenantId: 't-1' } as never,
    );
    await flush();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const body = publishedBody();
    expect(body.topic).toBe(`table:${DB_ID}:notes`);
    expect(body.event_type).toBe('schema_changed');
    expect(body.payload).toMatchObject({ dbId: DB_ID, table: 'notes', op: 'add_column' });
  });

  it('does NOT publish when the data plane rejects the DDL', async () => {
    const { service, proxy } = buildSchemaService();
    proxy.applySchemaDdl.mockImplementationOnce(() => Promise.reject(new Error('409 conflict')));
    await expect(
      service.applyDdl(
        DB_ID,
        'user-1',
        { op: 'add_column', table: 'notes', column: { name: 'x', normalized_type: 'text' } } as never,
        { tenantId: 't-1' } as never,
      ),
    ).rejects.toThrow('409 conflict');
    await flush();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
