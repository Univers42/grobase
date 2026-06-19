/**
 * DevBoard CRUD layer — backs the Notion-like database browser/editor
 * (`components/database`). Maps the app's `/api/crud/*` API onto Grobase: schema
 * introspection → table models, aggregate counts, paginated reads, and
 * create/update/delete — routed to the Postgres mount or the MongoDB mount.
 *
 * The endpoint↔table↔engine registry below MUST stay in sync with
 * `components/database/DatabaseService.ts`'s MODEL_TO_ENDPOINT (the UI filters
 * tables by it).
 */

import { adminDb, adminMongoDb, getSchema, config, type Row, type Where } from './baas';

type Engine = 'pg' | 'mongo';
type Entry = { ep: string; table: string; engine: Engine; pk: string };

const CRUD: Entry[] = [
  { ep: 'users', table: 'User', engine: 'pg', pk: 'id' },
  { ep: 'roles', table: 'Role', engine: 'pg', pk: 'id' },
  { ep: 'orders', table: 'Order', engine: 'pg', pk: 'id' },
  { ep: 'menus', table: 'Menu', engine: 'pg', pk: 'id' },
  { ep: 'menu-images', table: 'MenuImage', engine: 'pg', pk: 'id' },
  { ep: 'dishes', table: 'Dish', engine: 'pg', pk: 'id' },
  { ep: 'diets', table: 'Diet', engine: 'pg', pk: 'id' },
  { ep: 'themes', table: 'Theme', engine: 'pg', pk: 'id' },
  { ep: 'allergens', table: 'Allergen', engine: 'pg', pk: 'id' },
  { ep: 'ingredients', table: 'Ingredient', engine: 'pg', pk: 'id' },
  { ep: 'working-hours', table: 'WorkingHours', engine: 'pg', pk: 'id' },
  { ep: 'promotions', table: 'Promotion', engine: 'pg', pk: 'id' },
  { ep: 'discounts', table: 'Discount', engine: 'pg', pk: 'id' },
  { ep: 'reviews', table: 'Publish', engine: 'pg', pk: 'id' },
  { ep: 'companies', table: 'Company', engine: 'pg', pk: 'id' },
  { ep: 'events', table: 'Event', engine: 'pg', pk: 'id' },
  { ep: 'loyalty-accounts', table: 'LoyaltyAccount', engine: 'pg', pk: 'id' },
  { ep: 'notifications', table: 'Notification', engine: 'pg', pk: 'id' },
  { ep: 'mongo-events', table: 'events', engine: 'mongo', pk: '_id' },
  { ep: 'mongo-menu-views', table: 'menu_views', engine: 'mongo', pk: '_id' },
];
const byEp = new Map(CRUD.map((c) => [c.ep, c]));
const byTable = new Map(CRUD.map((c) => [c.table, c]));

/** The mount dbId backing a DevBoard table (for realtime topics + reads). */
export function dbIdForTable(table: string): string {
  const e = byTable.get(table);
  return e && e.engine === 'mongo' ? config.mongoDbId : config.pgDbId;
}

/** Columns to surface for Mongo collections when introspection returns none. */
const MONGO_COLS: Record<string, string[]> = {
  events: ['_id', 'event_type', 'user_id', 'menu_id', 'ts', 'owner_id', 'tenant_id'],
  menu_views: ['_id', 'menu_id', 'views', 'last_viewed', 'owner_id', 'tenant_id'],
};

const client = (e: Entry) => (e.engine === 'mongo' ? (adminMongoDb ?? adminDb) : adminDb);
const castKey = (e: Entry, key: string): string | number => (e.engine === 'pg' && /^\d+$/.test(key) ? Number(key) : key);

/** Re-fetch a single row by primary key — realtime events carry the pk, not the row. */
export async function fetchRowByTable(table: string, pk: string | number): Promise<Row | null> {
  const e = byTable.get(table);
  if (!e) return null;
  return client(e)
    .get(e.table, { [e.pk]: castKey(e, String(pk)) } as Where)
    .catch(() => null);
}

type SchemaTable = { name: string; primary_key: string[]; columns: Array<Record<string, unknown>> };

async function schemaMaps(): Promise<Map<string, SchemaTable>> {
  const [pg, mongo] = await Promise.all([
    getSchema(config.pgDbId).catch(() => ({ tables: [] as SchemaTable[] })),
    config.mongoDbId ? getSchema(config.mongoDbId).catch(() => ({ tables: [] as SchemaTable[] })) : Promise.resolve({ tables: [] as SchemaTable[] }),
  ]);
  const m = new Map<string, SchemaTable>();
  for (const t of [...pg.tables, ...mongo.tables]) m.set(t.name, t);
  return m;
}

