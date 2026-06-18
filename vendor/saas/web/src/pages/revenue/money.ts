// money.ts — section-local money model + formatting for the revenue showcase.
// Grobase stores money as integer CENTS; we narrow untrusted rows into typed
// shapes here and render every display value through formatCents.

import type { Row } from '../../lib/db';
import { asString, asNumber } from '../../lib/guards';

/** AccountKind is the ledger role of an account. */
export type AccountKind = 'customer' | 'revenue' | 'fees';

/** Account is one balance-bearing account, balance kept in cents. */
export type Account = { id: string; kind: AccountKind; balanceCents: number; currency: string; ownerUserId: string };

/** TxStatus is the lifecycle of a transaction. */
export type TxStatus = 'pending' | 'posted' | 'failed';

/** Txn is one money movement; amount in cents. */
export type Txn = { id: string; kind: string; amountCents: number; status: TxStatus; reference: string; createdAt: string };

/** LedgerEntry is one debit/credit leg of the double-entry ledger. */
export type LedgerEntry = { id: string; transactionId: string; accountId: string; direction: 'debit' | 'credit'; amountCents: number };

/** formatCents renders an integer-cent amount as $X,XXX.XX. */
export function formatCents(cents: number): string {
  const dollars = cents / 100;
  return dollars.toLocaleString('en-US', { style: 'currency', currency: 'USD' });
}

/** dollarsToCents converts a dollar string/number to rounded integer cents. */
export function dollarsToCents(dollars: string | number): number {
  const n = typeof dollars === 'number' ? dollars : Number(dollars);
  return Number.isFinite(n) ? Math.round(n * 100) : 0;
}

/** toAccount narrows a data-plane row into a typed Account. */
export function toAccount(row: Row): Account {
  return {
    id: asString(row.id),
    kind: (asString(row.kind, 'customer') as AccountKind),
    balanceCents: asNumber(row.balance_cents),
    currency: asString(row.currency, 'USD'),
    ownerUserId: asString(row.owner_user_id),
  };
}

/** toTxn narrows a data-plane row into a typed Txn. */
export function toTxn(row: Row): Txn {
  return {
    id: asString(row.id),
    kind: asString(row.kind, 'payment'),
    amountCents: asNumber(row.amount_cents),
    status: (asString(row.status, 'pending') as TxStatus),
    reference: asString(row.reference),
    createdAt: asString(row.created_at),
  };
}

/** toLedgerEntry narrows a data-plane row into a typed LedgerEntry. */
export function toLedgerEntry(row: Row): LedgerEntry {
  return {
    id: asString(row.id),
    transactionId: asString(row.transaction_id),
    accountId: asString(row.account_id),
    direction: asString(row.direction, 'debit') === 'credit' ? 'credit' : 'debit',
    amountCents: asNumber(row.amount_cents),
  };
}
