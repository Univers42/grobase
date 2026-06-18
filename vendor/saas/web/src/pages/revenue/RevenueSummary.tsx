// RevenueSummary.tsx — the KPI strip: total recognized revenue (sum of posted
// txns), the revenue account balance, and the aggregate customer balance. Numbers
// are derived from the same committed rows the panels render, so they always agree.

import { GlassCard } from '../../ds/GlassCard';
import { Icon } from '../../ds/Icon';
import type { IconName } from '../../ds/Icon';
import type { Account } from './money';
import { formatCents } from './money';

/** RevenueSummaryProps supplies the accounts to aggregate plus the true posted
 *  revenue total (a full aggregate, not the capped recent-txns sample). */
export type RevenueSummaryProps = { accounts: Account[]; postedRevenueCents: number };

/** sumBalances totals the balance of accounts matching a kind. */
function sumBalances(accounts: Account[], kind: Account['kind']): number {
  return accounts.filter((a) => a.kind === kind).reduce((acc, a) => acc + a.balanceCents, 0);
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
export function RevenueSummary({ accounts, postedRevenueCents }: RevenueSummaryProps) {
  return (
    <div className="grid gap-4 sm:grid-cols-3">
      {tile('Posted revenue', 'trend', postedRevenueCents)}
      {tile('Revenue balance', 'zap', sumBalances(accounts, 'revenue'))}
      {tile('Customer balances', 'users', sumBalances(accounts, 'customer'))}
    </div>
  );
}