/** GET /api/crud/schema → the DevBoard's SchemaModel[]. */
export async function crudSchema(): Promise<unknown[]> {
  const maps = await schemaMaps();
  return CRUD.map((e) => {
    const s = maps.get(e.table);
    const pk = s?.primary_key?.length ? s.primary_key : [e.pk];
    let cols = (s?.columns ?? []).map((c) => ({
      name: String(c.name),
      type: String(c.normalized_type ?? c.native_type ?? 'text'),
      isId: pk.includes(String(c.name)),
      isRequired: c.nullable === false,
      isList: false,
      isRelation: false,
      isReadOnly: pk.includes(String(c.name)),
    }));
    if (!cols.length && e.engine === 'mongo') {
      cols = (MONGO_COLS[e.table] ?? ['_id']).map((n) => ({ name: n, type: 'text', isId: n === '_id', isRequired: false, isList: false, isRelation: false, isReadOnly: n === '_id' }));
    }
    return { name: e.table, columns: cols, primaryKey: pk, canCreate: true, canUpdate: true, canDelete: true };
  });
}

/** GET /api/crud/counts → { table: rowCount }. */
export async function crudCounts(): Promise<Record<string, number>> {
  const out: Record<string, number> = {};
  await Promise.all(CRUD.map(async (e) => {
    let n = await client(e).count(e.table).catch(() => 0);
    if (!n && e.engine === 'mongo') n = await client(e).list(e.table, { limit: 500 }).then((r) => r.rowCount).catch(() => 0);
    out[e.table] = n;
  }));
  return out;
}

/** GET /api/crud/<endpoint>?page&limit → { data, total }. */
export async function crudList(ep: string, q: URLSearchParams): Promise<{ data: Row[]; total: number }> {
  const e = byEp.get(ep);
  if (!e) return { data: [], total: 0 };
  const page = Math.max(1, Number(q.get('page')) || 1);
  const limit = Math.min(500, Math.max(1, Number(q.get('limit')) || 25));
  const offset = (page - 1) * limit;
  const sort = e.engine === 'pg' ? { [e.pk]: 'asc' as const } : undefined;
  const { rows, rowCount } = await client(e).list(e.table, { limit, offset, sort });
  let total = await client(e).count(e.table).catch(() => 0);
  if (total < offset + rowCount) total = offset + rowCount;
  return { data: rows, total };
}

export async function crudGet(ep: string, key: string): Promise<Row | null> {
  const e = byEp.get(ep);
  if (!e) return null;
  return client(e).get(e.table, { [e.pk]: castKey(e, key) });
}

export async function crudCreate(ep: string, data: Row): Promise<Row | null> {
  const e = byEp.get(ep);
  if (!e) throw new Error(`unknown table endpoint: ${ep}`);
  return client(e).insert(e.table, data);
}

export async function crudUpdate(ep: string, key: string, data: Row): Promise<Row | null> {
  const e = byEp.get(ep);
  if (!e) throw new Error(`unknown table endpoint: ${ep}`);
  const clean: Row = { ...data };
  delete clean[e.pk];
  delete clean.owner_id;
  delete clean.tenant_id;
  return client(e).update(e.table, clean, { [e.pk]: castKey(e, key) } as Where);
}

export async function crudDelete(ep: string, key: string): Promise<void> {
  const e = byEp.get(ep);
  if (!e) throw new Error(`unknown table endpoint: ${ep}`);
  await client(e).remove(e.table, { [e.pk]: castKey(e, key) } as Where);
}

/** GET /api/crud/schema/tables → all table names (both engines). */
export async function crudTableNames(): Promise<string[]> {
  return [...(await schemaMaps()).keys()];
}

/** GET /api/crud/schema/full → DDL-style schema for every introspected table. */
export async function crudFullSchema(): Promise<unknown[]> {
  const maps = await schemaMaps();
  return [...maps.values()].map((t) => ({
    name: t.name,
    columns: (t.columns ?? []).map((c) => ({
      name: String(c.name),
      type: String(c.normalized_type ?? c.native_type ?? 'text'),
      isNullable: c.nullable !== false,
      defaultValue: (c.default ?? null) as string | null,
      isPrimaryKey: (t.primary_key ?? []).includes(String(c.name)),
    })),
  }));
}

/** GET /api/crud/schema/foreign-keys → FK edges from the introspected references. */
export async function crudForeignKeys(): Promise<unknown[]> {
  const maps = await schemaMaps();
  const out: unknown[] = [];
  for (const t of maps.values()) {
    for (const c of t.columns ?? []) {
      const ref = c.references as { table?: string; column?: string } | null;
      if (ref && ref.table) out.push({ tableName: t.name, columnName: String(c.name), referencedTable: ref.table, referencedColumn: ref.column ?? 'id' });
    }
  }
  return out;
}
