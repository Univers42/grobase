// ============================================================
// Mongo client — Grobase query-router for the 'surf_sessions' collection.
//   POST /query/v1/<dbId>/tables/surf_sessions
//   headers: apikey (anon) + X-Baas-Api-Key (app key) + Bearer (owner JWT)
//   ops: insert / list[{op,sort,limit}] / delete
// The data plane stamps owner_id=user:<sub> from the Bearer, so each surfer's
// bitacora is private to them — a plain list returns only their own sessions.
// ============================================================
const ENDPOINT = import.meta.env.VITE_BAAS_ENDPOINT ?? '';
const ANON_KEY = import.meta.env.VITE_BAAS_API_KEY || 'public-anon-key';
const APP_KEY = import.meta.env.VITE_BAAS_APP_KEY || '';
const DB_ID = import.meta.env.VITE_BAAS_MONGO_DBID || '';
const COLLECTION = 'surf_sessions';

const BASE = ENDPOINT || (typeof window !== 'undefined' ? window.location.origin : 'http://localhost:5183');

// journalReady — both the mongo mount id and the app key must be present, or the
// bitacora UI shows a friendly note instead of failing requests.
export const journalReady = Boolean(DB_ID && APP_KEY);

async function call(op) {
  const token = localStorage.getItem('baas_token');
  const headers = { 'Content-Type': 'application/json', apikey: ANON_KEY, 'X-Baas-Api-Key': APP_KEY };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${BASE}/query/v1/${DB_ID}/tables/${COLLECTION}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(op),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({ message: res.statusText }));
    throw new Error(err.message || err.error || `HTTP ${res.status}`);
  }
  return res.json();
}

/** Insert one surf-session document (owner stamped from the Bearer). */
export function insert(data) {
  return call({ op: 'insert', data: { ...data, created_at: new Date().toISOString() } });
}

/** List the caller's sessions newest-first (sort dialect {field:'desc'}). */
export async function list(limit = 100) {
  const out = await call({ op: 'list', sort: { created_at: 'desc' }, limit });
  return out?.rows ?? out?.data ?? (Array.isArray(out) ? out : []);
}

/** Delete sessions matching a filter (e.g. by _id) — owner-scoped. */
export function remove(filter) {
  return call({ op: 'delete', filter });
}

export default { insert, list, remove, journalReady };
