/**
 * Client-side composition — the query API returns FLAT rows (no joins/expand), so
 * the rich, nested shapes the NestJS backend used to return are assembled here
 * from a few flat reads + in-memory maps. This is what makes the public pages
 * (menus with dishes/images, reviews with author names, site-info, promotions)
 * render exactly as before.
 */

import { db, type Row } from './baas';

type Num = number;
const asNum = (v: unknown, d = 0): Num => (typeof v === 'number' ? v : Number(v) || d);
const asStr = (v: unknown): string => (typeof v === 'string' ? v : v == null ? '' : String(v));

/** The data plane caps a single read at 500 rows (a higher limit 400s). */
const LIMIT_MAX = 500;

/** Fetch up to `limit` rows of a table (reference tables are small). */
async function all(
  table: string,
  where: Record<string, unknown> = {},
  limit = LIMIT_MAX,
  sort?: Record<string, 'asc' | 'desc'>,
): Promise<Row[]> {
  const r = await db.list(table, { where, limit: Math.min(limit, LIMIT_MAX), sort });
  return r.rows;
}

/** Existing real assets shipped in public/ — used to replace the seed's dangling
 *  `/img/menus/*.jpg` paths (those images were never bundled) so the UI has no 404s. */
const REAL_IMAGES = [
  '/service-wedding-600.webp', '/service-private-600.webp', '/service-corporate-600.webp',
  '/produce-local-600.webp', '/hero-catering-960.webp',
];

