/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   live-demo-generate.mjs                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// Deterministic commerce+ops dataset generator for the live-database demo
// (M22 / osionos notion-database-sys). Zero dependencies on purpose: the
// repo's supply-chain policy forbids ad-hoc installs, so randomness is a
// seeded mulberry32 PRNG and "faker" is curated word pools. Same inputs →
// byte-identical outputs → the emitted loaders are upsert-idempotent
// (ON CONFLICT DO NOTHING / INSERT IGNORE / insertMany ordered:false).
//
// Inputs (env):
//   SEED_OWNER   required — owner_id stamped on EVERY row. The platform's
//                write path injects the caller principal (api-key:<key uuid>)
//                and owner-scopes updates/deletes (and MySQL/Mongo reads), so
//                bulk-loaded rows must carry the app key's principal or the
//                app cannot see or edit them.
//   SEED_TENANT  required — tenant_id stamped on Mongo docs (the Mongo pool
//                also tenant-scopes every read/write).
//   OUT_DIR      default /out
//   SEED_SCALE   default 1 — multiplies the big row counts.
//
// Outputs: pg-commerce.sql, mysql-ops.sql, mongo-activity.js, counts.json.

import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const OWNER = process.env.SEED_OWNER;
const TENANT = process.env.SEED_TENANT;
const OUT = process.env.OUT_DIR ?? '/out';
const SCALE = Number(process.env.SEED_SCALE ?? '1');
if (!OWNER || !TENANT) {
  console.error('SEED_OWNER and SEED_TENANT are required');
  process.exit(2);
}

// ── deterministic PRNG (mulberry32, seed 42) ────────────────────────────────
let prngState = 42 >>> 0;
function rand() {
  prngState = (prngState + 0x6d2b79f5) >>> 0;
  let t = prngState;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const int = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));
const pick = (arr) => arr[Math.floor(rand() * arr.length)];
const chance = (p) => rand() < p;
const money = (lo, hi) => (lo + rand() * (hi - lo)).toFixed(2);
// Weighted pick: [[value, weight], …]
function wpick(pairs) {
  const total = pairs.reduce((s, [, w]) => s + w, 0);
  let roll = rand() * total;
  for (const [value, weight] of pairs) {
    roll -= weight;
    if (roll <= 0) return value;
  }
  return pairs[pairs.length - 1][0];
}
// Anchored "now" so re-runs a few days apart still converge on the same rows.
const NOW = Date.parse('2026-06-09T12:00:00Z');
const DAY = 86_400_000;
const daysAgo = (max, min = 0) => new Date(NOW - int(min, max) * DAY - int(0, DAY - 1));
const iso = (d) => d.toISOString();
const isoDate = (d) => d.toISOString().slice(0, 10);
const sqlDt = (d) => iso(d).slice(0, 19).replace('T', ' '); // MySQL DATETIME

// ── curated pools ───────────────────────────────────────────────────────────
const FIRST = ['Ada', 'Alan', 'Amara', 'Bjorn', 'Camille', 'Chen', 'Dana', 'Diego', 'Elif', 'Emeka',
  'Farah', 'Felix', 'Grace', 'Hana', 'Hugo', 'Ines', 'Ivan', 'Jonas', 'Kavya', 'Kenji',
  'Lena', 'Liam', 'Mai', 'Marco', 'Nadia', 'Noah', 'Olga', 'Omar', 'Priya', 'Quentin',
  'Rafael', 'Rosa', 'Sami', 'Sofia', 'Tariq', 'Tessa', 'Umar', 'Vera', 'Wei', 'Yara', 'Zoe', 'Dylan'];
const LAST = ['Achebe', 'Bauer', 'Costa', 'Dubois', 'Eriksen', 'Fontaine', 'Garcia', 'Haddad', 'Ito', 'Jansen',
  'Kowalski', 'Lindqvist', 'Moreau', 'Nakamura', 'Okafor', 'Petrov', 'Quispe', 'Rossi', 'Sato', 'Tanaka',
  'Ueda', 'Vasquez', 'Weber', 'Xu', 'Yilmaz', 'Zhang', 'Lesieur', 'Mercier', 'Novak', 'Silva'];
