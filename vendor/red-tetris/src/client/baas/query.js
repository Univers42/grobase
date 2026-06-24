// Grobase data-plane queries over /query/v1/<dbId>/tables/<table>. Reads of
// world-readable tables (leaderboard / profiles / standings / tiers) use the app
// key only (`shared:true`); owner-scoped ops keep the user Bearer so the data
// plane stamps/filters the caller's identity (owner_id = user:<sub>).
import config from './config.js';
import { baseHeaders, requestJson } from './http.js';

/** runQuery posts a query-router op (op:list|get|insert|update|delete|...) on a table. */
export function runQuery(dbId, table, body, { shared = false } = {}) {
  return requestJson(`/query/v1/${dbId}/tables/${table}`, {
    method: 'POST',
    headers: baseHeaders(!shared),
    body: JSON.stringify(body),
  });
}

/** listRows runs a list op against the PG mount and returns just the rows. */
export async function listRows(table, body = {}, opts = {}) {
  const r = await runQuery(config.pgDbId, table, { op: 'list', ...body }, opts);
  return r.rows ?? [];
}

/** getRow returns the first row matching filter (or null). */
export async function getRow(table, filter, opts = {}) {
  const rows = await listRows(table, { filter, limit: 1 }, opts);
  return rows[0] ?? null;
}

/** insertRow inserts a row (owner-scoped; the data plane stamps owner_id). */
export async function insertRow(table, data) {
  const r = await runQuery(config.pgDbId, table, { op: 'insert', data });
  return (r.rows && r.rows[0]) ?? r;
}

/** sharedList is a cross-owner read of a world-readable table (app key only). */
export function sharedList(table, body = {}) {
  return listRows(table, body, { shared: true });
}
