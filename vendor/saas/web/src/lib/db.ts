// db.ts — engine-agnostic CRUD against a Grobase mount through the gateway:
// POST /query/v1/<dbId>/tables/<table> with {op,filter,data,sort,limit}. Headers:
// apikey=Kong anon (clears key-auth) + X-Baas-Api-Key=mbk_ (resolves the tenant)
// + Authorization=Bearer <user JWT> when signed in. The data plane owner-scopes
// PER REQUEST off the JWT: an `admin` JWT triggers the F2 owner-scope bypass and
// reads/writes across the (api-key-owned) seeded rows; a customer JWT scopes to
// `user:<sub>` and sees only its own. WITHOUT the JWT the app key is a public
// shared identity, so omitting it would expose every tenant's data to anyone
// holding the (browser-shipped) key — the JWT is the server-enforced authority.

import type { BaasConfig } from './config';
import type { Filter } from './filters';
import { eq } from './filters';
import { isRecord, asNumber, asArray } from './guards';

/** Row is a generic data-plane record. */
export type Row = Record<string, unknown>;

/** Sort is the data-plane sort spec ({col: 'asc' | 'desc'}). */
export type Sort = Record<string, 'asc' | 'desc'>;

/** ListOptions narrows a list query. */
export type ListOptions = { where?: Record<string, unknown>; filter?: Filter; limit?: number; offset?: number; sort?: Sort };

/** QueryResult mirrors the {rows,rowCount} envelope returned by the query router.
 *  NOTE: rowCount is the count of rows in THIS page (== rows.length under a limit),
 *  not the grand total — the router has no count op. For a real total page with
 *  count()/listAll() (see the data-plane LIMIT_MAX cap). */
export type QueryResult = { rows: Row[]; rowCount: number };

/** Db is the CRUD surface bound to one mount. */
export type Db = {
  list: (table: string, opts?: ListOptions) => Promise<QueryResult>;
  listAll: (table: string, opts?: ListOptions) => Promise<Row[]>;
  count: (table: string, opts?: ListOptions) => Promise<number>;
  get: (table: string, where: Record<string, unknown>) => Promise<Row | null>;
  insert: (table: string, data: Row) => Promise<Row | null>;
  update: (table: string, data: Row, where: Record<string, unknown>) => Promise<QueryResult>;
  upsert: (table: string, data: Row) => Promise<QueryResult>;
  remove: (table: string, where: Record<string, unknown>) => Promise<QueryResult>;
};

/** LIMIT_MAX is the data plane's hard per-request row cap (a higher limit 400s),
 *  so totals over a large set must be paged with offset rather than one big read. */
export const LIMIT_MAX = 500;

/** PAGE_ALL_CAP bounds offset paging so a runaway table cannot loop unbounded;
 *  it covers the seeded scale (~200 users / ~600 txns) with headroom. */
const PAGE_ALL_CAP = 10000;

/** toResult narrows a query-router response body to a {rows,rowCount}. */
function toResult(body: unknown): QueryResult {
  if (!isRecord(body)) return { rows: [], rowCount: 0 };
  const rows = asArray(body.rows).filter(isRecord);
  const rowCount = asNumber(body.rowCount, rows.length);
  return { rows, rowCount };
}

/** errorMessage extracts a query error string from a response body. */
function errorMessage(body: unknown, table: string, status: number): string {
  if (isRecord(body) && typeof (body.message ?? body.error) === 'string') {
    return String(body.message ?? body.error);
  }
  return `query ${table} failed (${status})`;
}

/** createDb returns CRUD bound to (config, dbId). `token` supplies the current
 * user JWT so every call is owner-scoped per request (admin → F2 bypass over the
 * seeded rows; customer → own rows only). It is read at call time so a sign-in
 * after construction takes effect (see the header note). */
export function createDb(config: BaasConfig, dbId: string, token: () => string): Db {
  const baseUrl = `${config.url}/query/v1/${dbId}/tables`;

  async function call(table: string, payload: Record<string, unknown>): Promise<QueryResult> {
    const headers: Record<string, string> = {
      apikey: config.anonKey,
      'X-Baas-Api-Key': config.apiKey,
      'Content-Type': 'application/json',
    };
    const jwt = token();
    if (jwt) headers.Authorization = `Bearer ${jwt}`;
    const res = await fetch(`${baseUrl}/${table}`, { method: 'POST', headers, body: JSON.stringify(payload) });
    const body: unknown = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(errorMessage(body, table, res.status));
    return toResult(body);
  }

  function list(table: string, { where, filter, limit, offset, sort }: ListOptions = {}): Promise<QueryResult> {
    const payload: Record<string, unknown> = { op: 'list', filter: filter ?? eq(where ?? {}) };
    if (limit) payload.limit = limit;
    if (offset) payload.offset = offset;
    if (sort) payload.sort = sort;
    return call(table, payload);
  }

  async function pageAll(table: string, opts: ListOptions): Promise<Row[]> {
    const sort = opts.sort ?? { id: 'asc' };
    const out: Row[] = [];
    for (let offset = 0; offset < PAGE_ALL_CAP; offset += LIMIT_MAX) {
      const { rows } = await list(table, { ...opts, sort, limit: LIMIT_MAX, offset });
      out.push(...rows);
      if (rows.length < LIMIT_MAX) break;
    }
    return out;
  }

  return {
    list,
    listAll: (table, opts = {}) => pageAll(table, opts),
    count: (table, opts = {}) => pageAll(table, opts).then((rows) => rows.length),
    get: (table, where) =>
      call(table, { op: 'list', filter: eq(where), limit: 1 }).then((r) => r.rows[0] ?? null),
    insert: (table, data) => call(table, { op: 'insert', data }).then((r) => r.rows[0] ?? null),
    update: (table, data, where) => call(table, { op: 'update', data, filter: eq(where) }),
    upsert: (table, data) => call(table, { op: 'upsert', data }),
    remove: (table, where) => call(table, { op: 'delete', filter: eq(where) }),
  };
}
