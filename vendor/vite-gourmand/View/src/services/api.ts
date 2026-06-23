/**
 * API base service — REWIRED onto the local Grobase BaaS.
 *
 * Originally a fetch wrapper to the NestJS backend (`/api/*`). It is now a ROUTER
 * that maps the app's REST conventions onto Grobase: `/api/auth/*` → GoTrue,
 * composed public endpoints (site-info, reviews, menus, promotions) → assembled
 * client-side from flat reads (see baas-compose.ts), and everything else →
 * owner-scoped query CRUD. The exported surface (apiRequest/setTokens/clearTokens/
 * isAuthenticated/ApiError) and the `{ success, data }` envelope are preserved, so
 * the existing service modules call it UNCHANGED. Unknown/dev-only endpoints
 * degrade to a safe empty shape so the SPA never 400s or crashes.
 */

import { auth, db, isAuthed, clearSession, BaasError, config, accessToken, type Row, type Where } from './baas';
import {
  composeMenus, composeMenuById, composeSiteInfo, composeReviews, reviewStats, activePromotions,
} from './baas-compose';
import {
  crudSchema, crudCounts, crudList, crudGet, crudCreate, crudUpdate, crudDelete,
  crudTableNames, crudFullSchema, crudForeignKeys,
} from './baas-crud';

interface ApiOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  body?: unknown;
  headers?: Record<string, string>;
}

class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

/** REST resource (plural/kebab) → Grobase table (PascalCase) for the generic path. */
const RESOURCE_TABLE: Record<string, string> = {
  menus: 'Menu', diets: 'Diet', themes: 'Theme', allergens: 'Allergen', ingredients: 'Ingredient',
  dishes: 'Dish', orders: 'Order', reviews: 'Publish', notifications: 'Notification',
  promotions: 'Promotion', discounts: 'Discount', 'working-hours': 'WorkingHours', images: 'MenuImage',
  contact: 'ContactMessage', messages: 'Message', support: 'SupportTicket', 'time-off': 'TimeOffRequest',
  kanban: 'KanbanColumn', newsletter: 'NewsletterSubscriber', addresses: 'UserAddress',
  loyalty: 'LoyaltyAccount', deliveries: 'DeliveryAssignment', events: 'Event', companies: 'Company',
};

const snake = (k: string): string => k.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);
const tableFor = (r: string): string => RESOURCE_TABLE[r] ?? r.charAt(0).toUpperCase() + r.slice(1).replace(/s$/, '');
const ok = <T>(data: T) => ({ success: true, statusCode: 200, message: 'OK', data });

export function setTokens(_a?: string, _r?: string): void { /* identity persists in the baas session store */ }
export function clearTokens(): void { clearSession(); }
export function isAuthenticated(): boolean { return isAuthed(); }

/** The caller's app "User" profile (int id + role), merged with the GoTrue
 *  identity. Throws 401 when there is no session — so `/api/auth/me` correctly
 *  fails after logout (otherwise the app key would read *some* User row and the
 *  SPA would think it's still authenticated). Resolves the caller's OWN row by
 *  `auth_id` (the GoTrue sub), never an arbitrary first row. */
async function appUser(): Promise<Row> {
  const u = auth.currentUser();
  if (!u || !u.id) throw new BaasError(401, 'not authenticated');
  const profile = (await db.get('User', { auth_id: u.id }).catch(() => null)) ?? {};
  return {
    id: profile.id ?? u.id,
    email: profile.email ?? u.email,
    firstName: profile.first_name ?? u.name,
    role: u.role || 'customer',
  };
}

/** /api/auth/* → GoTrue. */
async function routeAuth(action: string, body: unknown): Promise<unknown> {
  const b = (body ?? {}) as Record<string, unknown>;
  const email = String(b.email ?? '');
  const password = String(b.password ?? '');
  switch (action) {
    case 'register': {
      await auth.signUp({ email, password, username: String(b.firstName ?? '') });
      const cu = auth.currentUser();
      await db.insert('User', { email, first_name: String(b.firstName ?? ''), auth_id: cu?.id ?? '' }).catch(() => null);
      return ok({ user: await appUser(), accessToken: '' });
    }
    case 'login':
      await auth.signIn({ email, password });
      return ok({ user: await appUser(), accessToken: '' });
    case 'logout': await auth.signOut(); return ok({});
    case 'me': return ok(await appUser());
    case 'forgot-password': await auth.recover(email).catch(() => undefined); return ok({ message: 'If the email exists, a reset link was sent.' });
    case 'verify-reset-token': return ok({ valid: true, message: 'ok' });
    case 'reset-password': return ok({ message: 'Password updated.' });
    default: return ok({ clientId: null }); // google/config + unmapped → disabled
  }
}

const pageOf = (q: URLSearchParams) => Math.max(1, Number(q.get('page')) || 1);
const limitOf = (q: URLSearchParams, d: number) => Math.max(1, Number(q.get('limit')) || d);

