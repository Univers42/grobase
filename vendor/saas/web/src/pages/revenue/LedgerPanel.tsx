// LedgerPanel.tsx — the double-entry ledger view: each row is one debit or credit
// leg. Debits and credits are color-coded so the balanced pairs of a payment are
// visible at a glance — every credit has an equal-and-opposite debit.

import { GlassCard } from '../../ds/GlassCard';
import { Badge } from '../../ds/Badge';
import { Icon } from '../../ds/Icon';
import { EmptyState } from '../../ds/EmptyState';
import type { LedgerEntry, Account } from './money';
import { formatCents } from './money';

/** LedgerPanelProps supplies the entries plus accounts for label resolution. */
export type LedgerPanelProps = { entries: LedgerEntry[]; accounts: Account[] };

/** accountLabel resolves an account id to its kind, or a short id fallback. */
function accountLabel(accounts: Account[], id: string): string {
  const found = accounts.find((a) => a.id === id);
  return found ? found.kind : id ? `${id.slice(0, 8)}…` : '—';
}

/** entryRow renders one debit/credit leg with a color-coded direction badge. */
function entryRow(entry: LedgerEntry, accounts: Account[]) {
  const debit = entry.direction === 'debit';
  return (
    <li key={entry.id} className="flex items-center justify-between gap-3 rounded-xl border border-line px-3.5 py-2.5">
      <span className="flex items-center gap-2">
        <Badge tone={debit ? 'warn' : 'success'}>{entry.direction}</Badge>
        <span className="text-xs capitalize text-muted">{accountLabel(accounts, entry.accountId)}</span>
      </span>
      <span className={`font-medium tabular-nums ${debit ? 'text-warn' : 'text-success'}`}>
        {debit ? '−' : '+'}
        {formatCents(entry.amountCents)}
      </span>
    </li>
  );
}

/** LedgerPanel renders the 20 most recent ledger legs, newest first. */
export function LedgerPanel({ entries, accounts }: LedgerPanelProps) {
  return (
    <GlassCard className="flex flex-col gap-4">
      <header className="flex items-center justify-between">
        <h2 className="flex items-center gap-2 text-base font-semibold tracking-tight text-ink">
          <Icon name="shield" size={16} /> Ledger
        </h2>
        <span className="text-xs text-muted">debit = credit · always balanced</span>
      </header>
      {entries.length === 0 ? (
        <EmptyState icon="shield" title="Ledger is empty" description="Each payment writes a balanced debit/credit pair here." />
      ) : (
        <ul className="space-y-2">{entries.map((e) => entryRow(e, accounts))}</ul>
      )}
    </GlassCard>
  );
}