const CITY = {
  NA: ['Austin', 'Toronto', 'Denver', 'Montreal', 'Seattle', 'Chicago'],
  EU: ['Paris', 'Berlin', 'Lisbon', 'Prague', 'Amsterdam', 'Madrid'],
  APAC: ['Osaka', 'Singapore', 'Seoul', 'Melbourne', 'Taipei', 'Bangalore'],
  LATAM: ['Bogota', 'Santiago', 'Lima', 'Montevideo', 'Mexico City', 'Recife'],
};
const REGIONS = ['NA', 'EU', 'APAC', 'LATAM'];
const ADJ = ['Aurora', 'Cobalt', 'Drift', 'Ember', 'Flux', 'Granite', 'Halo', 'Ion', 'Juniper', 'Kite',
  'Lumen', 'Mistral', 'Nimbus', 'Onyx', 'Pulse', 'Quartz', 'Ridge', 'Sable', 'Terra', 'Volt'];
const NOUN = ['Backpack', 'Blender', 'Camera', 'Chair', 'Desk Pad', 'Earbuds', 'Hoodie', 'Kettle', 'Keyboard',
  'Lamp', 'Monitor Arm', 'Mug', 'Notebook', 'Racket', 'Scooter', 'Speaker', 'Tent', 'Tracker', 'Trimmer', 'Watch'];
const CATEGORY = ['electronics', 'home', 'sports', 'toys', 'office', 'grocery', 'apparel', 'beauty'];
const WAREHOUSES = ['paris', 'berlin', 'austin', 'osaka'];
const PROJECT_WORDS = ['Atlas', 'Beacon', 'Caravel', 'Dynamo', 'Estuary', 'Foxtrot', 'Gantry', 'Harbor',
  'Icarus', 'Jigsaw', 'Krypton', 'Lighthouse', 'Meridian', 'Nautilus', 'Obelisk', 'Pinwheel',
  'Quasar', 'Rampart', 'Sextant', 'Trellis'];
const TAGS = ['ops', 'retro', 'q3', 'supply-chain', 'pricing', 'urgent', 'idea', 'customer', 'logistics', 'growth'];
const EVENT_KINDS = ['page_view', 'search', 'add_to_cart', 'checkout', 'login', 'support_chat'];
const CHANNELS = ['web', 'mobile', 'email'];
const personName = () => `${pick(FIRST)} ${pick(LAST)}`;

// ── volumes ─────────────────────────────────────────────────────────────────
const scaled = (n) => Math.max(1, Math.round(n * SCALE));
const N = {
  customers: scaled(5000), products: scaled(1200), employees: 60,
  orders: scaled(25000), projects: 40, tasks: scaled(2000),
  tickets: scaled(3000), timeEntries: scaled(6000),
  events: scaled(30000), reviews: scaled(8000), notes: scaled(400),
};

// ── SQL helpers ─────────────────────────────────────────────────────────────
const q = (s) => `'${String(s).replace(/'/g, "''")}'`;
const orNull = (v, f = (x) => x) => (v === null || v === undefined ? 'NULL' : f(v));
function insertBatches(out, table, columns, rows, render, { conflict = '', prefix = 'INSERT INTO' } = {}) {
  for (let i = 0; i < rows.length; i += 500) {
    const values = rows.slice(i, i + 500).map(render).join(',\n');
    out.push(`${prefix} ${table} (${columns}) VALUES\n${values}${conflict};`);
  }
}

