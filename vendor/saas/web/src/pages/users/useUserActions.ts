// useUserActions.ts — the quick activate/deactivate toggle for one row. Tracks the
// in-flight user id (for the row spinner), flips active↔suspended via db.pg.update,
// toasts the outcome, and refetches the table on success.

import { useCallback, useState } from 'react';
import { useBaas } from '../../providers/useBaas';
import { useToast } from '../../providers/useToast';
import type { AppUser, UserStatus } from './user-model';

/** UserActionsApi exposes the busy id and the toggle handler to the page. */
export type UserActionsApi = { busyId: string | null; toggle: (user: AppUser) => void };

/** useUserActions wires the row-level status toggle against the pg mount. */
export function useUserActions(refetch: () => void): UserActionsApi {
  const baas = useBaas();
  const toast = useToast();
  const [busyId, setBusyId] = useState<string | null>(null);

  const toggle = useCallback(
    (user: AppUser) => {
      const next: UserStatus = user.status === 'suspended' ? 'active' : 'suspended';
      setBusyId(user.id);
      baas.db.pg
        .update('app_users', { status: next }, { id: user.id })
        .then(() => {
          toast.success(next === 'active' ? 'User activated' : 'User suspended', user.email);
          refetch();
        })
        .catch((e: unknown) => toast.error('Action failed', e instanceof Error ? e.message : 'Please retry.'))
        .finally(() => setBusyId(null));
    },
    [baas, toast, refetch],
  );

  return { busyId, toggle };
}
