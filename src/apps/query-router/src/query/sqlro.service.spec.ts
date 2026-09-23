/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sqlro.service.spec.ts                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/23 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/23 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// The repo's jest setup does not ship `@types/jest` — import globals explicitly.
import { beforeEach, describe, expect, it, jest } from '@jest/globals';
import { BadRequestException, NotFoundException } from '@nestjs/common';
import type { ConfigService } from '@nestjs/config';

// The runner opens a real pg Pool per request; a double lets the suite assert
// the pool lifecycle (connect / release / end) without a live Postgres.
jest.mock('pg', () => ({ Pool: jest.fn() }));
import { Pool } from 'pg';
import { SqlRoService } from './sqlro.service';
import type { AdapterResponse, QueryService } from './query.service';

const OWN = 'tenant-a';
const FOREIGN = 'tenant-b';
const DB = '11111111-1111-4111-8111-111111111111';
const STATIC_DB = '22222222-2222-4222-8222-222222222222';
const UNKNOWN_DB = '33333333-3333-4333-8333-333333333333';
const DSN = 'postgres://owner@own-db:5432/app';
const SELECT = 'SELECT 1 AS one';

type Rows = Record<string, unknown>[];

/** A mount the registry would return for an external, tenant-owned database. */
function ownedMount(overrides: Partial<AdapterResponse> = {}): AdapterResponse {
  return { engine: 'postgresql', connection_string: DSN, isolation: 'tenant_owned', ...overrides };
}

/**
 * QueryService double. `registry` is keyed `${tenantId}:${dbId}` — the same
 * tenant scope adapter-registry applies to `/connect` (unknown OR foreign → the
 * NotFoundException QueryService maps its 404 to). A static dbId resolves with
 * NO tenant check, exactly like the real `DATA_PLANE_MOUNTS` bypass.
 */
function queryDouble(registry: Record<string, AdapterResponse>, staticIds: string[] = []) {
  return {
    isStaticMount: jest.fn((dbId: string) => staticIds.includes(dbId)),
    resolveConnection: jest.fn(async (dbId: string, tenantId: string) => {
      if (staticIds.includes(dbId)) return ownedMount();
      const mount = registry[`${tenantId}:${dbId}`];
      if (!mount) {
        throw new NotFoundException(`Database mount '${dbId}' was not found for this tenant.`);
      }
      return mount;
    }),
  };
}

type QueryDouble = ReturnType<typeof queryDouble>;

/** Build the service under test with QUERY_ROUTER_SQL_RO set to `flag`. */
function build(query: QueryDouble, flag?: string): SqlRoService {
  const config = {
    get: (key: string, def?: string) => (key === 'QUERY_ROUTER_SQL_RO' ? (flag ?? def) : def),
  } as unknown as ConfigService;
  return new SqlRoService(config, query as unknown as QueryService);
}

interface PoolOptions {
  connectError?: Error;
  statementError?: Error;
  rows?: Rows;
}

/** Install a pg Pool double for the next `new Pool(...)`; returns its handles. */
function installPool(opts: PoolOptions = {}) {
  const client = {
    query: jest.fn(async (sql: string): Promise<{ rows: Rows }> => {
      if (sql !== SELECT) return { rows: [] };
      if (opts.statementError) throw opts.statementError;
      return { rows: opts.rows ?? [{ one: 1 }] };
    }),
    release: jest.fn(),
  };
  const pool = {
    connect: jest.fn(async () => {
      if (opts.connectError) throw opts.connectError;
      return client;
    }),
    end: jest.fn(async () => undefined),
  };
  jest.mocked(Pool).mockImplementation(() => pool as unknown as jest.Mocked<Pool>);
  return { pool, client };
}

/** Await `promise`, returning what it rejected with (undefined if it resolved). */
async function rejection(promise: Promise<unknown>): Promise<unknown> {
  return promise.then(
    () => undefined,
    (error: unknown) => error,
  );
}

/** Assert a rejection is the bare 404 the flag-OFF endpoint returns (no existence leak). */
async function expectBare404(promise: Promise<unknown>): Promise<void> {
  const error = await rejection(promise);
  expect(error).toBeInstanceOf(NotFoundException);
  expect((error as NotFoundException).getResponse()).toEqual(new NotFoundException().getResponse());
}

