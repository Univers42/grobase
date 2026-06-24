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

const ENDPOINT = import.meta.env.VITE_BAAS_ENDPOINT ?? '';
const API_KEY  = import.meta.env.VITE_BAAS_API_KEY  || 'public-anon-key';

// When ENDPOINT is empty the app is served behind a same-origin reverse proxy
// (grobase/serve.mjs) that forwards /rest /auth /realtime /storage to Kong —
// so the browser only ever talks to its own origin (no CORS, CSP 'self' ok).
const BASE = ENDPOINT || (typeof window !== 'undefined' ? window.location.origin : 'http://localhost:8000');

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
    const url = new URL(`/rest/v1/${this.#table}`, BASE);

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
  /** Visitor self-signup — role lands in user_metadata.role (drives RLS). */
  async signUp({ email, password, fullName }) {
    const res = await fetch(`${BASE}/auth/v1/signup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: API_KEY },
      body: JSON.stringify({
        email,
        password,
        data: { full_name: fullName || email.split('@')[0], role: 'visitor' },
      }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.msg || data.error_description || 'Sign-up failed');
    // Autoconfirm is on → signup returns a session immediately.
    if (data.access_token) {
      localStorage.setItem('baas_token', data.access_token);
      localStorage.setItem('baas_refresh', data.refresh_token);
    }
    return data;
  },

  async signIn({ email, password }) {
    const res = await fetch(`${BASE}/auth/v1/token?grant_type=password`, {
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
      await fetch(`${BASE}/auth/v1/logout`, {
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
    const res = await fetch(`${BASE}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${token}`, apikey: API_KEY },
    });
    if (!res.ok) return null;
    return res.json();
  },

  getToken() {
    return localStorage.getItem('baas_token');
  },
};

// ── Realtime subscription (Grobase agnostic-realtime, WebSocket) ──────────────
// Grobase's realtime plane is a WebSocket gateway at /realtime/v1/ws, fed by a
// PostgreSQL LISTEN/NOTIFY producer: a trigger on every public table publishes
// each change on topic `pg/<table>/<operation>` (inserted|updated|deleted) with
// the FULL ROW in event.payload.data — so a PostgREST write fires a live event
// with no polling. Protocol: AUTH → AUTH_OK → SUBSCRIBE{sub_id,topic} → EVENT.
const OP_TOPIC = { insert: ['inserted'], update: ['updated'], delete: ['deleted'] };

function subscribe(collection, event, callback) {
  const token = localStorage.getItem('baas_token') || API_KEY;
  const ops = OP_TOPIC[event] || ['inserted', 'updated', 'deleted']; // '*' or unknown → all
  const topics = ops.map((op) => `pg/${collection}/${op}`);
  const wsUrl =
    `${BASE.replace(/^http/, 'ws')}/realtime/v1/ws` +
    `?apikey=${encodeURIComponent(API_KEY)}&access_token=${encodeURIComponent(token)}`;

  let ws = null;
  let closed = false;
  let retry = 0;

  function connect() {
    if (closed) return;
    ws = new WebSocket(wsUrl);
    ws.onopen = () => { retry = 0; ws.send(JSON.stringify({ type: 'AUTH', token })); };
    ws.onmessage = (e) => {
      let msg;
      try { msg = JSON.parse(e.data); } catch { return; }
      if (msg.type === 'AUTH_OK') {
        topics.forEach((topic, i) =>
          ws.send(JSON.stringify({ type: 'SUBSCRIBE', sub_id: `${collection}-${i}`, topic })));
      } else if (msg.type === 'EVENT' || msg.type === 'ROW_CHANGED') {
        const row = msg.event?.payload?.data ?? msg.event?.payload ?? msg.payload ?? {};
        try { callback(row); } catch { /* ignore callback errors */ }
      }
    };
    ws.onerror = () => { try { ws.close(); } catch { /* noop */ } };
    ws.onclose = () => {
      if (closed) return;
      retry = Math.min(retry + 1, 6);
      setTimeout(connect, 500 * retry); // backoff up to 3s
    };
  }

  connect();
  return () => { closed = true; if (ws) try { ws.close(); } catch { /* noop */ } };
}

// ── Storage helper (via Kong /storage/v1) ─────────────────────
const storage = {
  getUrl(path) {
    if (!path) return null;
    if (path.startsWith('http')) return path;
    return `${BASE}/storage/v1${path.startsWith('/') ? '' : '/'}${path}`;
  },

  async upload(bucket, file) {
    const form = new FormData();
    form.append('file', file);
    const token = localStorage.getItem('baas_token');
    const headers = { apikey: API_KEY };
    if (token) headers.Authorization = `Bearer ${token}`;
    const res = await fetch(`${BASE}/storage/v1/${bucket}`, {
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
  const res = await fetch(`${BASE}/rest/v1/rpc/${fnName}`, {
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
