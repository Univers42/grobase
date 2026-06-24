// tx.ts — atomic single-mount transactions against the query router:
// POST /query/v1/txn with {mount, operations:[{op,resource,data,filter}]}. Every
// op commits all-or-nothing on a transactional engine (postgresql). The payment
// batch matches the live schema: a `txns` header (status 'posted'), a balanced
// debit+credit pair in `ledger_entries`, and the two absolute `accounts.balance_cents`
// updates.

import type { BaasConfig } from './config';
import type { Row } from './db';
import { isRecord, asArray, asNumber } from './guards';

/** TxnOp is one write operation in a transactional batch. */
export type TxnOp = { op: 'insert' | 'update' | 'delete' | 'upsert'; resource: string; data?: Row; filter?: Record<string, unknown> };

/** AccountRef is a stored account id as it round-trips from the data plane. */
export type AccountRef = number | string;

/** idValue restores an account ref's native type for the data plane: an all-digit
 *  string (a SQL bigint id surfaced as a string by the UI layer) becomes a number,
 *  so a bigint column gets a number and not a string (which the engine rejects);
 *  a non-numeric id (a Mongo string _id) is left as-is. */
function idValue(ref: AccountRef): number | string {
  if (typeof ref === 'number') return ref;
  return /^\d+$/.test(ref) ? Number(ref) : ref;
}

/** PaymentInput parameterizes a balanced double-entry payment batch. */
export type PaymentInput = {
  customerAccountId: AccountRef;
  revenueAccountId: AccountRef;
  amountCents: number;
  reference: string;
};

/** Tx is the transaction client surface bound to one Postgres mount. */
export type Tx = {
  run: (operations: TxnOp[]) => Promise<unknown[]>;
  recordPayment: (input: PaymentInput) => Promise<unknown[]>;
};

/** paymentOps builds the balanced 5-op batch against the live schema: a `txns`
 * header, a debit + credit ledger pair, and the two account balances set to their
 * new absolute values (the data plane has no server-side increment). The ledger
 * `transaction_id` is left null — the query router cannot thread the inserted txn
 * id into later ops in one batch; the legs link logically via the txn reference. */
function paymentOps(input: PaymentInput, customerBalance: number, revenueBalance: number): TxnOp[] {
  const { customerAccountId, revenueAccountId, amountCents, reference } = input;
  const customerId = idValue(customerAccountId);
  const revenueId = idValue(revenueAccountId);
  return [
    { op: 'insert', resource: 'txns', data: { kind: 'payment', amount_cents: amountCents, status: 'posted', reference } },
    { op: 'insert', resource: 'ledger_entries', data: { account_id: customerId, direction: 'debit', amount_cents: amountCents } },
    { op: 'insert', resource: 'ledger_entries', data: { account_id: revenueId, direction: 'credit', amount_cents: amountCents } },
    { op: 'update', resource: 'accounts', data: { balance_cents: customerBalance - amountCents }, filter: { id: customerId } },
    { op: 'update', resource: 'accounts', data: { balance_cents: revenueBalance + amountCents }, filter: { id: revenueId } },
  ];
}

/** createTx returns run/recordPayment bound to (config, pgDbId). `token` supplies
 *  the current user JWT so the batch owner-scopes per request: the logged-in admin
 *  JWT triggers the data plane's F2 bypass, so the balance UPDATEs reach the
 *  (api-key-owned) seeded accounts; a non-admin's batch matches 0 rows and no-ops
 *  (safe — money writes are admin-only by construction). See db.ts. */
export function createTx(config: BaasConfig, pgDbId: string, token: () => string): Tx {
  const txnUrl = `${config.url}/query/v1/txn`;
  const accountsUrl = `${config.url}/query/v1/${pgDbId}/tables/accounts`;

  /** headers carries the Kong anon key, the app key (tenant identity), and the
   *  user JWT (read at call time) that drives per-request owner-scoping. */
  function headers(): Record<string, string> {
    const h: Record<string, string> = {
      apikey: config.anonKey,
      'X-Baas-Api-Key': config.apiKey,
      'Content-Type': 'application/json',
    };
    const jwt = token();
    if (jwt) h.Authorization = `Bearer ${jwt}`;
    return h;
  }

  /** readBalanceCents fetches an account's current balance so the payment batch can
   * set the new absolute value (no server-side delta exists). */
  async function readBalanceCents(accountId: AccountRef): Promise<number> {
    const res = await fetch(accountsUrl, {
      method: 'POST',
      headers: headers(),
      body: JSON.stringify({ op: 'list', filter: { id: idValue(accountId) }, limit: 1 }),
    });
    const body: unknown = await res.json().catch(() => ({}));
    const rows = isRecord(body) ? asArray(body.rows) : [];
    const first = rows[0];
    if (!res.ok || !isRecord(first)) throw new Error(`account ${accountId} not found`);
    return asNumber(first.balance_cents);
  }

  async function run(operations: TxnOp[]): Promise<unknown[]> {
    const res = await fetch(txnUrl, { method: 'POST', headers: headers(), body: JSON.stringify({ mount: pgDbId, operations }) });
    const body: unknown = await res.json().catch(() => ({}));
    if (!res.ok) {
      const message = isRecord(body) && typeof body.message === 'string' ? body.message : `txn failed (${res.status})`;
      throw new Error(message);
    }
    return isRecord(body) ? asArray(body.results) : [];
  }

  // ponytail: read-then-absolute (the two balance reads precede the atomic batch),
  //   so concurrent payments on the same account could race — acceptable for a
  //   single-operator console; a DB BEFORE-UPDATE trigger or row lock hardens it.
  async function recordPayment(input: PaymentInput): Promise<unknown[]> {
    const [customerBalance, revenueBalance] = await Promise.all([
      readBalanceCents(input.customerAccountId),
      readBalanceCents(input.revenueAccountId),
    ]);
    return run(paymentOps(input, customerBalance, revenueBalance));
  }

  return { run, recordPayment };
}
