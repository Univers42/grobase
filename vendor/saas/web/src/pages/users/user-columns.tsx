// user-columns.tsx — the ds/Table column definitions for the users grid. Kept out
// of UsersPage so the page stays under the line budget and the columns have one
// home. Each render delegates to a UserRow cell component.

import type { Column } from '../../ds/table-types';
import type { AppUser } from './user-model';
import { formatJoined } from './user-model';
import { UserIdentity, UserRoleBadge, UserStatusBadge, UserActions } from './UserRow';

/** ColumnHandlers supply the per-row actions the actions column needs. */
export type ColumnHandlers = { busyId: string | null; onEdit: (user: AppUser) => void; onToggle: (user: AppUser) => void };

/** userColumns builds the sortable column set, wiring the action handlers in. */
export function userColumns({ busyId, onEdit, onToggle }: ColumnHandlers): Column<AppUser>[] {
  return [
    { key: 'name', header: 'User', sortable: true, render: (u) => <UserIdentity user={u} /> },
    { key: 'role', header: 'Role', sortable: true, render: (u) => <UserRoleBadge user={u} /> },
    { key: 'status', header: 'Status', sortable: true, render: (u) => <UserStatusBadge user={u} /> },
    { key: 'created_at', header: 'Joined', sortable: true, render: (u) => <span className="text-muted">{formatJoined(u.createdAt)}</span> },
    {
      key: 'actions',
      header: '',
      align: 'right',
      render: (u) => <UserActions user={u} busy={busyId === u.id} onEdit={onEdit} onToggle={onToggle} />,
    },
  ];
}