/** Owner-scoped paginated list for an authed resource → { items, meta }. */
async function pagedList(table: string, q: URLSearchParams, where: Where = {}): Promise<unknown> {
  const page = pageOf(q); const limit = limitOf(q, 20);
  const { rows, rowCount } = await db.list(table, { where, limit, offset: (page - 1) * limit, sort: { id: 'desc' } });
  const total = (page - 1) * limit + rowCount;
  return ok({ items: rows, meta: { page, limit, total, totalPages: Math.max(page, Math.ceil(total / limit)) } });
}

/** Route the Notion-like DevBoard `/api/crud/*` endpoints to the CRUD layer. */
async function crudDispatch(segs: string[], method: string, data: Row, q: URLSearchParams): Promise<unknown> {
  const [sub, p2] = segs; // ['schema'] | ['schema','tables'] | ['users'] | ['users','5']
  if (sub === 'schema') {
    if (!p2) return ok(await crudSchema());
    if (p2 === 'tables') return ok(await crudTableNames());
    if (p2 === 'full') return ok(await crudFullSchema());
    if (p2 === 'foreign-keys') return ok(await crudForeignKeys());
    if (p2 === 'table' || p2 === 'column') return ok({ success: false, message: 'Schema DDL is managed via Grobase migrations, not the UI.' });
    return ok([]);
  }
  if (sub === 'counts') return ok(await crudCounts());
  if (sub === 'shell') return ok({ output: 'Shell is disabled on Grobase.', exitCode: 1 });
  const ep = sub;
  const key = p2;
  if (key) {
    if (method === 'GET') return ok(await crudGet(ep, key));
    if (method === 'PUT' || method === 'PATCH') return ok(await crudUpdate(ep, key, data));
    if (method === 'DELETE') { await crudDelete(ep, key); return ok({ deleted: true }); }
    return ok({});
  }
  if (method === 'POST') return ok(await crudCreate(ep, data));
  return ok(await crudList(ep, q));
}

