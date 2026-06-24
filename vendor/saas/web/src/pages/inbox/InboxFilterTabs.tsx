// InboxFilterTabs.tsx — the All / Open / Closed segmented control above the list.
// Pure presentation: it reports the chosen folder up to the page.

import clsx from 'clsx';

/** InboxFilter is the active-list folder the tabs select. */
export type InboxFilter = 'all' | 'open' | 'closed';

/** InboxFilterTabsProps wires the active folder and its change handler. */
export type InboxFilterTabsProps = { value: InboxFilter; onChange: (value: InboxFilter) => void };

const tabs: readonly { id: InboxFilter; label: string }[] = [
  { id: 'all', label: 'All' },
  { id: 'open', label: 'Open' },
  { id: 'closed', label: 'Closed' },
];

/** InboxFilterTabs renders the segmented folder control. */
export function InboxFilterTabs({ value, onChange }: InboxFilterTabsProps) {
  return (
    <div className="inline-flex rounded-xl bg-white/5 p-1" role="tablist" aria-label="Filter messages">
      {tabs.map((t) => (
        <button
          key={t.id}
          type="button"
          role="tab"
          aria-selected={value === t.id}
          onClick={() => onChange(t.id)}
          className={clsx(
            'rounded-lg px-3.5 py-1.5 text-sm font-medium transition',
            value === t.id ? 'bg-accent text-accent-fg shadow-sm' : 'text-muted hover:text-ink',
          )}
        >
          {t.label}
        </button>
      ))}
    </div>
  );
}
