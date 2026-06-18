// user-model.ts — the app_users domain shape + the row→AppUser narrowing and the
// Badge tone maps. One source of truth so the page, row, and dialog agree on the
// role/status vocabulary without copying it. Const unions, never TS enums.

import type { Row } from '../../lib/db';
import type { BadgeTone } from '../../ds/Badge';
import { asString } from '../../lib/guards';

/** ROLES is the closed set of app_users.role values. */
export const ROLES = ['admin', 'staff', 'customer'] as const;

/** STATUSES is the closed set of app_users.status values. */
export const STATUSES = ['active', 'suspended', 'deleted'] as const;

/** UserRole is one of the allowed roles. */
export type UserRole = (typeof ROLES)[number];

/** UserStatus is one of the allowed lifecycle states. */
export type UserStatus = (typeof STATUSES)[number];

/** AppUser is the typed projection of an app_users row used by the UI. */
export type AppUser = {
  id: string;
  email: string;
  name: string;
  role: UserRole;
  status: UserStatus;
  createdAt: string;
};

/** oneOf narrows a string to a member of a const tuple, falling back to its head. */
function oneOf<T extends readonly string[]>(set: T, value: string): T[number] {
  return (set as readonly string[]).includes(value) ? (value as T[number]) : set[0];
}

/** toAppUser narrows an untyped data-plane Row into a typed AppUser. */
export function toAppUser(row: Row): AppUser {
  return {
    id: asString(row.id),
    email: asString(row.email),
    name: asString(row.name),
    role: oneOf(ROLES, asString(row.role, 'customer')),
    status: oneOf(STATUSES, asString(row.status, 'active')),
    createdAt: asString(row.created_at),
  };
}

/** roleTone maps a role to its Badge color treatment. */
export function roleTone(role: UserRole): BadgeTone {
  return role === 'admin' ? 'accent' : role === 'staff' ? 'neutral' : 'neutral';
}

/** statusTone maps a status to its Badge color (active emerald, suspended amber). */
export function statusTone(status: UserStatus): BadgeTone {
  return status === 'active' ? 'success' : status === 'suspended' ? 'warn' : 'neutral';
}

/** formatJoined renders an ISO timestamp as a short, locale-stable joined date. */
export function formatJoined(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}