describe('SqlRoService', () => {
  beforeEach(() => {
    jest.mocked(Pool).mockReset();
  });

  it('flag OFF → bare 404, the mount is never resolved (unchanged behavior)', async () => {
    const query = queryDouble({ [`${OWN}:${DB}`]: ownedMount() });
    await expectBare404(build(query).run(DB, OWN, SELECT));
    await expectBare404(build(query, '0').run(DB, OWN, SELECT));
    expect(query.isStaticMount).not.toHaveBeenCalled();
    expect(query.resolveConnection).not.toHaveBeenCalled();
    expect(Pool).not.toHaveBeenCalled();
  });

  it('own tenant_owned mount → rows from a READ ONLY txn on its DSN; pool released + ended', async () => {
    const query = queryDouble({ [`${OWN}:${DB}`]: ownedMount() });
    const { pool, client } = installPool({ rows: [{ one: 1 }] });
    const result = await build(query, '1').run(DB, OWN, SELECT);
    expect(result).toEqual({ rows: [{ one: 1 }], truncated: false });
    expect(query.resolveConnection).toHaveBeenCalledWith(DB, OWN);
    expect(Pool).toHaveBeenCalledWith(expect.objectContaining({ connectionString: DSN, max: 1 }));
    const sent = client.query.mock.calls.map(([sql]) => sql);
    expect(sent.slice(0, 2)).toEqual(['BEGIN', 'SET TRANSACTION READ ONLY']);
    expect(sent).toContain(SELECT);
    expect(client.release).toHaveBeenCalledTimes(1);
    expect(pool.end).toHaveBeenCalledTimes(1);
  });

  it('foreign tenant mount → the same bare 404 as an unknown dbId', async () => {
    const query = queryDouble({ [`${FOREIGN}:${DB}`]: ownedMount() });
    await expectBare404(build(query, '1').run(DB, OWN, SELECT));
    await expectBare404(build(query, '1').run(UNKNOWN_DB, OWN, SELECT));
    expect(query.resolveConnection).toHaveBeenCalledWith(DB, OWN);
    expect(Pool).not.toHaveBeenCalled();
  });

  it('static DATA_PLANE_MOUNTS dbId → bare 404 without resolving (no owner to check)', async () => {
    const query = queryDouble({}, [STATIC_DB]);
    await expectBare404(build(query, '1').run(STATIC_DB, OWN, SELECT));
    expect(query.isStaticMount).toHaveBeenCalledWith(STATIC_DB);
    expect(query.resolveConnection).not.toHaveBeenCalled();
    expect(Pool).not.toHaveBeenCalled();
  });

  it.each(['', '   ', undefined])(
    'own tenant_owned mount with no inline DSN (%p, a Vault cred-ref) → bare 404, no connection opened',
    async (dsn) => {
      const credRef = ownedMount({ connection_string: dsn as string });
      const query = queryDouble({ [`${OWN}:${DB}`]: credRef });
      await expectBare404(build(query, '1').run(DB, OWN, SELECT));
      expect(Pool).not.toHaveBeenCalled();
    },
  );

  it('flag value is trimmed like the other routers (" 1 " is ON)', async () => {
    const query = queryDouble({ [`${OWN}:${DB}`]: ownedMount() });
    installPool({ rows: [{ one: 1 }] });
    await expect(build(query, ' 1 ').run(DB, OWN, SELECT)).resolves.toEqual({
      rows: [{ one: 1 }],
      truncated: false,
    });
  });

  it('own read_scoped mount → bare 404, no connection opened', async () => {
    const readScoped = ownedMount({ capability_overrides: { read_scoped: true } });
    const query = queryDouble({ [`${OWN}:${DB}`]: readScoped });
    await expectBare404(build(query, '1').run(DB, OWN, SELECT));
    expect(Pool).not.toHaveBeenCalled();
  });

  it.each(['shared_rls', 'schema_per_tenant', 'db_per_tenant', 'typo', undefined])(
    'own mount owner-scoped per request (isolation %s) → bare 404',
    async (isolation) => {
      const query = queryDouble({ [`${OWN}:${DB}`]: ownedMount({ isolation }) });
      await expectBare404(build(query, '1').run(DB, OWN, SELECT));
      expect(Pool).not.toHaveBeenCalled();
    },
  );

  it('connect failure → the pool is still ended and the error propagates unmapped', async () => {
    const query = queryDouble({ [`${OWN}:${DB}`]: ownedMount() });
    const refused = new Error('connect ECONNREFUSED 10.0.0.9:5432');
    const { pool, client } = installPool({ connectError: refused });
    expect(await rejection(build(query, '1').run(DB, OWN, SELECT))).toBe(refused);
    expect(pool.connect).toHaveBeenCalledTimes(1);
    expect(pool.end).toHaveBeenCalledTimes(1);
    expect(client.release).not.toHaveBeenCalled();
  });

  it('statement failure → 400 with the query error, rolled back, released and ended', async () => {
    const query = queryDouble({ [`${OWN}:${DB}`]: ownedMount() });
    const readOnly = new Error('cannot execute INSERT in a read-only transaction');
    const { pool, client } = installPool({ statementError: readOnly });
    const error = await rejection(build(query, '1').run(DB, OWN, SELECT));
    expect(error).toBeInstanceOf(BadRequestException);
    expect((error as BadRequestException).message).toBe(readOnly.message);
    expect(client.query.mock.calls.map(([sql]) => sql)).toContain('ROLLBACK');
    expect(client.release).toHaveBeenCalledTimes(1);
    expect(pool.end).toHaveBeenCalledTimes(1);
  });

  it('own tenant_owned non-postgres mount → 400 (postgres only), no connection opened', async () => {
    const query = queryDouble({ [`${OWN}:${DB}`]: ownedMount({ engine: 'mysql' }) });
    const error = await rejection(build(query, '1').run(DB, OWN, SELECT));
    expect(error).toBeInstanceOf(BadRequestException);
    expect(Pool).not.toHaveBeenCalled();
  });

  it('multi-statement SQL → 400 before any mount is resolved', async () => {
    const query = queryDouble({ [`${OWN}:${DB}`]: ownedMount() });
    const error = await rejection(build(query, '1').run(DB, OWN, 'SELECT 1; SELECT 2'));
    expect(error).toBeInstanceOf(BadRequestException);
    expect(query.resolveConnection).not.toHaveBeenCalled();
  });
});