// ═════════════════════════════ PostgreSQL — commerce ════════════════════════
const customers = Array.from({ length: N.customers }, (_, i) => {
  const region = pick(REGIONS);
  const name = personName();
  return {
    id: i + 1, name, region, city: pick(CITY[region]),
    email: `${name.toLowerCase().replace(/[^a-z]/g, '.')}${i + 1}@example.com`,
    signup: daysAgo(900, 1), optIn: chance(0.55), ltv: money(0, 9000),
  };
});
const products = Array.from({ length: N.products }, (_, i) => {
  const price = Number(money(4.99, 1999));
  return {
    id: i + 1, name: `${pick(ADJ)} ${pick(NOUN)} ${int(100, 999)}`,
    sku: `SKU-${String(i + 1).padStart(5, '0')}`, category: pick(CATEGORY),
    price, cost: (price * (0.45 + rand() * 0.25)).toFixed(2),
    active: chance(0.9), launched: daysAgo(1200, 30),
  };
});
const employees = Array.from({ length: N.employees }, (_, i) => {
  const name = personName();
  return {
    // Suffix with the id: 60 draws from the name pools WILL collide
    // (birthday paradox) and email is UNIQUE.
    id: i + 1, name, email: `${name.toLowerCase().replace(/[^a-z]/g, '.')}.${i + 1}@trackbinocle.io`,
    role: i < 6 ? 'management' : pick(['sales', 'support', 'ops', 'engineering']),
    region: pick(REGIONS), hired: daysAgo(2000, 60), salary: money(32000, 110000),
    managerId: i < 6 ? null : int(1, 6),
  };
});
const inventory = products.flatMap((product) => {
  const slots = chance(0.8) ? 2 : 3;
  return [...WAREHOUSES].sort(() => rand() - 0.5).slice(0, slots).map((warehouse, j) => ({
    id: (product.id - 1) * 4 + j + 1, productId: product.id, warehouse,
    qty: int(0, 480), reorder: int(10, 60), restocked: daysAgo(120),
  }));
});
const orders = [];
const orderItems = [];
let itemId = 1;
for (let i = 1; i <= N.orders; i += 1) {
  const placed = daysAgo(540);
  const ageDays = (NOW - placed.getTime()) / DAY;
  const status = ageDays > 30
    ? wpick([['delivered', 78], ['cancelled', 12], ['refunded', 10]])
    : wpick([['pending', 25], ['paid', 35], ['shipped', 40]]);
  const shipped = status === 'shipped' || status === 'delivered'
    ? new Date(placed.getTime() + int(1, 5) * DAY) : null;
  const discount = chance(0.25) ? pick([5, 10, 15, 20]) : 0;
  let total = 0;
  for (let line = int(1, 5); line > 0; line -= 1) {
    const product = pick(products);
    const qty = int(1, 4);
    orderItems.push({ id: itemId, orderId: i, productId: product.id, qty, unitPrice: product.price.toFixed(2) });
    total += qty * product.price;
    itemId += 1;
  }
  orders.push({
    id: i, customerId: int(1, N.customers), employeeId: chance(0.7) ? int(1, N.employees) : null,
    status, ship: pick(['standard', 'express', 'overnight', 'pickup']), placed, shipped,
    total: (total * (1 - discount / 100)).toFixed(2), discount,
    notes: chance(0.08) ? pick(['Gift wrap requested', 'Leave at door', 'Call before delivery', 'Fragile items']) : null,
  });
}