/** Keep external (https) image URLs; map dangling local seed paths to a real asset. */
function resolveImageUrl(url: string, seed: number): string {
  if (/^https?:\/\//.test(url)) return url;
  if (url.startsWith('/img/')) return REAL_IMAGES[Math.abs(seed) % REAL_IMAGES.length];
  return url || '/menu-fallback-640.webp';
}

/** Group rows by a key into a Map<key, Row[]>. */
function groupBy(rows: Row[], key: string): Map<unknown, Row[]> {
  const m = new Map<unknown, Row[]>();
  for (const r of rows) {
    const k = r[key];
    const arr = m.get(k);
    if (arr) arr.push(r); else m.set(k, [r]);
  }
  return m;
}

/** Index rows by a unique key into a Map<key, Row>. */
function indexBy(rows: Row[], key: string): Map<unknown, Row> {
  return new Map(rows.map((r) => [r[key], r] as const));
}

// ── menus (Menu + MenuImage + Diet + Theme + Dish[.DishAllergen.Allergen]) ──

type MenuMaps = {
  imagesByMenu: Map<unknown, Row[]>;
  dietById: Map<unknown, Row>;
  themeById: Map<unknown, Row>;
  dishesByMenu: Map<unknown, Row[]>;
};

async function loadMenuMaps(): Promise<MenuMaps> {
  const [images, diets, themes, links, dishes, dishAllergens, allergens] = await Promise.all([
    all('MenuImage'), all('Diet'), all('Theme'), all('_MenuDishes'), all('Dish'),
    all('DishAllergen'), all('Allergen'),
  ]);
  const allergenById = indexBy(allergens, 'id');
  const allergensByDish = groupBy(dishAllergens, 'dish_id');
  const dishById = indexBy(dishes, 'id');
  // _MenuDishes: B = menu id, A = dish id (Prisma implicit, alphabetical Dish→A, Menu→B).
  const linksByMenu = groupBy(links, 'B');
  const dishesByMenu = new Map<unknown, Row[]>();
  for (const [menuId, rows] of linksByMenu) {
    const ds = rows.map((l) => dishById.get(l.A)).filter((d): d is Row => !!d).map((d) => ({
      ...d,
      DishAllergen: (allergensByDish.get(d.id) ?? []).map((da) => ({
        ...da, Allergen: allergenById.get(da.allergen_id) ?? null,
      })),
    }));
    dishesByMenu.set(menuId, ds);
  }
  return { imagesByMenu: groupBy(images, 'menu_id'), dietById: indexBy(diets, 'id'), themeById: indexBy(themes, 'id'), dishesByMenu };
}

function decorateMenu(menu: Row, m: MenuMaps): Row {
  const id = asNum(menu.id);
  return {
    ...menu,
    MenuImage: (m.imagesByMenu.get(menu.id) ?? []).map((img) => ({ ...img, image_url: resolveImageUrl(asStr(img.image_url), id) })),
    Diet: m.dietById.get(menu.diet_id) ?? null,
    Theme: m.themeById.get(menu.theme_id) ?? null,
    Dish: m.dishesByMenu.get(menu.id) ?? [],
  };
}

export type MenuQuery = { status?: string; diet_id?: number; theme_id?: number; page?: number; limit?: number };

/** Paginated, decorated published menus → { items, meta }. */
export async function composeMenus(q: MenuQuery): Promise<{ items: Row[]; meta: Row }> {
  const where: Record<string, unknown> = { status: q.status ?? 'published' };
  if (q.diet_id) where.diet_id = q.diet_id;
  if (q.theme_id) where.theme_id = q.theme_id;
  const [menus, maps] = await Promise.all([all('Menu', where, 500, { id: 'asc' }), loadMenuMaps()]);
  const page = q.page && q.page > 0 ? q.page : 1;
  const limit = q.limit && q.limit > 0 ? q.limit : 12;
  const total = menus.length;
  const slice = menus.slice((page - 1) * limit, (page - 1) * limit + limit).map((mn) => decorateMenu(mn, maps));
  const totalPages = Math.max(1, Math.ceil(total / limit));
  return { items: slice, meta: { page, limit, total, totalPages, hasNext: page < totalPages, hasPrev: page > 1 } };
}

/** A single decorated menu by id, or null. */
export async function composeMenuById(id: number): Promise<Row | null> {
  const menu = await db.get('Menu', { id });
  if (!menu) return null;
  return decorateMenu(menu, await loadMenuMaps());
}

// ── site-info (Company + CompanyOwner[+User] + Event count) ──

export async function composeSiteInfo(): Promise<Row> {
  const [companies, owners, users, events] = await Promise.all([
    all('Company', {}, 1), all('CompanyOwner'), all('User', {}, 50), all('Event', {}, 500),
  ]);
  const company = companies[0] ?? {};
  const userById = indexBy(users, 'id');
  const established = asStr(company.first_opening_date).slice(0, 4);
  const establishedYear = Number(established) || 2001;
  return {
    company: { name: asStr(company.name), slogan: company.slogan ?? null, description: company.description ?? null },
    owners: owners.map((o) => {
      const u = userById.get(o.user_id) ?? {};
      return { firstName: asStr(u.first_name), lastName: u.last_name ?? null, role: asStr(o.role), isPrimary: !!o.is_primary };
    }),
    yearsOfExperience: Math.max(0, new Date().getFullYear() - establishedYear),
    establishedYear,
    eventCount: events.length,
    phone: asStr(company.phone), email: asStr(company.email), address: asStr(company.address),
    city: company.city ?? null, website: company.website ?? null,
  };
}

// ── reviews (approved Publish + author first_name) + stats ──

export async function composeReviews(page = 1, limit = 20): Promise<{ items: Row[]; meta: Row }> {
  const [reviews, users] = await Promise.all([
    all('Publish', { status: 'approved' }, 500), all('User', {}, 100),
  ]);
  const userById = indexBy(users, 'id');
  const total = reviews.length;
  const items = reviews.slice((page - 1) * limit, (page - 1) * limit + limit).map((r) => ({
    id: r.id, user_id: r.user_id, note: r.note, description: r.description, created_at: r.created_at,
    User_Publish_user_idToUser: { first_name: asStr((userById.get(r.user_id) ?? {}).first_name) || 'Client' },
  }));
  return { items, meta: { page, limit, total, totalPages: Math.max(1, Math.ceil(total / limit)) } };
}

export async function reviewStats(): Promise<Row> {
  const reviews = await all('Publish', {}, 500);
  const approved = reviews.filter((r) => r.status === 'approved');
  const count = approved.length;
  const avg = count ? approved.reduce((s, r) => s + asNum(r.note), 0) / count : 0;
  // Satisfaction = the average rating as a percentage of 5 (a fair reflection of
  // every client's note), NOT just the share of ≥4★ — so an all-5★ set is 100%
  // but a 4.67 average reads ~93%.
  return {
    averageRating: Math.round(avg * 10) / 10,
    reviewCount: count,
    satisfactionPercent: count ? Math.round((avg / 5) * 100) : 0,
  };
}

// ── active promotions (+ nested Discount) ──

export async function activePromotions(): Promise<Row[]> {
  const [promos, discounts] = await Promise.all([all('Promotion', { is_active: true }), all('Discount')]);
  const discById = indexBy(discounts, 'id');
  return promos
    .filter((p) => p.is_public !== false)
    .sort((a, b) => asNum(b.priority) - asNum(a.priority))
    .map((p) => {
      const d = p.discount_id != null ? discById.get(p.discount_id) : null;
      return { ...p, Discount: d ? { code: asStr(d.code), type: asStr(d.type), value: asNum(d.value) } : null };
    });
}
