// ToastProvider.tsx — owns the toast queue and renders the Radix viewport. push()
// appends a toast and auto-dismisses it after a timeout; the visual layer lives in
// the Toast design-system component.

import { useCallback, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { ToastContext } from './toast-context';
import type { ToastItem } from './toast-context';
import { ToastViewport } from '../ds/Toast';

/** ToastProviderProps wraps the subtree toasts are available to. */
export type ToastProviderProps = { children: ReactNode };

/** ToastProvider supplies the push/dismiss API and renders queued toasts. */
export function ToastProvider({ children }: ToastProviderProps) {
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const seq = useRef(0);

  const dismiss = useCallback((id: number) => {
    setToasts((list) => list.filter((t) => t.id !== id));
  }, []);

  const push = useCallback<(t: Omit<ToastItem, 'id'>) => void>(
    (t) => {
      const id = ++seq.current;
      setToasts((list) => [...list, { ...t, id }]);
      window.setTimeout(() => dismiss(id), 4500);
    },
    [dismiss],
  );

  return (
    <ToastContext.Provider value={{ toasts, push, dismiss }}>
      {children}
      <ToastViewport toasts={toasts} onDismiss={dismiss} />
    </ToastContext.Provider>
  );
}
