// UsersPage.tsx — the live users section: a searchable, sortable, paginated table
// over db.pg.list('app_users') via useQueryTable, with a per-row activate/suspend
// toggle and a role/status edit dialog. Loading shows a Spinner, empty an EmptyState.

import { useMemo, useState } from 'react';
import { GlassCard } from '../../ds/GlassCard';
import { Input } from '../../ds/Input';
import { Table } from '../../ds/Table';
import { Spinner } from '../../ds/Spinner';
import { EmptyState } from '../../ds/EmptyState';
import { Button } from '../../ds/Button';
import type { SortDir, SortState } from '../../ds/table-types';
import { useBaas } from '../../providers/useBaas';
import { useQueryTable } from '../../providers/useQueryTable';
import { toAppUser } from './user-model';
import type { AppUser } from './user-model';
import { userColumns } from './user-columns';
import { useUserActions } from './useUserActions';
import { UserEditDialog } from './UserEditDialog';

/** Pager renders the offset pagination controls under the table. */
function Pager({ page, total, size, onPage }: { page: number; total: number; size: number; onPage: (p: number) => void }) {
  const pages = Math.max(1, Math.ceil(total / size));
  return (
    <div className="flex items-center justify-between pt-4 text-sm text-muted">
      <span>{total} user{total === 1 ? '' : 's'}</span>
      <div className="flex items-center gap-2">
        <Button size="sm" variant="ghost" disabled={page <= 1} onClick={() => onPage(page - 1)}>Prev</Button>
        <span className="tabular-nums">{page} / {pages}</span>
        <Button size="sm" variant="ghost" disabled={page >= pages} onClick={() => onPage(page + 1)}>Next</Button>
      </div>
    </div>
  );
}

/** UsersPage renders the searchable, sortable, paginated app_users table. */
export function UsersPage() {
  const baas = useBaas();
  const pageSize = 20;
  const table = useQueryTable({ db: baas.db.pg, table: 'app_users', pageSize, searchColumn: 'name' });
  const [sort, setSortState] = useState<SortState>({ key: 'created_at', dir: 'desc' });
  const [editing, setEditing] = useState<AppUser | null>(null);
  const { busyId, toggle } = useUserActions(table.refetch);

  const users = useMemo(() => table.rows.map(toAppUser), [table.rows]);
  const columns = useMemo(() => userColumns({ busyId, onEdit: setEditing, onToggle: toggle }), [busyId, toggle]);

  const onSort = (key: string, dir: SortDir) => {
    setSortState({ key, dir });
    table.setSort(dir ? { [key]: dir } : undefined);
  };

  return (
    <section className="space-y-5">
      <header className="flex items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-ink">Users</h1>
          <p className="mt-1 text-sm text-muted">Browse, search and manage your tenant's accounts.</p>
        </div>
        <div className="w-64">
          <Input placeholder="Search by name…" value={table.query} onChange={(e) => table.setQuery(e.target.value)} aria-label="Search users by name" />
        </div>
      </header>

      <GlassCard>
        {table.loading ? (
          <div className="flex justify-center py-16"><Spinner size={28} label="Loading users" /></div>
        ) : table.error ? (
          <EmptyState icon="alert" title="Could not load users" description={table.error} />
        ) : users.length === 0 ? (
          <EmptyState icon="users" title="No users found" description={table.query ? 'Try a different search term.' : 'Accounts will appear here once they sign up.'} />
        ) : (
          <>
            <Table columns={columns} rows={users} rowKey={(u) => u.id} sort={sort} onSort={onSort} caption="Tenant users" />
            <Pager page={table.page} total={table.total} size={pageSize} onPage={table.setPage} />
          </>
        )}
      </GlassCard>

      <UserEditDialog key={editing?.id ?? 'none'} user={editing} onOpenChange={(open) => !open && setEditing(null)} onSaved={table.refetch} />
    </section>
  );
}
