// ============================================================
// BaaS Client — Grobase (PostgREST + GoTrue via Kong)
//   - REST:  Kong → PostgREST (GET/POST/PATCH/DELETE)
//   - Auth:  Kong → GoTrue (sign-up/sign-in/user)
// Served same-origin behind grobase/serve.mjs, so BASE falls back to the
// page origin (no CORS, CSP 'self'). Catalog reads send only the apikey;
// owner-scoped writes also attach the user's Bearer (localStorage token).
// ============================================================

const ENDPOINT = import.meta.env.VITE_BAAS_ENDPOINT ?? '';
const API_KEY = import.meta.env.VITE_BAAS_API_KEY || 'public-anon-key';

const BASE = ENDPOINT || (typeof window !== 'undefined' ? window.location.origin : 'http://localhost:8002');

class QueryBuilder {
  #table;
  #filters = [];
  #orders = [];
  #limitN = null;
  #offsetN = null;
  #select = null;

  constructor(table) {
    this.#table = table;
  }

  eq(field, value) { this.#filters.push({ field, op: 'eq', value }); return this; }
  neq(field, value) { this.#filters.push({ field, op: 'neq', value }); return this; }
  gt(field, value) { this.#filters.push({ field, op: 'gt', value }); return this; }
  gte(field, value) { this.#filters.push({ field, op: 'gte', value }); return this; }
  lt(field, value) { this.#filters.push({ field, op: 'lt', value }); return this; }
  lte(field, value) { this.#filters.push({ field, op: 'lte', value }); return this; }
  in(field, values) {
    const csv = Array.isArray(values) ? values.join(',') : values;
    this.#filters.push({ field, op: 'in', value: `(${csv})` });
    return this;
  }
  like(field, pat) { this.#filters.push({ field, op: 'like', value: pat }); return this; }
  ilike(field, pat) { this.#filters.push({ field, op: 'ilike', value: pat }); return this; }
  is(field, value) { this.#filters.push({ field, op: 'is', value }); return this; }
  not(field, op, value) { this.#filters.push({ field, op: `not.${op}`, value }); return this; }

  order(field, dir = 'asc') { this.#orders.push(`${field}.${dir}`); return this; }
  limit(n) { this.#limitN = n; return this; }
  offset(n) { this.#offsetN = n; return this; }
  select(s) { this.#select = s; return this; }

  async #request(method, body, prefer) {
    const url = new URL(`/rest/v1/${this.#table}`, BASE);
    for (const { field, op, value } of this.#filters) {
      url.searchParams.append(field, `${op}.${value}`);
    }
    if (this.#orders.length) url.searchParams.set('order', this.#orders.join(','));
    if (this.#limitN != null) url.searchParams.set('limit', this.#limitN);
    if (this.#offsetN != null) url.searchParams.set('offset', this.#offsetN);
    if (this.#select) url.searchParams.set('select', this.#select);

    const token = localStorage.getItem('baas_token');
    const headers = { 'Content-Type': 'application/json', apikey: API_KEY };
    if (token) headers.Authorization = `Bearer ${token}`;
    if (method !== 'GET') headers.Prefer = prefer || 'return=representation';

    const res = await fetch(url, {
      method,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({ message: res.statusText }));
      throw new Error(err.message || err.details || `HTTP ${res.status}`);
    }
    const text = await res.text();
    return text ? JSON.parse(text) : [];
  }

  get() { return this.#request('GET'); }

  async single() {
    this.#limitN = 1;
    const rows = await this.#request('GET');
    return Array.isArray(rows) ? rows[0] ?? null : rows;
  }

  async insert(data) {
    const rows = await this.#request('POST', data);
    return Array.isArray(rows) ? rows[0] ?? rows : rows;
  }

  async upsert(data) {
    const rows = await this.#request('POST', data, 'return=representation,resolution=merge-duplicates');
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

const auth = {
  async signUp({ email, password, fullName }) {
    const res = await fetch(`${BASE}/auth/v1/signup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: API_KEY },
      body: JSON.stringify({
        email,
        password,
        data: { full_name: fullName || email.split('@')[0], role: 'user' },
      }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.msg || data.error_description || 'No se pudo crear la cuenta');
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
    if (!res.ok) throw new Error('Credenciales no válidas');
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

const storage = {
  getUrl(path) {
    if (!path) return null;
    if (path.startsWith('http')) return path;
    return `${BASE}/storage/v1${path.startsWith('/') ? '' : '/'}${path}`;
  },
};

const baas = {
  collection: (name) => new QueryBuilder(name),
  auth,
  storage,
};

export default baas;
export { auth, storage };
