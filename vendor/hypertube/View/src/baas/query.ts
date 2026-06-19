import type { BaasConfig } from './config.ts';
import { baseHeaders, requestJson } from './http.ts';

export type QueryOp = 'list' | 'get' | 'insert' | 'update' | 'delete' | 'upsert' | 'aggregate';

export type QueryBody = {
  op: QueryOp;
  data?: Record<string, unknown>;
  filter?: Record<string, Record<string, unknown>>;
  sort?: Record<string, 'asc' | 'desc'>;
  limit?: number;
  offset?: number;
};

export type QueryResult<T> = { rows?: T[]; rowCount?: number; affected_rows?: number };

/** Read mode: `shared` reads a cross-owner catalog (movies/comments/profiles)
 *  via the app key only — the reliable public path; owner-scoped ops keep the
 *  user Bearer so the data plane stamps/filters the caller's identity. */
export type QueryOpts = { shared?: boolean };

/** runQuery posts a query-router op against a table on a given mount (dbId). */
export function runQuery<T>(cfg: BaasConfig, dbId: string, table: string, body: QueryBody, opts: QueryOpts = {}): Promise<QueryResult<T>> {
  return requestJson<QueryResult<T>>(`/query/v1/${dbId}/tables/${table}`, {
    method: 'POST',
    headers: baseHeaders(cfg, !opts.shared),
    body: JSON.stringify(body),
  });
}

/** listRows runs a list op and returns just the rows (empty array when none). */
export async function listRows<T>(cfg: BaasConfig, dbId: string, table: string, body: Omit<QueryBody, 'op'>, opts: QueryOpts = {}): Promise<T[]> {
  const r = await runQuery<T>(cfg, dbId, table, { op: 'list', ...body }, opts);
  return r.rows ?? [];
}