const pg = [];
pg.push('\\set ON_ERROR_STOP on');
pg.push('BEGIN;');
for (const [name, values] of [
  ['region_t', REGIONS], ['order_status_t', ['pending', 'paid', 'shipped', 'delivered', 'cancelled', 'refunded']],
  ['ship_method_t', ['standard', 'express', 'overnight', 'pickup']], ['product_category_t', CATEGORY],
  ['employee_role_t', ['sales', 'support', 'ops', 'engineering', 'management']], ['warehouse_t', WAREHOUSES],
]) {
  pg.push(`DO $$ BEGIN CREATE TYPE ${name} AS ENUM (${values.map(q).join(', ')}); EXCEPTION WHEN duplicate_object THEN NULL; END $$;`);
}
pg.push(`
CREATE TABLE IF NOT EXISTS customers (
  id serial PRIMARY KEY, name text NOT NULL, email text NOT NULL UNIQUE,
  region region_t NOT NULL, city text NOT NULL, signup_date date NOT NULL,
  marketing_opt_in boolean NOT NULL DEFAULT false, lifetime_value numeric(12,2) NOT NULL DEFAULT 0,
  owner_id text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS products (
  id serial PRIMARY KEY, name text NOT NULL, sku text NOT NULL UNIQUE, category product_category_t NOT NULL,
  price numeric(10,2) NOT NULL, cost numeric(10,2) NOT NULL, active boolean NOT NULL DEFAULT true,
  launched_on date, owner_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS employees (
  id serial PRIMARY KEY, name text NOT NULL, email text NOT NULL UNIQUE, role employee_role_t NOT NULL,
  region region_t NOT NULL, hired_on date NOT NULL, salary numeric(10,2) NOT NULL,
  manager_id integer REFERENCES employees(id), owner_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS inventory (
  id serial PRIMARY KEY, product_id integer NOT NULL REFERENCES products(id), warehouse warehouse_t NOT NULL,
  qty_on_hand integer NOT NULL DEFAULT 0, reorder_level integer NOT NULL DEFAULT 10, restocked_at timestamptz,
  owner_id text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (product_id, warehouse));
CREATE TABLE IF NOT EXISTS orders (
  id serial PRIMARY KEY, customer_id integer NOT NULL REFERENCES customers(id),
  employee_id integer REFERENCES employees(id), status order_status_t NOT NULL DEFAULT 'pending',
  ship_method ship_method_t NOT NULL DEFAULT 'standard', placed_at timestamptz NOT NULL,
  shipped_at timestamptz, total numeric(12,2) NOT NULL, discount_pct numeric(4,1) NOT NULL DEFAULT 0,
  notes text, owner_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS order_items (
  id serial PRIMARY KEY, order_id integer NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id integer NOT NULL REFERENCES products(id), qty integer NOT NULL, unit_price numeric(10,2) NOT NULL,
  owner_id text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS edges (
  id serial PRIMARY KEY, src_kind text NOT NULL, src_id text NOT NULL,
  dst_kind text NOT NULL, dst_id text NOT NULL, rel text NOT NULL,
  owner_id text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (src_kind, src_id, dst_kind, dst_id, rel));
CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders (customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders (status);
CREATE INDEX IF NOT EXISTS idx_items_order ON order_items (order_id);
CREATE INDEX IF NOT EXISTS idx_items_product ON order_items (product_id);
CREATE INDEX IF NOT EXISTS idx_inventory_product ON inventory (product_id);
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$ LANGUAGE plpgsql;`);
for (const table of ['customers', 'products', 'employees', 'inventory', 'orders', 'order_items', 'edges']) {
  pg.push(`DROP TRIGGER IF EXISTS trg_${table}_updated ON ${table};`);
  pg.push(`CREATE TRIGGER trg_${table}_updated BEFORE UPDATE ON ${table} FOR EACH ROW EXECUTE FUNCTION set_updated_at();`);
}
pg.push('COMMIT;');
pg.push('BEGIN;');
const skip = { conflict: '\nON CONFLICT (id) DO NOTHING' };
insertBatches(pg, 'customers',
  'id, name, email, region, city, signup_date, marketing_opt_in, lifetime_value, owner_id', customers,
  (c) => `(${c.id}, ${q(c.name)}, ${q(c.email)}, ${q(c.region)}, ${q(c.city)}, ${q(isoDate(c.signup))}, ${c.optIn}, ${c.ltv}, ${q(OWNER)})`, skip);
insertBatches(pg, 'products',
  'id, name, sku, category, price, cost, active, launched_on, owner_id', products,
  (p) => `(${p.id}, ${q(p.name)}, ${q(p.sku)}, ${q(p.category)}, ${p.price.toFixed(2)}, ${p.cost}, ${p.active}, ${q(isoDate(p.launched))}, ${q(OWNER)})`, skip);
insertBatches(pg, 'employees',
  'id, name, email, role, region, hired_on, salary, manager_id, owner_id', employees,
  (e) => `(${e.id}, ${q(e.name)}, ${q(e.email)}, ${q(e.role)}, ${q(e.region)}, ${q(isoDate(e.hired))}, ${e.salary}, ${orNull(e.managerId)}, ${q(OWNER)})`, skip);
insertBatches(pg, 'inventory',
  'id, product_id, warehouse, qty_on_hand, reorder_level, restocked_at, owner_id', inventory,
  (s) => `(${s.id}, ${s.productId}, ${q(s.warehouse)}, ${s.qty}, ${s.reorder}, ${q(iso(s.restocked))}, ${q(OWNER)})`, skip);
insertBatches(pg, 'orders',
  'id, customer_id, employee_id, status, ship_method, placed_at, shipped_at, total, discount_pct, notes, owner_id', orders,
  (o) => `(${o.id}, ${o.customerId}, ${orNull(o.employeeId)}, ${q(o.status)}, ${q(o.ship)}, ${q(iso(o.placed))}, ${orNull(o.shipped, (d) => q(iso(d)))}, ${o.total}, ${o.discount}, ${orNull(o.notes, q)}, ${q(OWNER)})`, skip);
