// Dialog.tsx — accessible modal over @radix-ui/react-dialog, styled as a glass
// panel with a dimmed backdrop. Radix handles focus trap, escape, and aria roles.

import * as RadixDialog from '@radix-ui/react-dialog';
import type { ReactNode } from 'react';
import { Icon } from './Icon';

/** DialogProps controls an open/close modal with a title and body. */
export type DialogProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description?: string;
  children: ReactNode;
  trigger?: ReactNode;
};

/** Dialog renders a centered glass modal with a backdrop and close button. */
export function Dialog({ open, onOpenChange, title, description, children, trigger }: DialogProps) {
  return (
    <RadixDialog.Root open={open} onOpenChange={onOpenChange}>
      {trigger && <RadixDialog.Trigger asChild>{trigger}</RadixDialog.Trigger>}
      <RadixDialog.Portal>
        <RadixDialog.Overlay className="fixed inset-0 z-40 bg-black/60 backdrop-blur-sm" />
        <RadixDialog.Content className="glass fixed left-1/2 top-1/2 z-50 w-[min(92vw,30rem)] -translate-x-1/2 -translate-y-1/2 rounded-2xl p-6 focus:outline-none">
          <div className="mb-4 flex items-start justify-between gap-4">
            <div>
              <RadixDialog.Title className="text-lg font-semibold tracking-tight text-ink">{title}</RadixDialog.Title>
              {description && <RadixDialog.Description className="mt-1 text-sm text-muted">{description}</RadixDialog.Description>}
            </div>
            <RadixDialog.Close className="rounded-lg p-1.5 text-muted hover:bg-white/5 hover:text-ink" aria-label="Close">
              <Icon name="close" size={18} />
            </RadixDialog.Close>
          </div>
          {children}
        </RadixDialog.Content>
      </RadixDialog.Portal>
    </RadixDialog.Root>
  );
}
