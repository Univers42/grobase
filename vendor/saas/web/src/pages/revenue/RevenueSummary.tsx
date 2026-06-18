// RevenueSummary.tsx — the KPI strip: total recognized revenue (sum of posted
// txns), the revenue account balance, and the aggregate customer balance. Numbers
// are derived from the same committed rows the panels render, so they always agree.

import { GlassCard } from '../../ds/GlassCard';
import { Icon } from '../../ds/Icon';
import type { IconName } from '../../ds/Icon';
import type { Account, Txn } from './money';
import { formatCents } from './money';

/** RevenueSummaryProps supplies the typed accounts + transactions to aggregate. */
export type RevenueSummaryProps = { accounts: Account[]; txns: Txn[] };

/** sumBalances totals the balance of accounts matching a kind. */
function sumBalances(accounts: Account[], kind: Account['kind']): number {
  return accounts.filter((a) => a.kind === kind).reduce((acc, a) => acc + a.balanceCents, 0);
}

/** postedRevenue sums amount of posted payment-kind transactions. */
function postedRevenue(txns: Txn[]): number {
  return txns.filter((t) => t.status === 'posted' && t.kind === 'payment').reduce((acc, t) => acc + t.amountCents, 0);
}

/** tile renders one labeled, icon-led money figure. */
function tile(label: string, icon: IconName, cents: number) {
  return (
    <GlassCard key={label} className="flex flex-col gap-2">
      <span className="flex items-center gap-2 text-sm text-muted">
        <Icon name={icon} size={16} /> {label}
      </span>
      <span className="text-2xl font-semibold tracking-tight tabular-nums text-ink">{formatCents(cents)}</span>
    </GlassCard>
  );
}

/** RevenueSummary renders the three headline money figures. */
export function RevenueSummary({ accounts, txns }: RevenueSummaryProps) {
  return (
    <div className="grid gap-4 sm:grid-cols-3">
      {tile('Posted revenue', 'trend', postedRevenue(txns))}
      {tile('Revenue balance', 'zap', sumBalances(accounts, 'revenue'))}
      {tile('Customer balances', 'users', sumBalances(accounts, 'customer'))}
    </div>
  );
}
