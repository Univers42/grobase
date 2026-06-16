// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { afterEach, describe, expect, it, jest } from '@jest/globals';
import { ConfigService } from '@nestjs/config';
import { SchemaService } from './schema.service';
import type { QueryService } from './query.service';
import type {
  RustCapabilitiesResponse,
  RustDataPlaneProxy,
  RustSchemaDescriptor,
} from '../proxy/rust-data-plane.proxy';

describe('SchemaService', () => {
  const descriptor = (engine = 'postgresql'): RustSchemaDescriptor => ({
    engine,
    tables: [
      {
        name: 'orders',
        primary_key: ['id'],
        columns: [
          {
            name: 'status',
            native_type: 'order_status',
            normalized_type: 'enum',
            nullable: false,
            default: null,
            enum_values: ['pending', 'paid'],
            references: null,
            inferred: false,
          },
        ],
      },
    ],
  });

  const capabilities = {
    router: {},
    engines: [
      {
        engine: 'postgresql',
        phase: 'pool_v2_active',
        capabilities: { read: true, write: true, ddl: true, introspect: true },
      },
    ],
  } as unknown as RustCapabilitiesResponse;

  function build(configOverrides: Record<string, string> = {}) {
    const config = {
      get: (key: string, def?: string) => configOverrides[key] ?? def,
    } as unknown as ConfigService;
    const query = {
      resolveConnection: jest.fn(async () => ({
        engine: 'postgresql',
        connection_string: 'postgres://example/db',
        isolation: 'shared_rls',
      })),
    };
    const proxy = {
      describeSchema: jest.fn(async () => descriptor()),
      getCapabilitiesCached: jest.fn(async () => capabilities),
      applySchemaDdl: jest.fn(
        async (_ctx: unknown, ddl: { op: string; table: string; column?: unknown }) => ({
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
    );
    return { service, query, proxy };
  }

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('resolves the mount, forwards to the Rust proxy and merges live capabilities', async () => {
    const { service, query, proxy } = build();
    const result = await service.describe('db-1', 'user-1', { tenantId: 't-1' } as never);

    expect(query.resolveConnection).toHaveBeenCalledWith('db-1', 't-1');
    expect(proxy.describeSchema).toHaveBeenCalledWith(
      expect.objectContaining({
        databaseId: 'db-1',
        engine: 'postgresql',
        tenantId: 't-1',
        userId: 'user-1',
        connectionString: 'postgres://example/db',
        isolation: 'shared_rls',
      }),
    );
    expect(result).toEqual({
      dbId: 'db-1',
      engine: 'postgresql',
      capabilities: capabilities.engines[0].capabilities,
      tables: descriptor().tables,
    });
  });

  it('serves a second call within the TTL from cache (single upstream fetch)', async () => {
    const { service, proxy } = build();
    const first = await service.describe('db-1', 'user-1', { tenantId: 't-1' } as never);
    const second = await service.describe('db-1', 'user-1', { tenantId: 't-1' } as never);
    expect(proxy.describeSchema).toHaveBeenCalledTimes(1);
    expect(second).toEqual(first);
  });

  it('refetches after the TTL expires', async () => {
    const { service, proxy } = build({ QUERY_ROUTER_SCHEMA_CACHE_TTL_MS: '60000' });
    const start = Date.now();
    const now = jest.spyOn(Date, 'now');

    now.mockReturnValue(start);
    await service.describe('db-1', 'user-1', { tenantId: 't-1' } as never);
    // Still inside the window → cached.
    now.mockReturnValue(start + 59_000);
    await service.describe('db-1', 'user-1', { tenantId: 't-1' } as never);
    expect(proxy.describeSchema).toHaveBeenCalledTimes(1);
    // Past the window → expired entry is dropped and refetched.
    now.mockReturnValue(start + 61_000);
    await service.describe('db-1', 'user-1', { tenantId: 't-1' } as never);
    expect(proxy.describeSchema).toHaveBeenCalledTimes(2);
  });

  it('isolates cache entries by tenant (no cross-tenant cache hits)', async () => {
    const { service, proxy } = build();
    await service.describe('db-1', 'user-a', { tenantId: 't-a' } as never);
    await service.describe('db-1', 'user-b', { tenantId: 't-b' } as never);
    // Same dbId but different tenants → two distinct upstream fetches.
    expect(proxy.describeSchema).toHaveBeenCalledTimes(2);
    // And a repeat for tenant A still hits A's cache.
    await service.describe('db-1', 'user-a', { tenantId: 't-a' } as never);
    expect(proxy.describeSchema).toHaveBeenCalledTimes(2);
  });

  it('evicts the oldest entry once the cache cap is reached', async () => {
    const { service, proxy } = build({ QUERY_ROUTER_SCHEMA_CACHE_MAX_ENTRIES: '2' });
    await service.describe('db-1', 'u', { tenantId: 't-1' } as never); // entry 1 (oldest)
    await service.describe('db-2', 'u', { tenantId: 't-1' } as never); // entry 2 → at cap
    await service.describe('db-3', 'u', { tenantId: 't-1' } as never); // evicts db-1
    expect(proxy.describeSchema).toHaveBeenCalledTimes(3);
    // db-3 and db-2... db-2 was evicted? No: oldest (db-1) was. db-2 still cached.
    await service.describe('db-2', 'u', { tenantId: 't-1' } as never);
    expect(proxy.describeSchema).toHaveBeenCalledTimes(3);
    // db-1 was evicted → refetch.
    await service.describe('db-1', 'u', { tenantId: 't-1' } as never);
    expect(proxy.describeSchema).toHaveBeenCalledTimes(4);
  });

  it('still serves the schema when the capabilities lookup fails', async () => {
    const { service, proxy } = build();
    proxy.getCapabilitiesCached.mockImplementation(() =>
      Promise.reject(new Error('capabilities down')),
    );
    const result = await service.describe('db-1', 'user-1', { tenantId: 't-1' } as never);
    expect(result.capabilities).toBeNull();
    expect(result.tables).toHaveLength(1);
  });

  it('falls back to userId as the tenant scope when no identity is present', async () => {
    const { service, query } = build();
    await service.describe('db-1', 'user-1');
    expect(query.resolveConnection).toHaveBeenCalledWith('db-1', 'user-1');
  });

  // ── M22 step 2: applyDdl (POST /:dbId/schema/ddl) ──────────────────────────

  describe('applyDdl', () => {
    const identity = { tenantId: 't-1' } as never;

    it('refuses destructive ops without confirm: true (no proxy call)', async () => {
      const { service, proxy } = build();
      for (const op of ['drop_column', 'drop_table'] as const) {
        await expect(
          service.applyDdl('db-1', 'user-1', { op, table: 'orders', column_name: 'x' } as never, identity),
        ).rejects.toMatchObject({ status: 400 });
      }
      expect(proxy.applySchemaDdl).not.toHaveBeenCalled();
      // …and proceeds once confirmed.
      const result = await service.applyDdl(
        'db-1',
        'user-1',
        { op: 'drop_column', table: 'orders', column_name: 'status', confirm: true } as never,
        identity,
      );
      expect(proxy.applySchemaDdl).toHaveBeenCalledTimes(1);
      expect(result).toEqual({ op: 'drop_column', table: 'orders', status: 'applied', dbId: 'db-1' });
    });

    it('forwards the proxy call with the resolved mount context and full wire ddl', async () => {
      const { service, proxy, query } = build();
      await service.applyDdl(
        'db-1',
        'user-1',
        {
          op: 'add_column',
          table: 'orders',
          column: { name: 'qty', normalized_type: 'integer' },
        } as never,
        identity,
      );
      expect(query.resolveConnection).toHaveBeenCalledWith('db-1', 't-1');
      expect(proxy.applySchemaDdl).toHaveBeenCalledWith(
        expect.objectContaining({
          databaseId: 'db-1',
          engine: 'postgresql',
          tenantId: 't-1',
          userId: 'user-1',
          connectionString: 'postgres://example/db',
          isolation: 'shared_rls',
        }),
        {
          op: 'add_column',
          table: 'orders',
          // optional attributes are defaulted into a FULL wire def
          column: { name: 'qty', normalized_type: 'integer', nullable: true, default: null, enum_values: null },
          column_name: null,
          columns: null,
          primary_key: null,
        },
      );
    });

    it('alter_column_type composes the FULL target def, preserving current attributes', async () => {
      const { service, proxy } = build();
      // current `status` column: nullable=false, default=null, enum ['pending','paid']
      await service.applyDdl(
        'db-1',
        'user-1',
        {
          op: 'alter_column_type',
          table: 'orders',
          column: { name: 'status', normalized_type: 'text' },
        } as never,
        identity,
      );
      const [, ddl] = proxy.applySchemaDdl.mock.calls[0];
      expect(ddl.column).toEqual({
        name: 'status',
        normalized_type: 'text', // requested type wins
        nullable: false, // preserved from the current column
        default: null, // preserved
        enum_values: ['pending', 'paid'], // preserved
      });
      // …and an explicit override wins over the current value.
      await service.applyDdl(
        'db-1',
        'user-1',
        {
          op: 'alter_column_type',
          table: 'orders',
          column: { name: 'status', normalized_type: 'text', nullable: true, enum_values: null },
        } as never,
        identity,
      );
      const [, overridden] = proxy.applySchemaDdl.mock.calls[1];
      expect(overridden.column).toEqual({
        name: 'status',
        normalized_type: 'text',
        nullable: true,
        default: null,
        enum_values: null,
      });
    });

    it('alter_column_type 404s on an unknown table or column', async () => {
      const { service, proxy } = build();
      await expect(
        service.applyDdl(
          'db-1',
          'user-1',
          { op: 'alter_column_type', table: 'ghosts', column: { name: 'x', normalized_type: 'text' } } as never,
          identity,
        ),
      ).rejects.toMatchObject({ status: 404 });
      await expect(
        service.applyDdl(
          'db-1',
          'user-1',
          { op: 'alter_column_type', table: 'orders', column: { name: 'ghost', normalized_type: 'text' } } as never,
          identity,
        ),
      ).rejects.toMatchObject({ status: 404 });
      expect(proxy.applySchemaDdl).not.toHaveBeenCalled();
    });

    it('busts the schema cache entry after a successful DDL', async () => {
      const { service, proxy } = build();
      await service.describe('db-1', 'user-1', identity);
      await service.describe('db-1', 'user-1', identity);
      expect(proxy.describeSchema).toHaveBeenCalledTimes(1); // cached
      await service.applyDdl(
        'db-1',
        'user-1',
        { op: 'add_column', table: 'orders', column: { name: 'qty', normalized_type: 'integer' } } as never,
        identity,
      );
      await service.describe('db-1', 'user-1', identity);
      expect(proxy.describeSchema).toHaveBeenCalledTimes(2); // cache busted → refetch
      // another tenant's entry is untouched by the bust (keyed per tenant+db).
      await service.describe('db-1', 'user-2', { tenantId: 't-2' } as never);
      await service.describe('db-1', 'user-2', { tenantId: 't-2' } as never);
      expect(proxy.describeSchema).toHaveBeenCalledTimes(3);
    });

    it('does not bust the cache when the data plane rejects the DDL', async () => {
      const { service, proxy } = build();
      await service.describe('db-1', 'user-1', identity);
      proxy.applySchemaDdl.mockImplementationOnce(() => Promise.reject(new Error('409 conflict')));
      await expect(
        service.applyDdl(
          'db-1',
          'user-1',
          { op: 'add_column', table: 'orders', column: { name: 'qty', normalized_type: 'integer' } } as never,
          identity,
        ),
      ).rejects.toThrow('409 conflict');
      await service.describe('db-1', 'user-1', identity);
      // still cached — nothing changed on the engine.
      expect(proxy.describeSchema).toHaveBeenCalledTimes(1);
    });
  });
});
