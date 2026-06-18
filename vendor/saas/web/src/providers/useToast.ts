// useToast.ts — convenience accessor for the toast API. Returns push/dismiss plus
// tone shortcuts so call sites read `toast.success('Saved')`.

import { useContext, useMemo } from 'react';
import { ToastContext } from './toast-context';

/** Toaster is the ergonomic toast surface returned by useToast. */
export type Toaster = {
  push: (title: string, description?: string) => void;
  success: (title: string, description?: string) => void;
  error: (title: string, description?: string) => void;
  dismiss: (id: number) => void;
};

/** useToast returns tone-shortcut push helpers over the toast context. */
export function useToast(): Toaster {
  const api = useContext(ToastContext);
  if (!api) throw new Error('useToast must be used within a <ToastProvider>');
  const { push, dismiss } = api;
  return useMemo<Toaster>(
    () => ({
      push: (title, description) => push({ title, description, tone: 'info' }),
      success: (title, description) => push({ title, description, tone: 'success' }),
      error: (title, description) => push({ title, description, tone: 'error' }),
      dismiss,
    }),
    [push, dismiss],
  );
}
