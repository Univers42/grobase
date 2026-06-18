// UserEditDialog.tsx — edits an app_user's role + status through ds/Dialog. On save
// it issues db.pg.update('app_users',{data,filter:{id}}), toasts the outcome, and
// refetches the parent table. Role/status are closed enum-like unions, not enums.

import { useState } from 'react';
import { Dialog } from '../../ds/Dialog';
import { Field } from '../../ds/Field';
import { Button } from '../../ds/Button';
import { useBaas } from '../../providers/useBaas';
import { useToast } from '../../providers/useToast';
import type { AppUser, UserRole, UserStatus } from './user-model';
import { ROLES, STATUSES } from './user-model';

/** UserEditDialogProps controls the open modal bound to one user. */
export type UserEditDialogProps = { user: AppUser | null; onOpenChange: (open: boolean) => void; onSaved: () => void };

/** select shares the dark input styling for the two native selects. */
const select = 'w-full h-11 rounded-2xl bg-surface-2/70 border border-line px-4 text-sm text-ink transition focus-visible:border-accent/60';

/** UserEditDialog renders the role/status editor and persists changes on save. */
export function UserEditDialog({ user, onOpenChange, onSaved }: UserEditDialogProps) {
  const baas = useBaas();
  const toast = useToast();
  const [role, setRole] = useState<UserRole>(user?.role ?? 'customer');
  const [status, setStatus] = useState<UserStatus>(user?.status ?? 'active');
  const [saving, setSaving] = useState(false);

  const save = async () => {
    if (!user) return;
    setSaving(true);
    try {
      await baas.db.pg.update('app_users', { role, status }, { id: user.id });
      toast.success('User updated', `${user.name || user.email} saved.`);
      onSaved();
      onOpenChange(false);
    } catch (e: unknown) {
      toast.error('Update failed', e instanceof Error ? e.message : 'Please retry.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={user !== null} onOpenChange={onOpenChange} title="Edit user" description={user?.email}>
      <div className="space-y-4">
        <Field label="Role">
          {({ id }) => (
            <select id={id} className={select} value={role} onChange={(e) => setRole(e.target.value as UserRole)}>
              {ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
            </select>
          )}
        </Field>
        <Field label="Status">
          {({ id }) => (
            <select id={id} className={select} value={status} onChange={(e) => setStatus(e.target.value as UserStatus)}>
              {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
            </select>
          )}
        </Field>
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="ghost" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button onClick={save} loading={saving}>Save changes</Button>
        </div>
      </div>
    </Dialog>
  );
}
