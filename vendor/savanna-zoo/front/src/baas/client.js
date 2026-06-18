// ============================================================
// BaaS Client — SDK for mini-BaaS (PostgREST + GoTrue via Kong)
//
// Talks to the real BaaS infrastructure:
//   - REST API:  Kong → PostgREST  (GET/POST/PATCH/DELETE)
//   - Auth:      Kong → GoTrue     (sign-up/sign-in/user)
//   - Realtime:  Kong → Realtime   (SSE)
//   - Storage:   Kong → MinIO      (upload/download)
//   - RPC:       Kong → PostgREST  (stored functions)
// ============================================================

const ENDPOINT = import.meta.env.VITE_BAAS_ENDPOINT || 'http://localhost:8000';
const API_KEY  = import.meta.env.VITE_BAAS_API_KEY  || 'public-anon-key';

// ── PostgREST resource-embedding map ──────────────────────────
// Maps logical join names to PostgREST `select` clauses
const EMBED_MAP = {
  animal_with_keeper: '*,keeper:staff!keeper_id(full_name,role,zone)',
};

// ── Tiny query builder (PostgREST dialect) ────────────────────
class QueryBuilder {
  #table;
  #filters  = [];      // [{column, op, value}]
  #orders   = [];      // ['field.dir']
  #limitN   = null;
  #offsetN  = null;
  #select   = null;    // PostgREST select clause

  constructor(table) {
    this.#table = table;
  }