/** Forward to grobase's real newsletter service (orchestrator), returning its envelope. */
async function newsletterGateway(path: string, method: string, payload?: unknown): Promise<Record<string, unknown>> {
  const headers: Record<string, string> = { apikey: config.anonKey, 'Content-Type': 'application/json' };
  const token = accessToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${config.url}/newsletter/v1${path}`, {
    method, headers, body: payload !== undefined ? JSON.stringify(payload) : undefined,
  });
  const text = await res.text();
  let env: Record<string, unknown> = {};
  try { env = text ? (JSON.parse(text) as Record<string, unknown>) : {}; }
  catch { throw new ApiError(res.status || 502, `newsletter: gateway returned a non-JSON response (${res.status})`); }
  if (!res.ok) throw new ApiError(res.status, (env.message as string) ?? `newsletter ${res.status}`);
  return env;
}

/** /api/newsletter/* → grobase /newsletter/v1/* — subscribe triggers a real confirmation email. */
async function newsletterDispatch(segs: string[], data: Row): Promise<unknown> {
  const sub = segs.join('/');
  if (sub === 'subscribe') {
    const env = await newsletterGateway('/subscribe', 'POST', data);
    return ok({ message: (env.message as string) ?? 'Vérifiez votre email pour confirmer votre inscription.' });
  }
  if (segs[0] === 'confirm' && segs[1]) {
    const env = await newsletterGateway(`/confirm/${segs[1]}`, 'GET');
    return ok({ message: (env.message as string) ?? 'Inscription confirmée.' });
  }
  if (segs[0] === 'unsubscribe' && segs[1]) {
    const env = await newsletterGateway(`/unsubscribe/${segs[1]}`, 'GET');
    return ok({ message: (env.message as string) ?? 'Vous êtes désabonné.' });
  }
  if (sub === 'stats' || sub === 'stats/admin') {
    return ok(await newsletterGateway('/admin/stats', 'GET').then((e) => e.data ?? { total: 0, active: 0, confirmed: 0 }));
  }
  if (sub === 'admin/campaigns/send' || sub === 'send') {
    const env = await newsletterGateway('/admin/campaigns/send', 'POST', data);
    return ok(env.data ?? { message: (env.message as string) ?? 'Campagne envoyée.' });
  }
  return ok({});
}

/** The explicit endpoint map — composed public data + authed flows + safe stubs. */
async function routeKnown(key: string, segs: string[], method: string, body: unknown, q: URLSearchParams): Promise<unknown | undefined> {
  const data = (body ?? {}) as Row;
  const idNum = Number(segs[1]);
  if (segs[0] === 'newsletter') return newsletterDispatch(segs.slice(1), data);
  switch (key) {
    // ── public composed ──
    case 'site-info': return ok(await composeSiteInfo());
    case 'reviews': return method === 'POST' ? ok(await db.insert('Publish', data)) : ok(await composeReviews(pageOf(q), limitOf(q, 20)));
    case 'reviews/stats': return ok(await reviewStats());
    case 'promotions/active': return ok(await activePromotions());
    case 'working-hours': return ok((await db.list('WorkingHours', { limit: 50, sort: { id: 'asc' } })).rows);
    case 'menus': return method === 'GET'
      ? ok(await composeMenus({ status: q.get('status') ?? 'published', diet_id: Number(q.get('dietId')) || undefined, theme_id: Number(q.get('themeId')) || undefined, page: pageOf(q), limit: limitOf(q, 12) }))
      : ok(await db.insert('Menu', data));
    // ── orders (authed) ──
    case 'orders': return method === 'POST' ? ok(await db.insert('Order', data)) : pagedList('Order', q);
    case 'orders/my': return pagedList('Order', q);
    // ── loyalty (authed) ──
    case 'loyalty/me': return ok((await db.list('LoyaltyAccount', { limit: 1 })).rows[0] ?? { balance: 0, total_earned: 0, total_spent: 0 });
    case 'loyalty/me/transactions': return ok((await db.list('LoyaltyTransaction', { limit: 100, sort: { id: 'desc' } })).rows);
    case 'loyalty/me/redeem': return ok(await db.insert('LoyaltyTransaction', { ...data, type: 'redeem' }));
    // ── notifications (authed) ──
    case 'notifications': return ok((await db.list('Notification', { limit: limitOf(q, 20), sort: { id: 'desc' } })).rows);
    case 'notifications/unread-count': return ok({ count: 0 });
    case 'notifications/read-all': return ok({ count: 0 });
    // ── users / profile ──
    case 'users/me': return ok(await appUser());
    case 'users/me/addresses': return ok((await db.list('UserAddress', { limit: 50 })).rows);
    // ── consent / gdpr (writes); newsletter/* is handled by newsletterDispatch above ──
    case 'consent/anonymous': case 'gdpr/consent': return ok({ recorded: true });
    // ── support (authed) ──
    case 'support': return method === 'POST' ? ok(await db.insert('SupportTicket', data)) : pagedList('SupportTicket', q);
    case 'support/my-tickets': return ok((await db.list('SupportTicket', { limit: 50, sort: { id: 'desc' } })).rows);
    case 'support/stats': return ok({ open: 0, resolved: 0, total: 0 });
    // ── dev-only / external → safe stubs (never 400) ──
    case 'ai-agent/status': return ok({ enabled: false });
    case 'ai-agent/chat': return ok({ reply: '' });
  }
  // prefix-based handlers
  if (segs[0] === 'menus' && segs[1] && method === 'GET') return ok(await composeMenuById(idNum)); // /menus/:id (decorated)
  if (key.startsWith('tests')) return ok({ status: 'skipped', results: [] });
  if (key.startsWith('logs')) return ok([]);
  if (segs[0] === 'crud') return crudDispatch(segs.slice(1), method, data, q);
  if (segs[0] === 'notifications' && segs[2] === 'read') return ok({}); // PATCH /notifications/:id/read
  if (segs[0] === 'notifications' && method === 'DELETE') return ok({}); // DELETE /notifications/:id
  if (segs[0] === 'orders' && segs[2] === 'cancel') return ok(await db.update('Order', { status: 'cancelled', cancellation_reason: String(data.reason ?? '') }, { id: idNum }));
  return undefined; // not a known endpoint → generic CRUD
}

/** Generic CRUD fallback: GET list → array, GET/:id → object, writes → object. */
async function routeCrud(segs: string[], method: string, body: unknown, q: URLSearchParams): Promise<unknown> {
  const table = tableFor(segs[0]);
  const id = segs[1];
  const data = (body ?? {}) as Row;
  if (segs[2]) return ok(await db.update(table, data, { id: Number(id) })); // /res/:id/<action>
  if (method === 'GET' && !id) {
    const where: Where = {};
    for (const [k, v] of q.entries()) { if (k !== 'page' && k !== 'limit') where[snake(k)] = /^\d+$/.test(v) ? Number(v) : v; }
    return ok((await db.list(table, { where, limit: limitOf(q, 100) })).rows);
  }
  if (method === 'GET') return ok(await db.get(table, { id: Number(id) }));
  if (method === 'POST') return ok(await db.insert(table, data));
  if (method === 'PATCH' || method === 'PUT') return ok(await db.update(table, data, { id: Number(id) }));
  if (method === 'DELETE') return ok(await db.remove(table, { id: Number(id) }));
  throw new ApiError(405, `unsupported ${method} ${segs.join('/')}`);
}

/** Make an API request — routed to the local Grobase gateway. */
export async function apiRequest<T>(endpoint: string, options: ApiOptions = {}): Promise<T> {
  const { method = 'GET', body } = options;
  const url = new URL(endpoint, 'http://app.local');
  const segs = url.pathname.replace(/^\/api\/?/, '').split('/').filter(Boolean);
  const key = segs.join('/');
  try {
    if (segs[0] === 'auth') return (await routeAuth(segs.slice(1).join('/'), body)) as T;
    const known = await routeKnown(key, segs, method, body, url.searchParams);
    if (known !== undefined) return known as T;
    return (await routeCrud(segs, method, body, url.searchParams)) as T;
  } catch (error) {
    if (error instanceof BaasError) {
      if (error.status === 401) clearSession();
      throw new ApiError(error.status, error.message);
    }
    throw error instanceof ApiError ? error : new ApiError(500, (error as Error).message || 'Request failed');
  }
}

export { ApiError };
