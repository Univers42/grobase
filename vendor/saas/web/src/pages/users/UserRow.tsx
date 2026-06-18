// UserRow.tsx — the cell renderers for one app_users row: an avatar + name/email
// identity cell, role/status pills, and an actions cell with Edit + a quick
// activate/deactivate toggle. Returned as Column.render fragments to ds/Table.

import { Avatar } from '../../ds/Avatar';
import { Badge } from '../../ds/Badge';
import { Button } from '../../ds/Button';
import type { AppUser } from './user-model';
import { roleTone, statusTone } from './user-model';

/** UserActionsProps wires the per-row Edit + activate/deactivate handlers. */
export type UserActionsProps = { user: AppUser; busy: boolean; onEdit: (user: AppUser) => void; onToggle: (user: AppUser) => void };

/** UserIdentity renders the avatar with the user's name and email. */
export function UserIdentity({ user }: { user: AppUser }) {
  return (
    <div className="flex items-center gap-3">
      <Avatar name={user.name || user.email} size={36} />
      <div className="min-w-0">
        <div className="truncate font-medium text-ink">{user.name || '—'}</div>
        <div className="truncate text-xs text-muted">{user.email}</div>
      </div>
    </div>
  );
}

/** UserRoleBadge renders the role pill. */
export function UserRoleBadge({ user }: { user: AppUser }) {
  return <Badge tone={roleTone(user.role)}>{user.role}</Badge>;
}

/** UserStatusBadge renders the status pill (active emerald, suspended amber). */
export function UserStatusBadge({ user }: { user: AppUser }) {
  return <Badge tone={statusTone(user.status)}>{user.status}</Badge>;
}

/** UserActions renders the Edit button and the quick activate/deactivate toggle. */
export function UserActions({ user, busy, onEdit, onToggle }: UserActionsProps) {
  const suspended = user.status === 'suspended';
  return (
    <div className="flex items-center justify-end gap-2">
      <Button size="sm" variant="secondary" onClick={() => onEdit(user)}>Edit</Button>
      <Button
        size="sm"
        variant={suspended ? 'primary' : 'ghost'}
        loading={busy}
        disabled={user.status === 'deleted'}
        onClick={() => onToggle(user)}
      >
        {suspended ? 'Activate' : 'Suspend'}
      </Button>
    </div>
  );
}