  /* ── Filter operators ─────────────────────────────────────── */
  eq(field, value)  { this.#filters.push({ field, op: 'eq', value }); return this; }
  neq(field, value) { this.#filters.push({ field, op: 'neq', value }); return this; }
  gt(field, value)  { this.#filters.push({ field, op: 'gt', value }); return this; }
  gte(field, value) { this.#filters.push({ field, op: 'gte', value }); return this; }
  lt(field, value)  { this.#filters.push({ field, op: 'lt', value }); return this; }
  lte(field, value) { this.#filters.push({ field, op: 'lte', value }); return this; }
  in(field, values) {
    const csv = Array.isArray(values) ? values.join(',') : values;
    this.#filters.push({ field, op: 'in', value: `(${csv})` });
    return this;
  }
  like(field, pat)  { this.#filters.push({ field, op: 'like', value: pat }); return this; }
  ilike(field, pat) { this.#filters.push({ field, op: 'ilike', value: pat }); return this; }
  is(field, value)  { this.#filters.push({ field, op: 'is', value }); return this; }

  /* ── Sort / paginate / embed ──────────────────────────────── */
  order(field, dir = 'asc') { this.#orders.push(`${field}.${dir}`); return this; }
  limit(n)   { this.#limitN  = n; return this; }
  offset(n)  { this.#offsetN = n; return this; }
  select(s)  { this.#select  = s; return this; }

  /** Map a logical join name to PostgREST resource embedding */
  join(name) {
    const embed = EMBED_MAP[name];
    if (embed) this.#select = embed;
    return this;
  }

  /* ── Internal HTTP caller ─────────────────────────────────── */
  async #request(method, body) {
    const url = new URL(`/rest/v1/${this.#table}`, ENDPOINT);

    // PostgREST filters: ?field=op.value
    for (const { field, op, value } of this.#filters) {
      url.searchParams.append(field, `${op}.${value}`);
    }

    // Ordering
    if (this.#orders.length) {
      url.searchParams.set('order', this.#orders.join(','));
    }

    // Pagination
    if (this.#limitN  != null) url.searchParams.set('limit',  this.#limitN);
    if (this.#offsetN != null) url.searchParams.set('offset', this.#offsetN);

    // Select / embedding
    if (this.#select) url.searchParams.set('select', this.#select);

    // Headers
    const token = localStorage.getItem('baas_token');
    const headers = {
      'Content-Type': 'application/json',
      apikey: API_KEY,
    };
    if (token) headers.Authorization = `Bearer ${token}`;

    // Prefer header — ask PostgREST to return the affected rows
    if (method !== 'GET') {
      headers.Prefer = 'return=representation';
    }

    const res = await fetch(url, {
      method,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
    });

    if (!res.ok) {
      const err = await res.json().catch(() => ({ message: res.statusText }));
      throw new Error(err.message || err.details || `HTTP ${res.status}`);
    }

    // DELETE / PATCH may return 200 with array; GET returns array
    const text = await res.text();
    return text ? JSON.parse(text) : [];
  }

  /* ── Public CRUD verbs ────────────────────────────────────── */
  get()    { return this.#request('GET'); }

  async single() {
    this.#limitN = 1;
    const rows = await this.#request('GET');
    return Array.isArray(rows) ? rows[0] ?? null : rows;
  }

  async insert(data) {
    const rows = await this.#request('POST', data);
    // PostgREST returns an array; for single insert return the object
    return Array.isArray(rows) ? rows[0] ?? rows : rows;
  }

  async update(data) {
    const rows = await this.#request('PATCH', data);
    return Array.isArray(rows) ? rows[0] ?? rows : rows;
  }

  async remove() {
    const rows = await this.#request('DELETE');
    return Array.isArray(rows) ? rows[0] ?? { deleted: true } : rows;
  }
}

// ── Auth helper (GoTrue via Kong /auth/v1) ────────────────────
const auth = {
  async signIn({ email, password }) {
    const res = await fetch(`${ENDPOINT}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: API_KEY },
      body: JSON.stringify({ email, password }),
    });
    if (!res.ok) throw new Error('Invalid credentials');
    const data = await res.json();
    localStorage.setItem('baas_token', data.access_token);
    localStorage.setItem('baas_refresh', data.refresh_token);
    return data;
  },

  async signOut() {
    const token = localStorage.getItem('baas_token');
    if (token) {
      await fetch(`${ENDPOINT}/auth/v1/logout`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, apikey: API_KEY },
      }).catch(() => {});
    }
    localStorage.removeItem('baas_token');
    localStorage.removeItem('baas_refresh');
  },

  async getUser() {
    const token = localStorage.getItem('baas_token');
    if (!token) return null;
    const res = await fetch(`${ENDPOINT}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${token}`, apikey: API_KEY },
    });
    if (!res.ok) return null;
    return res.json();
  },

  getToken() {
    return localStorage.getItem('baas_token');
  },
};

// ── Realtime subscription (via Kong /realtime/v1) ─────────────
// Graceful fallback: if the realtime service is down (503), stop retrying
// after a few failures to avoid flooding the console and hogging connections.
function subscribe(collection, event, callback) {
  const token = localStorage.getItem('baas_token');
  const params = new URLSearchParams({ event, apikey: API_KEY });
  if (token) params.set('token', token);
  const url = `${ENDPOINT}/realtime/v1/${collection}?${params}`;

  let errorCount = 0;
  const MAX_ERRORS = 2;  // give up after 2 consecutive failures
  let es = null;
  let closed = false;

  function connect() {
    if (closed) return;
    es = new EventSource(url);
    es.onmessage = (e) => {
      errorCount = 0;  // reset on successful message
      try { callback(JSON.parse(e.data)); } catch { /* ignore parse errors */ }
    };
    es.onerror = () => {
      errorCount++;
      if (errorCount >= MAX_ERRORS) {
        // Realtime service is unavailable — stop retrying silently
        es.close();
        if (import.meta.env.DEV) {
          console.warn(`[baas] Realtime unavailable for "${collection}" — polling fallback active`);
        }
      }
    };
  }

  connect();
  return () => { closed = true; if (es) es.close(); };
}

// ── Storage helper (via Kong /storage/v1) ─────────────────────
const storage = {
  getUrl(path) {
    if (!path) return null;
    if (path.startsWith('http')) return path;
    return `${ENDPOINT}/storage/v1${path.startsWith('/') ? '' : '/'}${path}`;
  },

  async upload(bucket, file) {
    const form = new FormData();
    form.append('file', file);
    const token = localStorage.getItem('baas_token');
    const headers = { apikey: API_KEY };
    if (token) headers.Authorization = `Bearer ${token}`;
    const res = await fetch(`${ENDPOINT}/storage/v1/${bucket}`, {
      method: 'POST',
      headers,
      body: form,
    });
    if (!res.ok) throw new Error('Upload failed');
    return res.json();
  },
};

// ── RPC caller (PostgREST stored functions) ───────────────────
async function rpc(fnName, params = {}) {
  const token = localStorage.getItem('baas_token');
  const headers = {
    'Content-Type': 'application/json',
    apikey: API_KEY,
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${ENDPOINT}/rest/v1/rpc/${fnName}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(params),
  });
  if (!res.ok) throw new Error(`RPC ${fnName} failed`);
  return res.json();
}

// ── Public API ────────────────────────────────────────────────
const baas = {
  collection: (name) => new QueryBuilder(name),
  auth,
  storage,
  rpc,
  subscribe,
};

export default baas;
export { auth, storage, rpc, subscribe };
