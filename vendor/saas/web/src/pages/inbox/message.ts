// message.ts — the inbox Message model + parsing/format helpers. Mongo rows arrive
// as untyped records, so parseMessage narrows them through guards (no `any`), and
// snippet/relativeTime keep presentation logic out of the components.

import type { Row } from '../../lib/db';
import { asString, asBool, asArray } from '../../lib/guards';

/** MessageStatus is the lifecycle of an inbox message. */
export type MessageStatus = 'open' | 'closed' | 'archived';

/** Message is the narrowed inbox record the UI renders. */
export type Message = {
  id: string;
  from: string;
  subject: string;
  body: string;
  status: MessageStatus;
  read: boolean;
  tags: string[];
  createdAt: string;
};

/** asStatus narrows an unknown to a MessageStatus, defaulting to 'open'. */
function asStatus(value: unknown): MessageStatus {
  return value === 'closed' || value === 'archived' ? value : 'open';
}

/** parseMessage narrows a raw Mongo row into a typed Message. The data plane
 *  surfaces Mongo's `_id` as `id` (hex string), so read `id` first, `_id` second. */
export function parseMessage(row: Row): Message {
  return {
    id: asString(row.id ?? row._id),
    from: asString(row.from, 'unknown'),
    subject: asString(row.subject, '(no subject)'),
    body: asString(row.body),
    status: asStatus(row.status),
    read: asBool(row.read),
    tags: asArray(row.tags).map((t) => asString(t)).filter(Boolean),
    createdAt: asString(row.created_at),
  };
}

/** snippet trims a body to a single-line preview of at most `max` chars. */
export function snippet(body: string, max = 90): string {
  const flat = body.replace(/\s+/g, ' ').trim();
  return flat.length > max ? `${flat.slice(0, max).trimEnd()}…` : flat;
}

/** relativeTime renders an ISO timestamp as a compact "5m" / "2h" / "3d" label. */
export function relativeTime(iso: string): string {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return '';
  const secs = Math.max(0, Math.round((Date.now() - then) / 1000));
  if (secs < 60) return 'now';
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.round(hours / 24);
  return days < 7 ? `${days}d` : new Date(then).toLocaleDateString();
}
