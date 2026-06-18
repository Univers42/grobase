// Toast.tsx — the Radix toast viewport + items rendered from the provider queue.
// role=status is supplied by Radix; tone selects the accent edge.

import * as RadixToast from '@radix-ui/react-toast';
import clsx from 'clsx';
import type { ToastItem, ToastTone } from '../providers/toast-context';
import { Icon } from './Icon';
import type { IconName } from './Icon';

/** ToastViewportProps feeds the queued toasts + dismiss handler from the provider. */
export type ToastViewportProps = { toasts: ToastItem[]; onDismiss: (id: number) => void };

const toneIcon: Record<ToastTone, IconName> = { info: 'info', success: 'ok', error: 'alert' };
const toneClass: Record<ToastTone, string> = {
  info: 'text-accent',
  success: 'text-success',
  error: 'text-danger',
};

/** ToastViewport renders the toast stack in the bottom-right via a Radix provider. */
export function ToastViewport({ toasts, onDismiss }: ToastViewportProps) {
  return (
    <RadixToast.Provider swipeDirection="right" duration={4500}>
      {toasts.map((t) => (
        <RadixToast.Root
          key={t.id}
          onOpenChange={(open) => !open && onDismiss(t.id)}
          className="glass flex w-80 items-start gap-3 rounded-2xl p-4 data-[state=open]:animate-rise"
        >
          <Icon name={toneIcon[t.tone]} size={18} className={clsx('mt-0.5 shrink-0', toneClass[t.tone])} />
          <div className="min-w-0 flex-1">
            <RadixToast.Title className="text-sm font-medium text-ink">{t.title}</RadixToast.Title>
            {t.description && <RadixToast.Description className="mt-0.5 text-xs text-muted">{t.description}</RadixToast.Description>}
          </div>
          <RadixToast.Close className="rounded-md p-1 text-muted hover:text-ink" aria-label="Dismiss">
            <Icon name="close" size={14} />
          </RadixToast.Close>
        </RadixToast.Root>
      ))}
      <RadixToast.Viewport className="fixed bottom-4 right-4 z-[60] flex w-80 flex-col gap-2 outline-none" />
    </RadixToast.Provider>
  );
}