insertBatches(pg, 'order_items',
  'id, order_id, product_id, qty, unit_price, owner_id', orderItems,
  (l) => `(${l.id}, ${l.orderId}, ${l.productId}, ${l.qty}, ${l.unitPrice}, ${q(OWNER)})`, skip);
pg.push('COMMIT;');

// ═════════════════════════════ MySQL — ops ══════════════════════════════════
const projects = Array.from({ length: N.projects }, (_, i) => ({
  id: i + 1, name: `Project ${PROJECT_WORDS[i % PROJECT_WORDS.length]}${i >= 20 ? ' II' : ''}`,
  code: `OPS-${String(i + 1).padStart(3, '0')}`,
  status: wpick([['planning', 15], ['active', 45], ['on_hold', 10], ['done', 25], ['archived', 5]]),
  lead: personName(), budget: money(8000, 250000), starts: daysAgo(700, 30),
}));
const tasks = Array.from({ length: N.tasks }, (_, i) => {
  const status = wpick([['todo', 25], ['in_progress', 25], ['review', 12], ['blocked', 8], ['done', 30]]);
  return {
    id: i + 1, projectId: int(1, N.projects),
    title: `${pick(['Audit', 'Refactor', 'Ship', 'Design', 'Benchmark', 'Document', 'Migrate', 'Review'])} ${pick(['warehouse sync', 'pricing rules', 'returns flow', 'vendor portal', 'SLA alerts', 'pick list', 'carrier API', 'stock report'])}`,
    status, priority: wpick([['low', 20], ['medium', 45], ['high', 25], ['urgent', 10]]),
    assignee: personName(), estimate: (rand() * 16 + 0.5).toFixed(1),
    due: chance(0.8) ? daysAgo(-60, -1) : null, // -days → future due dates
    doneAt: status === 'done' ? daysAgo(200) : null,
  };
});
const tickets = Array.from({ length: N.tickets }, (_, i) => {
  const status = wpick([['open', 18], ['triaged', 14], ['in_progress', 18], ['waiting', 10], ['resolved', 25], ['closed', 15]]);
  const opened = daysAgo(400);
  const resolved = status === 'resolved' || status === 'closed'
    ? new Date(opened.getTime() + int(1, 21) * DAY) : null;
  return {
    id: i + 1, projectId: chance(0.7) ? int(1, N.projects) : null,
    title: `${pick(['Late delivery', 'Refund request', 'Damaged item', 'Wrong size', 'Billing mismatch', 'Login issue', 'Stock discrepancy', 'Carrier exception'])} #${i + 1}`,
    severity: wpick([['low', 30], ['minor', 35], ['major', 25], ['critical', 10]]),
    status, reporter: personName(), channel: pick(['email', 'chat', 'phone', 'web']),
    orderRef: chance(0.6) ? int(1, N.orders) : null, opened, resolved,
    satisfaction: resolved && chance(0.7) ? int(1, 5) : null,
  };
});
const timeEntries = Array.from({ length: N.timeEntries }, (_, i) => ({
  id: i + 1, taskId: int(1, N.tasks), person: personName(),
  hours: (rand() * 7.5 + 0.25).toFixed(2), date: daysAgo(180), billable: chance(0.65),
  note: chance(0.3) ? pick(['pairing', 'code review', 'incident follow-up', 'customer call', 'spec writing']) : null,
}));

