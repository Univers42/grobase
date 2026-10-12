// provision.ts — turns a GoTrue auth identity into REAL console data. After a
// signup (or a self-heal on login), the app must create the app_users row the
// console reads (the console queries app_users, not GoTrue), plus a zero-balance
// customer account for a customer. Writes ride the caller's JWT, so a customer's
// self-provisioned rows are owner-scoped to `user:<sub>` (only they and an admin
// JWT's F2 bypass can read them) — a customer can never see another's rows.
//
// Idempotency is read-then-insert by primary key (the owner-scoped mount has no
// composite UNIQUE for a SQL upsert), so a retried signup never duplicates.

import type { Db, Row } from './db';

/** ProvisionInput is the identity a signup/login resolves to. */
export type ProvisionInput = { id: string; email: string; name: string; role?: string };

/** ROLE_DEFAULT is the role a self-service signup gets (and the account-bearing one). */
const ROLE_DEFAULT = 'customer';

/** userRow builds the app_users insert payload (status active, role defaulted). */
function userRow(input: ProvisionInput): Row {
  return {
    id: input.id,
    email: input.email,
    name: input.name || input.email,
    role: input.role ?? ROLE_DEFAULT,
    status: 'active',
  };
}

/** ensureCustomerAccount inserts a zero-balance customer account once per user.
 *  It first checks for an existing customer account so a retry is a no-op. */
async function ensureCustomerAccount(db: Db, userId: string): Promise<void> {
  const existing = await db.list('accounts', { where: { owner_user_id: userId, kind: 'customer' }, limit: 1 });
  if (existing.rows.length > 0) return;
  await db.insert('accounts', { owner_user_id: userId, kind: 'customer', balance_cents: 0, currency: 'USD' });
}

/** insertAppUserUnlessPresent inserts the row and reports whether it was created.
 *  Caveat: the duplicate is recognised by the data plane's `conflict:` message
 *  prefix, not a status code, because Db surfaces only the message. A row that
 *  exists but is hidden from this caller's read (an admin JWT without the F2
 *  bypass) lands here; any other failure is rethrown. */
async function insertAppUserUnlessPresent(db: Db, row: Row): Promise<boolean> {
  try {
    await db.insert('app_users', row);
    return true;
  } catch (err) {
    if (err instanceof Error && err.message.startsWith('conflict:')) return false;
    throw err;
  }
}

/** ensureAppUser makes the auth identity visible to the console: it inserts the
 *  app_users row when absent (idempotent by id) and, for a customer, a paired
 *  zero-balance account. Returns true when it created the user row (vs. found it).
 *  A row that exists but is not readable by this caller has an unknown role, so
 *  no customer account is created for it. */
export async function ensureAppUser(db: Db, input: ProvisionInput): Promise<boolean> {
  if (!input.id) return false;
  const found = await db.get('app_users', { id: input.id });
  if (found === null) {
    const created = await insertAppUserUnlessPresent(db, userRow(input));
    if (!created) return false;
    if ((input.role ?? ROLE_DEFAULT) === ROLE_DEFAULT) await ensureCustomerAccount(db, input.id);
    return true;
  }
  const role = (found.role as string | undefined) ?? input.role ?? ROLE_DEFAULT;
  if (role === ROLE_DEFAULT) await ensureCustomerAccount(db, input.id);
  return false;
}
