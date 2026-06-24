// EmptyState.tsx — the friendly zero-data panel: an icon, a title, a line of copy,
// and an optional action slot.

import type { ReactNode } from 'react';
import { Icon } from './Icon';
import type { IconName } from './Icon';

/** EmptyStateProps describes the empty panel. */
export type EmptyStateProps = { icon?: IconName; title: string; description?: string; action?: ReactNode };

/** EmptyState renders a centered zero-data placeholder. */
export function EmptyState({ icon = 'sparkles', title, description, action }: EmptyStateProps) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 rounded-2xl border border-dashed border-line px-6 py-14 text-center">
      <span className="grid size-12 place-items-center rounded-2xl bg-accent-soft text-accent">
        <Icon name={icon} size={22} />
      </span>
      <h3 className="text-base font-semibold text-ink">{title}</h3>
      {description && <p className="max-w-sm text-sm text-muted">{description}</p>}
      {action && <div className="pt-2">{action}</div>}
    </div>
  );
}
