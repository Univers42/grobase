#!/usr/bin/env node
// **************************************************************************** //
//  nimbus-data-generate.mjs — deterministic Nimbus business generator         //
//                                                                              //
//  Zero-dependency Node ESM. Seeded PRNG (seed 42, mulberry32) and a fixed     //
//  base epoch — no Math.random, no wall-clock — so re-runs are byte-identical. //
//  Emits into $OUT (default /out):                                            //
//    pg-nimbus.sql     TRUNCATE + COPY of the 6 PG money tables (idempotent)   //
//    mongo-nimbus.js   drop + insert of the 3 mongo collections (owner-stamped)//
//    counts.json       per-table/collection manifest for the loader           //
//  Coherent by construction: every account.balance_cents equals the signed    //
//  sum of its ledger entries, and global debits equal global credits.         //
//                                                                              //
//  Owner identity arrives via SEED_OWNER (the gateway-probed app-key           //
//  principal `api-key:<key uuid>`); SEED_TENANT defaults to "nimbus".          //
// **************************************************************************** //

import { writeFileSync } from "node:fs";

const OUT = process.env.OUT_DIR || "/out";
const OWNER = process.env.SEED_OWNER || "api-key:eb9ca6f4-a677-42a0-9fe0-7dceaa05325e";
const TENANT = process.env.SEED_TENANT || "nimbus";
const BASE_EPOCH = Date.UTC(2024, 11, 18, 12, 0, 0);
const MONTH_MS = 2629800000;
const DAY_MS = 86400000;

