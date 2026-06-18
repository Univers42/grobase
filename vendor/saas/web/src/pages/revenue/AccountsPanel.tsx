// AccountsPanel.tsx — the per-account balance board. Customer and revenue
// accounts are the two sides of every payment, so they are visually highlighted;
// balances are rendered in dollars from integer-cent storage.

import { GlassCard } from '../../ds/GlassCard';
import { Badge } from '../../ds/Badge';
import { Icon } from '../../ds/Icon';
import { EmptyState } from '../../ds/EmptyState';
import type { Account, AccountKind } from './money';
import { formatCents } from './money';

/** AccountsPanelProps supplies the typed accounts to display. */
export type AccountsPanelProps = { accounts: Account[] };

/** kindTone maps an account role to a badge tone. */
function kindTone(kind: AccountKind): 'accent' | 'success' | 'warn' {
  if (kind === 'customer') return 'accent';
  if (kind === 'revenue') return 'success';
  return 'warn';
}

/** accountRow renders one account's role badge and formatted balance. */
function accountRow(account: Account) {
  const highlight = account.kind === 'customer' || account.kind === 'revenue';
  return (
    <li
      key={account.id}
      className={`flex items-center justify-between rounded-xl border px-3.5 py-3 ${highlight ? 'border-accent/20 bg-white/[0.03]' : 'border-line bg-transparent'}`}
    >
      <span className="flex items-center gap-2">
        <Badge tone={kindTone(account.kind)}>{account.kind}</Badge>
        <span className="text-xs text-muted">{account.currency}</span>
      </span>
      <span className="font-semibold tabular-nums text-ink">{formatCents(account.balanceCents)}</span>
    </li>
  );
}

/** AccountsPanel lists each account with its role and live balance. */
export function AccountsPanel({ accounts }: AccountsPanelProps) {
  return (
    <GlassCard className="flex flex-col gap-4">
      <header className="flex items-center justify-between">
        <h2 className="flex items-center gap-2 text-base font-semibold tracking-tight text-ink">
          <Icon name="database" size={16} /> Accounts
        </h2>
        <span className="text-xs text-muted">balance · cents-exact</span>
      </header>
      {accounts.length === 0 ? (
        <EmptyState icon="database" title="No accounts yet" description="Accounts appear here once the tenant is seeded." />
      ) : (
        <ul className="space-y-2">{accounts.map(accountRow)}</ul>
      )}
    </GlassCard>
  );
}