const my = [];
my.push('SET NAMES utf8mb4;');
my.push(`
CREATE TABLE IF NOT EXISTS projects (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, name VARCHAR(120) NOT NULL, code VARCHAR(16) NOT NULL UNIQUE,
  status ENUM('planning','active','on_hold','done','archived') NOT NULL DEFAULT 'planning',
  lead_name VARCHAR(80) NOT NULL, budget DECIMAL(12,2) NOT NULL DEFAULT 0, starts_on DATE NOT NULL,
  owner_id VARCHAR(64) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS tasks (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, project_id INT NOT NULL,
  title VARCHAR(160) NOT NULL,
  status ENUM('todo','in_progress','review','blocked','done') NOT NULL DEFAULT 'todo',
  priority ENUM('low','medium','high','urgent') NOT NULL DEFAULT 'medium',
  assignee VARCHAR(80) NOT NULL, estimate_h DECIMAL(5,1) NOT NULL DEFAULT 1.0,
  due_on DATE NULL, done_at DATETIME NULL, owner_id VARCHAR(64) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_tasks_project FOREIGN KEY (project_id) REFERENCES projects(id), INDEX idx_tasks_project (project_id)) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS tickets (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, project_id INT NULL,
  title VARCHAR(160) NOT NULL,
  severity ENUM('low','minor','major','critical') NOT NULL DEFAULT 'minor',
  status ENUM('open','triaged','in_progress','waiting','resolved','closed') NOT NULL DEFAULT 'open',
  reporter VARCHAR(80) NOT NULL, channel ENUM('email','chat','phone','web') NOT NULL DEFAULT 'web',
  order_ref INT NULL, opened_at DATETIME NOT NULL, resolved_at DATETIME NULL,
  satisfaction TINYINT NULL, owner_id VARCHAR(64) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_tickets_project FOREIGN KEY (project_id) REFERENCES projects(id), INDEX idx_tickets_project (project_id)) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS time_entries (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, task_id INT NOT NULL,
  person VARCHAR(80) NOT NULL, hours DECIMAL(5,2) NOT NULL, entry_date DATE NOT NULL,
  billable TINYINT(1) NOT NULL DEFAULT 1, note VARCHAR(255) NULL, owner_id VARCHAR(64) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_time_task FOREIGN KEY (task_id) REFERENCES tasks(id), INDEX idx_time_task (task_id)) ENGINE=InnoDB;`);
const ignore = { prefix: 'INSERT IGNORE INTO' };
insertBatches(my, 'projects', 'id, name, code, status, lead_name, budget, starts_on, owner_id', projects,
  (p) => `(${p.id}, ${q(p.name)}, ${q(p.code)}, ${q(p.status)}, ${q(p.lead)}, ${p.budget}, ${q(isoDate(p.starts))}, ${q(OWNER)})`, ignore);
insertBatches(my, 'tasks', 'id, project_id, title, status, priority, assignee, estimate_h, due_on, done_at, owner_id', tasks,
  (t) => `(${t.id}, ${t.projectId}, ${q(t.title)}, ${q(t.status)}, ${q(t.priority)}, ${q(t.assignee)}, ${t.estimate}, ${orNull(t.due, (d) => q(isoDate(d)))}, ${orNull(t.doneAt, (d) => q(sqlDt(d)))}, ${q(OWNER)})`, ignore);
insertBatches(my, 'tickets', 'id, project_id, title, severity, status, reporter, channel, order_ref, opened_at, resolved_at, satisfaction, owner_id', tickets,
  (t) => `(${t.id}, ${orNull(t.projectId)}, ${q(t.title)}, ${q(t.severity)}, ${q(t.status)}, ${q(t.reporter)}, ${q(t.channel)}, ${orNull(t.orderRef)}, ${q(sqlDt(t.opened))}, ${orNull(t.resolved, (d) => q(sqlDt(d)))}, ${orNull(t.satisfaction)}, ${q(OWNER)})`, ignore);
insertBatches(my, 'time_entries', 'id, task_id, person, hours, entry_date, billable, note, owner_id', timeEntries,
  (e) => `(${e.id}, ${e.taskId}, ${q(e.person)}, ${e.hours}, ${q(isoDate(e.date))}, ${e.billable ? 1 : 0}, ${orNull(e.note, q)}, ${q(OWNER)})`, ignore);