/** mulberry32 — a small deterministic 32-bit PRNG seeded once. */
export function makeRng(seed) {
  let a = seed >>> 0;
  return function next() {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** intRange returns a deterministic integer in [lo, hi]. */
export function intRange(rng, lo, hi) {
  return lo + Math.floor(rng() * (hi - lo + 1));
}

/** pick returns a deterministic element of arr. */
export function pick(rng, arr) {
  return arr[Math.floor(rng() * arr.length)];
}

/** weighted picks a key by integer weight from [[key, w], …]. */
export function weighted(rng, pairs) {
  const total = pairs.reduce((s, p) => s + p[1], 0);
  let r = rng() * total;
  for (const [key, w] of pairs) {
    r -= w;
    if (r < 0) return key;
  }
  return pairs[pairs.length - 1][0];
}

const FIRST = [
  "Alice", "Bob", "Carol", "David", "Emma", "Frank", "Grace", "Henry", "Ivy",
  "Jack", "Karen", "Liam", "Mia", "Noah", "Olivia", "Peter", "Quinn", "Rachel",
  "Sam", "Tina", "Umar", "Vera", "Wade", "Xena", "Yusuf", "Zoe", "Aaron",
  "Bella", "Caleb", "Diana", "Ethan", "Fiona", "Gabriel", "Hannah", "Isaac",
  "Julia", "Kevin", "Laura", "Marcus", "Nora", "Oscar", "Priya", "Riley",
  "Sofia", "Theo", "Uma", "Victor", "Wendy", "Yara", "Zachary",
];
const LAST = [
  "Anderson", "Brooks", "Chen", "Diaz", "Evans", "Fischer", "Garcia", "Hughes",
  "Ibrahim", "Johnson", "Kim", "Lopez", "Murphy", "Nguyen", "Okafor", "Patel",
  "Quinn", "Reyes", "Smith", "Tanaka", "Underwood", "Vasquez", "Wright", "Xu",
  "Yamamoto", "Zhang", "Bauer", "Costa", "Dubois", "Engel", "Flores", "Grant",
];
const DOMAINS = ["nimbus.io", "acme.co", "globex.com", "initech.dev", "umbrella.org"];
const PLANS = [
  ["free", 0], ["pro", 2999], ["team", 9900], ["enterprise", 49900],
];

/** slug lowercases a name fragment into an email-safe token. */
export function slug(s) {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, "");
}

/** sqlStr escapes a value for a Postgres single-quoted string literal. */
export function sqlStr(v) {
  return "'" + String(v).replace(/'/g, "''") + "'";
}

/** isoAt renders a UTC ISO timestamp offset ms from the base epoch. */
export function isoAt(offsetMs) {
  return new Date(BASE_EPOCH - offsetMs).toISOString().replace("T", " ").replace("Z", "+00");
}

/** buildUsers makes ~200 coherent app_users with roles, statuses and dates. */
export function buildUsers(rng) {
  const users = [];
  const seenEmail = new Set();
  for (let i = 0; i < 200; i++) {
    const first = pick(rng, FIRST);
    const last = pick(rng, LAST);
    let email = `${slug(first)}.${slug(last)}@${pick(rng, DOMAINS)}`;
    if (seenEmail.has(email)) email = `${slug(first)}.${slug(last)}${i}@${pick(rng, DOMAINS)}`;
    seenEmail.add(email);
    const role = i < 5 ? "admin" : i < 30 ? "staff" : "customer";
    const status = weighted(rng, [["active", 88], ["suspended", 9], ["deleted", 3]]);
    const ageMs = Math.floor(rng() * 18 * MONTH_MS);
    users.push({
      id: `nimbus-u-${String(i).padStart(4, "0")}`,
      email, name: `${first} ${last}`, role, status, createdMs: ageMs,
    });
  }
  return users;
}

/** buildAccounts creates one account per customer plus revenue + fees houses. */
export function buildAccounts(rng, users) {
  const accounts = [];
  let id = 1;
  for (const u of users) {
    if (u.role !== "customer") continue;
    accounts.push({
      id: id++, ownerUserId: u.id, kind: "customer", balance: 0,
      createdMs: u.createdMs,
    });
  }
  const revenue = { id: id++, ownerUserId: null, kind: "revenue", balance: 0, createdMs: 18 * MONTH_MS };
  const fees = { id: id++, ownerUserId: null, kind: "fees", balance: 0, createdMs: 18 * MONTH_MS };
  accounts.push(revenue, fees);
  return { accounts, revenue, fees };
}

/** postEntry appends a ledger row and moves the balance per the app's sign
 *  convention (credit increases, debit decreases — matches lib/tx.ts). */
function postEntry(ledger, account, direction, amount, txnId, createdMs) {
  ledger.push({ txnId, accountId: account.id, direction, amount, createdMs });
  account.balance += direction === "credit" ? amount : -amount;
}

/** buildTxns posts ~600 balanced double-entry transactions across 18 months. */
export function buildTxns(rng, custAccounts, revenue, fees) {
  const txns = [];
  const ledger = [];
  for (let i = 0; i < 600; i++) {
    const kind = weighted(rng, [["payment", 80], ["refund", 12], ["payout", 8]]);
    const amount = intRange(rng, 5, 900) * 100;
    const acct = pick(rng, custAccounts);
    const createdMs = Math.floor(rng() * 18 * MONTH_MS);
    const status = weighted(rng, [["posted", 92], ["pending", 5], ["failed", 3]]);
    const id = i + 1;
    txns.push({ id, kind, amount, status, reference: `NMB-${String(id).padStart(6, "0")}`, createdMs });
    if (status !== "posted") continue;
    postLedgerPair(ledger, kind, amount, id, createdMs, acct, revenue, fees);
  }
  return { txns, ledger };
}

/** postLedgerPair writes the debit/credit pair that keeps each txn balanced. */
function postLedgerPair(ledger, kind, amount, id, createdMs, acct, revenue, fees) {
  if (kind === "payment") {
    postEntry(ledger, acct, "debit", amount, id, createdMs);
    postEntry(ledger, revenue, "credit", amount, id, createdMs);
  } else if (kind === "refund") {
    postEntry(ledger, revenue, "debit", amount, id, createdMs);
    postEntry(ledger, acct, "credit", amount, id, createdMs);
  } else {
    postEntry(ledger, fees, "debit", amount, id, createdMs);
    postEntry(ledger, revenue, "credit", amount, id, createdMs);
  }
}

/** buildSubscriptions assigns ~150 plans to customers with realistic states. */
export function buildSubscriptions(rng, custUsers) {
  const subs = [];
  for (let i = 0; i < 150; i++) {
    const u = pick(rng, custUsers);
    const [plan, amount] = pick(rng, PLANS);
    const status = weighted(rng, [["active", 62], ["trialing", 15], ["past_due", 13], ["canceled", 10]]);
    const createdMs = Math.floor(rng() * 18 * MONTH_MS);
    const periodEndMs = createdMs - 30 * DAY_MS;
    subs.push({ id: i + 1, userId: u.id, plan, amount, status, createdMs, periodEndMs });
  }
  return subs;
}

/** buildInvoices issues ~400 invoices, linking paid ones to a posted txn. */
export function buildInvoices(rng, subs, postedTxnIds) {
  const invoices = [];
  for (let i = 0; i < 400; i++) {
    const sub = pick(rng, subs);
    const status = weighted(rng, [["paid", 55], ["open", 22], ["draft", 13], ["void", 10]]);
    const createdMs = Math.floor(rng() * 18 * MONTH_MS);
    const txnId = status === "paid" ? pick(rng, postedTxnIds) : null;
    invoices.push({
      id: i + 1, subscriptionId: sub.id, userId: sub.userId,
      amount: sub.amount || intRange(rng, 5, 200) * 100, status, txnId,
      dueAtMs: createdMs - 14 * DAY_MS, createdMs,
    });
  }
  return invoices;
}

/** copyBlock renders a COPY … FROM stdin block for one table and its rows. */
export function copyBlock(table, columns, rows) {
  const head = `COPY public.${table} (${columns.join(", ")}) FROM stdin;\n`;
  const body = rows.map((r) => r.join("\t")).join("\n");
  return head + body + "\n\\.\n";
}

/** N renders a nullable scalar as a Postgres COPY field. */
function N(v) {
  return v === null || v === undefined ? "\\N" : String(v);
}

/** buildPgSql assembles the full idempotent Postgres load script. */
export function buildPgSql(data) {
  const { users, accounts, txns, ledger, subs, invoices } = data;
  const O = OWNER;
  const parts = [
    "BEGIN;",
    "TRUNCATE public.ledger_entries, public.invoices, public.subscriptions, public.txns, public.accounts, public.app_users RESTART IDENTITY CASCADE;",
  ];
  parts.push(copyBlock("app_users", ["id", "email", "name", "role", "status", "owner_id", "created_at"],
    users.map((u) => [u.id, u.email, u.name, u.role, u.status, O, isoAt(u.createdMs)])));
  parts.push(pgAccountsBlock(accounts, O));
  parts.push(copyBlock("txns", ["id", "kind", "amount_cents", "currency", "status", "reference", "owner_id", "created_at"],
    txns.map((t) => [t.id, t.kind, t.amount, "USD", t.status, t.reference, O, isoAt(t.createdMs)])));
  parts.push(pgIdentityReset("txns", txns.length));
  parts.push(copyBlock("subscriptions", ["id", "user_id", "plan", "amount_cents", "currency", "status", "current_period_end", "owner_id", "created_at"],
    subs.map((s) => [s.id, s.userId, s.plan, s.amount, "USD", s.status, isoAt(s.periodEndMs), O, isoAt(s.createdMs)])));
  parts.push(pgIdentityReset("subscriptions", subs.length));
  parts.push(copyBlock("invoices", ["id", "subscription_id", "user_id", "amount_cents", "currency", "status", "transaction_id", "due_at", "owner_id", "created_at"],
    invoices.map((v) => [v.id, v.subscriptionId, v.userId, v.amount, "USD", v.status, N(v.txnId), isoAt(v.dueAtMs), O, isoAt(v.createdMs)])));
  parts.push(pgIdentityReset("invoices", invoices.length));
  parts.push(copyBlock("ledger_entries", ["transaction_id", "account_id", "direction", "amount_cents", "owner_id", "created_at"],
    ledger.map((l) => [l.txnId, l.accountId, l.direction, l.amount, O, isoAt(l.createdMs)])));
  parts.push("COMMIT;");
  return parts.join("\n") + "\n";
}

/** pgAccountsBlock renders accounts with by-construction balances + id reset. */
function pgAccountsBlock(accounts, owner) {
  const block = copyBlock("accounts", ["id", "owner_user_id", "kind", "balance_cents", "currency", "owner_id", "created_at"],
    accounts.map((a) => [a.id, N(a.ownerUserId), a.kind, a.balance, "USD", owner, isoAt(a.createdMs)]));
  return block + pgIdentityReset("accounts", accounts.length);
}

/** pgIdentityReset advances a GENERATED-ALWAYS identity past the loaded rows. */
function pgIdentityReset(table, n) {
  return `SELECT setval(pg_get_serial_sequence('public.${table}', 'id'), ${n}, true);\n`;
}

/** mongoDoc stamps a document with the owner + tenant the app reads under. */
function mongoDoc(fields) {
  return { owner_id: OWNER, tenant_id: TENANT, ...fields };
}

const SUBJECTS = [
  "Billing question about my invoice", "Cannot access the dashboard",
  "Feature request: export to CSV", "Refund for duplicate charge",
  "API rate limit increase", "Onboarding help for my team",
  "Password reset not arriving", "Upgrade to the team plan",
  "Webhook delivery failures", "Sales enquiry — enterprise",
];
const BODIES = [
  "Hi team, I noticed something on my account and wanted to check in.",
  "This has been blocking my work since this morning — any update?",
  "Could you point me to the right docs? Thanks in advance.",
  "Appreciate the quick turnaround last time. One more thing:",
  "We are evaluating Nimbus for our org and have a few questions.",
];

/** buildMessages makes ~60 realistic inbox messages from real users. */
export function buildMessages(rng, users) {
  const out = [];
  for (let i = 0; i < 60; i++) {
    const u = pick(rng, users);
    const status = weighted(rng, [["open", 45], ["closed", 40], ["archived", 15]]);
    const createdMs = Math.floor(rng() * 18 * MONTH_MS);
    out.push(mongoDoc({
      subject: pick(rng, SUBJECTS), body: pick(rng, BODIES), from: u.email,
      status, read: status !== "open", created_at: isoAt(createdMs).replace(" ", "T"),
    }));
  }
  return out;
}

/** buildContent makes the site.settings doc plus a few page/block docs. */
export function buildContent() {
  return [
    mongoDoc({ key: "site.settings", type: "settings", value: { siteName: "Nimbus", tagline: "Beautifully observed.", supportEmail: "support@nimbus.local", theme: "dark" } }),
    mongoDoc({ key: "page.home", type: "page", title: "Welcome to Nimbus", body: "Your money, observed." }),
    mongoDoc({ key: "page.pricing", type: "page", title: "Pricing", body: "Free, Pro, Team and Enterprise plans." }),
    mongoDoc({ key: "page.docs", type: "page", title: "Documentation", body: "Guides and API reference." }),
    mongoDoc({ key: "block.hero", type: "block", title: "Hero", body: "One backend, any frontend." }),
    mongoDoc({ key: "block.cta", type: "block", title: "Call to action", body: "Start free today." }),
    mongoDoc({ key: "block.footer", type: "block", title: "Footer", body: "© Nimbus" }),
    mongoDoc({ key: "page.security", type: "page", title: "Security", body: "Owner-scoped reads, never a cross-tenant leak." }),
  ];
}

/** buildActivity derives ~300 log entries from signups, payments, messages. */
export function buildActivity(rng, users, txns, messages) {
  const out = [];
  for (let i = 0; i < 300; i++) {
    const kind = weighted(rng, [["user.signup", 35], ["payment.posted", 40], ["message.received", 25]]);
    const createdMs = Math.floor(rng() * 18 * MONTH_MS);
    out.push(activityFor(rng, kind, users, txns, messages, createdMs));
  }
  return out;
}

/** activityFor renders one coherent activity entry for the chosen event kind. */
function activityFor(rng, kind, users, txns, messages, createdMs) {
  const at = isoAt(createdMs).replace(" ", "T");
  if (kind === "user.signup") {
    const u = pick(rng, users);
    return mongoDoc({ action: "user.signup", actor: u.email, detail: `${u.name} joined`, created_at: at });
  }
  if (kind === "payment.posted") {
    const t = pick(rng, txns);
    return mongoDoc({ action: "payment.posted", actor: "system", detail: `${t.reference} ${(t.amount / 100).toFixed(2)} USD`, created_at: at });
  }
  const m = pick(rng, messages);
  return mongoDoc({ action: "message.received", actor: m.from, detail: m.subject, created_at: at });
}

/** buildMongoJs emits a deterministic drop + insert mongosh script. */
export function buildMongoJs(messages, content, activity) {
  const lines = [
    "db.messages.deleteMany({});",
    "db.content.deleteMany({});",
    "db.activity.deleteMany({});",
    `db.messages.insertMany(${JSON.stringify(messages)});`,
    `db.content.insertMany(${JSON.stringify(content)});`,
    `db.activity.insertMany(${JSON.stringify(activity)});`,
  ];
  return lines.join("\n") + "\n";
}

/** ledgerTotals returns the global debit and credit sums in cents. */
export function ledgerTotals(ledger) {
  let debit = 0;
  let credit = 0;
  for (const l of ledger) {
    if (l.direction === "debit") debit += l.amount;
    else credit += l.amount;
  }
  return { debit, credit };
}

/** generate builds the whole coherent dataset deterministically from seed 42. */
export function generate() {
  const rng = makeRng(42);
  const users = buildUsers(rng);
  const custUsers = users.filter((u) => u.role === "customer");
  const { accounts, revenue, fees } = buildAccounts(rng, users);
  const custAccounts = accounts.filter((a) => a.kind === "customer");
  const { txns, ledger } = buildTxns(rng, custAccounts, revenue, fees);
  const postedTxnIds = txns.filter((t) => t.status === "posted").map((t) => t.id);
  const subs = buildSubscriptions(rng, custUsers);
  const invoices = buildInvoices(rng, subs, postedTxnIds);
  const messages = buildMessages(rng, users);
  const content = buildContent();
  const activity = buildActivity(rng, users, txns, messages);
  return { users, accounts, revenue, fees, txns, ledger, subs, invoices, messages, content, activity };
}

/** main wires generation to the emitted files and prints the balance proof. */
export function main() {
  const d = generate();
  const { debit, credit } = ledgerTotals(d.ledger);
  const balanced = debit === credit;
  writeFileSync(`${OUT}/pg-nimbus.sql`, buildPgSql(d));
  writeFileSync(`${OUT}/mongo-nimbus.js`, buildMongoJs(d.messages, d.content, d.activity));
  const counts = {
    pg: {
      app_users: d.users.length, accounts: d.accounts.length, txns: d.txns.length,
      ledger_entries: d.ledger.length, subscriptions: d.subs.length, invoices: d.invoices.length,
    },
    mongo: { messages: d.messages.length, content: d.content.length, activity: d.activity.length },
  };
  writeFileSync(`${OUT}/counts.json`, JSON.stringify(counts, null, 2));
  const revenueUsd = (d.revenue.balance / 100).toFixed(2);
  process.stdout.write(`pg: ${JSON.stringify(counts.pg)}\n`);
  process.stdout.write(`mongo: ${JSON.stringify(counts.mongo)}\n`);
  process.stdout.write(`ledger balanced=${balanced} debit=$${(debit / 100).toFixed(2)} credit=$${(credit / 100).toFixed(2)} revenue=$${revenueUsd}\n`);
  if (!balanced) process.exitCode = 1;
}

main();
