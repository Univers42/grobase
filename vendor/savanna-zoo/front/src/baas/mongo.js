// ============================================================
// Mongo Journal client — the Savanna Zoo "Visit Journal" lives in
// MongoDB, reached through Grobase's query-router (NOT PostgREST):
//   POST /query/v1/{dbId}/tables/{collection}  { op, data | filter }
//
// This showcases the document engine alongside the Postgres core from
// one frontend. Every call carries the app key (X-Baas-Api-Key) AND the
// visitor's GoTrue Bearer, so the data plane stamps owner_id=user:<sub>
// and owner-scopes reads — each visitor sees only their own journal.
// dbId + app key are injected by scripts/seed/savanna-tenant.sh.
// ============================================================
const API_KEY = import.meta.env.VITE_BAAS_API_KEY || 'public-anon-key';
const APP_KEY = import.meta.env.VITE_BAAS_APP_KEY || '';
const MONGO_DBID = import.meta.env.VITE_BAAS_MONGO_DBID || '';
const ENDPOINT = import.meta.env.VITE_BAAS_ENDPOINT ?? '';
const BASE = ENDPOINT || (typeof window !== 'undefined' ? window.location.origin : 'http://localhost:8000');

const COLLECTION = 'observations';

/** journalReady — false when the mongo mount wasn't provisioned (env absent). */
export const journalReady = Boolean(APP_KEY && MONGO_DBID);

/** mq sends one query-router op to the journal collection, returns its rows. */
async function mq(body) {
  if (!journalReady) throw new Error('Journal (MongoDB) is not provisioned');
  const token = localStorage.getItem('baas_token');
  if (!token) throw new Error('Sign in to use your journal');
  const res = await fetch(`${BASE}/query/v1/${MONGO_DBID}/tables/${COLLECTION}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: API_KEY,
      'X-Baas-Api-Key': APP_KEY,
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = Array.isArray(data.message) ? data.message.join(', ') : data.message;
    throw new Error(msg || data.error || `Journal request failed (${res.status})`);
  }
  return data.rows || [];
}

const journal = {
  /** List the signed-in visitor's observations, newest first. */
  // The query-router sort dialect is { field: 'asc'|'desc' } (not Mongo's 1/-1).
  list: () => mq({ op: 'list', sort: { created_at: 'desc' }, limit: 200 }),

  /** Add an observation (owner stamped by the data plane from the JWT). */
  add: ({ animal, zone, note, rating, tags }) =>
    mq({
      op: 'insert',
      data: {
        animal,
        zone: zone || null,
        note: note || '',
        rating: Number(rating) || 5,
        tags: Array.isArray(tags) ? tags : [],
        created_at: new Date().toISOString(),
      },
    }),

  /** Remove one of the visitor's own observations by _id. */
  remove: (id) => mq({ op: 'delete', filter: { _id: { $eq: id } } }),
};

export default journal;