// ═════════════════════════════ MongoDB — activity ═══════════════════════════
const events = Array.from({ length: N.events }, (_, i) => {
  const kind = wpick([['page_view', 45], ['search', 18], ['add_to_cart', 14], ['checkout', 8], ['login', 10], ['support_chat', 5]]);
  const customerRef = int(1, N.customers);
  const path = kind === 'search' ? `/search?q=${pick(NOUN).toLowerCase()}` : `/products/${int(1, N.products)}`;
  return {
    _id: `evt-${String(i + 1).padStart(6, '0')}`, kind,
    summary: `${kind} ${path} by cust-${customerRef}`,
    customer_ref: customerRef, order_ref: kind === 'checkout' ? int(1, N.orders) : null,
    channel: pick(CHANNELS), ts: daysAgo(90), payload: { path, ms: int(40, 2400) },
  };
});
const reviews = Array.from({ length: N.reviews }, (_, i) => {
  const rating = wpick([[5, 38], [4, 30], [3, 14], [2, 9], [1, 9]]);
  return {
    _id: `rev-${String(i + 1).padStart(5, '0')}`, product_ref: int(1, N.products),
    customer_ref: int(1, N.customers), rating,
    title: pick(['Exceeded expectations', 'Solid value', 'Does the job', 'Mixed feelings', 'Not as described', 'Five stars', 'Would buy again', 'Save your money']),
    body: pick(['Arrived early and works perfectly.', 'Quality feels premium for the price.', 'Setup took five minutes.', 'The finish scratches easily.', 'Customer support resolved my issue fast.', 'Battery life is shorter than advertised.', 'My second purchase from this brand.']),
    verified: chance(0.7), helpful_votes: int(0, 240), reviewed_at: daysAgo(360),
  };
});
const notes = Array.from({ length: N.notes }, (_, i) => ({
  _id: `note-${String(i + 1).padStart(4, '0')}`,
  title: `${pick(['Standup', 'Retro', 'Supplier call', 'Inventory check', 'Pricing review', 'Roadmap', 'Incident', 'Hiring'])} — ${pick(PROJECT_WORDS)}`,
  body: pick(['Follow up next week.', 'Decision: ship behind a flag.', 'Carrier renegotiation pending.', 'Stock levels look healthy.', 'Two candidates moved to onsite.', 'Root cause: stale cache on the edge.']),
  tags: [...new Set([pick(TAGS), pick(TAGS)])], pinned: chance(0.1),
  related_kind: chance(0.5) ? pick(['project', 'ticket', 'order']) : null,
  related_id: null, created_at: daysAgo(250),
}));
for (const note of notes) {
  if (note.related_kind === 'project') note.related_id = String(int(1, N.projects));
  if (note.related_kind === 'ticket') note.related_id = String(int(1, N.tickets));
  if (note.related_kind === 'order') note.related_id = String(int(1, N.orders));
}

// Validators: declared contract → exact (inferred:false) introspection. Date
// fields accept date|string so in-place edits (JSON strings over HTTP) pass
// validation; introspection still normalizes them to datetime (first type).
const mongoDate = (d) => `new Date(${JSON.stringify(iso(d))})`;
function mongoDoc(obj) {
  const fields = Object.entries(obj).map(([key, value]) => {
    if (value instanceof Date) return `${JSON.stringify(key)}: ${mongoDate(value)}`;
    return `${JSON.stringify(key)}: ${JSON.stringify(value)}`;
  });
  return `{ ${fields.join(', ')}, "owner_id": ${JSON.stringify(OWNER)}, "tenant_id": ${JSON.stringify(TENANT)} }`;
}
const mongo = [];
mongo.push(`// Idempotent mongo seed (live-demo). Run against the activity database.
function ensureCollection(name, validator) {
  try { db.createCollection(name, { validator: validator }); }
  catch (e) { db.runCommand({ collMod: name, validator: validator }); }
}
const S = { bsonType: ['string', 'null'] };
const I = { bsonType: ['int', 'long', 'double', 'null'] };
const D = { bsonType: ['date', 'string', 'null'] };
ensureCollection('events', { $jsonSchema: {
  bsonType: 'object', required: ['owner_id', 'tenant_id'],
  properties: {
    _id: { bsonType: ['string', 'objectId'] }, kind: { enum: ${JSON.stringify(EVENT_KINDS)} },
    summary: S, customer_ref: I, order_ref: I,
    channel: { enum: ${JSON.stringify(CHANNELS)} }, ts: D, payload: { bsonType: ['object', 'null'] },
    owner_id: { bsonType: ['string', 'objectId'] }, tenant_id: { bsonType: ['string', 'objectId'] },
  } } });
ensureCollection('product_reviews', { $jsonSchema: {
  bsonType: 'object', required: ['owner_id', 'tenant_id'],
  properties: {
    _id: { bsonType: ['string', 'objectId'] }, product_ref: I, customer_ref: I,
    rating: I, title: S, body: S, verified: { bsonType: ['bool', 'null'] },
    helpful_votes: I, reviewed_at: D,
    owner_id: { bsonType: ['string', 'objectId'] }, tenant_id: { bsonType: ['string', 'objectId'] },
  } } });
ensureCollection('notes', { $jsonSchema: {
  bsonType: 'object', required: ['owner_id', 'tenant_id'],
  properties: {
    _id: { bsonType: ['string', 'objectId'] }, title: S, body: S,
    tags: { bsonType: ['array', 'null'] }, pinned: { bsonType: ['bool', 'null'] },
    related_kind: S, related_id: S, created_at: D,
    owner_id: { bsonType: ['string', 'objectId'] }, tenant_id: { bsonType: ['string', 'objectId'] },
  } } });
function load(name, docs) {
  try { db[name].insertMany(docs, { ordered: false }); }
  catch (e) { /* duplicate _ids on re-run are expected */ }
}`);
for (const [name, docs] of [['events', events], ['product_reviews', reviews], ['notes', notes]]) {
  for (let i = 0; i < docs.length; i += 1000) {
    mongo.push(`load('${name}', [\n${docs.slice(i, i + 1000).map(mongoDoc).join(',\n')}\n]);`);
  }
}
mongo.push(`print('mongo-activity seeded: events=' + db.events.countDocuments() + ' product_reviews=' + db.product_reviews.countDocuments() + ' notes=' + db.notes.countDocuments());`);

