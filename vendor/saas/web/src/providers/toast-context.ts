// toast-context.ts — context + types for the toast system, split from the
// provider component so the hook imports the context without the UI.

import { createContext } from 'react';

/** ToastTone selects the visual treatment. */
export type ToastTone = 'info' | 'success' | 'error';

/** ToastItem is one queued notification. */
export type ToastItem = { id: number; title: string; description?: string; tone: ToastTone };

/** ToastApi is the push/dismiss surface exposed through context. */
export type ToastApi = {
  toasts: ToastItem[];
  push: (t: Omit<ToastItem, 'id'>) => void;
  dismiss: (id: number) => void;
};

/** ToastContext carries the toast API; null until a ToastProvider supplies it. */
export const ToastContext = createContext<ToastApi | null>(null);