// ═══════════════ cross-engine edges (PG table, built from the same streams) ═
const edges = [];
for (const ticket of tickets) {
  if (ticket.orderRef !== null) {
    edges.push({ srcKind: 'ticket', srcId: String(ticket.id), dstKind: 'order', dstId: String(ticket.orderRef), rel: 'ticket_about_order' });
  }
}
for (const review of reviews.slice(0, 2000)) {
  edges.push({ srcKind: 'review', srcId: review._id, dstKind: 'product', dstId: String(review.product_ref), rel: 'review_of_product' });
}
for (const event of events.slice(0, 2000)) {
  edges.push({ srcKind: 'event', srcId: event._id, dstKind: 'customer', dstId: String(event.customer_ref), rel: 'event_by_customer' });
}
pg.push('BEGIN;');
insertBatches(pg, 'edges', 'src_kind, src_id, dst_kind, dst_id, rel, owner_id', edges,
  (e) => `(${q(e.srcKind)}, ${q(e.srcId)}, ${q(e.dstKind)}, ${q(e.dstId)}, ${q(e.rel)}, ${q(OWNER)})`,
  { conflict: '\nON CONFLICT (src_kind, src_id, dst_kind, dst_id, rel) DO NOTHING' });
pg.push('COMMIT;');
// Serial sequences must clear the seeded ids or the app's first INSERT 409s.
for (const table of ['customers', 'products', 'employees', 'inventory', 'orders', 'order_items', 'edges']) {
  pg.push(`SELECT setval(pg_get_serial_sequence('${table}', 'id'), GREATEST((SELECT COALESCE(MAX(id), 1) FROM ${table}), 1));`);
}
pg.push('ANALYZE;');

// ── write outputs ───────────────────────────────────────────────────────────
mkdirSync(OUT, { recursive: true });
writeFileSync(join(OUT, 'pg-commerce.sql'), `${pg.join('\n')}\n`);
writeFileSync(join(OUT, 'mysql-ops.sql'), `${my.join('\n')}\n`);
writeFileSync(join(OUT, 'mongo-activity.js'), `${mongo.join('\n')}\n`);
const counts = {
  pg: {
    customers: customers.length, products: products.length, employees: employees.length,
    inventory: inventory.length, orders: orders.length, order_items: orderItems.length, edges: edges.length,
  },
  mysql: {
    projects: projects.length, tasks: tasks.length, tickets: tickets.length, time_entries: timeEntries.length,
  },
  mongo: { events: events.length, product_reviews: reviews.length, notes: notes.length },
};
writeFileSync(join(OUT, 'counts.json'), `${JSON.stringify(counts, null, 2)}\n`);
const total = Object.values(counts).flatMap((engine) => Object.values(engine)).reduce((a, b) => a + b, 0);
console.log(`generated ${total} rows → ${OUT} (owner=${OWNER}, tenant=${TENANT})`);
