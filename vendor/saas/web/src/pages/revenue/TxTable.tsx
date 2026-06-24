// TxTable.tsx — the recent-transactions table (kind, amount, status, reference,
// date). Status drives the badge tone; amounts render in dollars from cents.

import { Table } from '../../ds/Table';
import type { Column } from '../../ds/table-types';
import { GlassCard } from '../../ds/GlassCard';
import { Badge } from '../../ds/Badge';
import type { BadgeTone } from '../../ds/Badge';
import { Icon } from '../../ds/Icon';
import { EmptyState } from '../../ds/EmptyState';
import type { Txn, TxStatus } from './money';
import { formatCents } from './money';

/** TxTableProps supplies the typed transaction rows. */
export type TxTableProps = { txns: Txn[] };

/** statusTone maps a transaction status to its badge color. */
function statusTone(status: TxStatus): BadgeTone {
  if (status === 'posted') return 'success';
  if (status === 'pending') return 'warn';
  return 'danger';
}

/** formatDate renders an ISO timestamp as a short local date-time, or em dash. */
function formatDate(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

const columns: Column<Txn>[] = [
  { key: 'kind', header: 'Kind', render: (t) => <span className="capitalize text-ink">{t.kind}</span> },
  { key: 'amount', header: 'Amount', align: 'right', render: (t) => <span className="font-medium tabular-nums">{formatCents(t.amountCents)}</span> },
  { key: 'status', header: 'Status', render: (t) => <Badge tone={statusTone(t.status)}>{t.status}</Badge> },
  { key: 'reference', header: 'Reference', render: (t) => <span className="font-mono text-xs text-muted">{t.reference || '—'}</span> },
  { key: 'date', header: 'Date', align: 'right', render: (t) => <span className="text-muted">{formatDate(t.createdAt)}</span> },
];

/** TxTable renders the 50 most recent transactions, newest first. */
export function TxTable({ txns }: TxTableProps) {
  return (
    <GlassCard className="flex flex-col gap-4">
      <header className="flex items-center justify-between">
        <h2 className="flex items-center gap-2 text-base font-semibold tracking-tight text-ink">
          <Icon name="trend" size={16} /> Transactions
        </h2>
        <span className="text-xs text-muted">latest 50 · newest first</span>
      </header>
      {txns.length === 0 ? (
        <EmptyState icon="trend" title="No transactions yet" description="Record a payment to post the first double-entry transaction." />
      ) : (
        <Table columns={columns} rows={txns} rowKey={(t) => t.id || t.reference} caption="Recent transactions" />
      )}
    </GlassCard>
  );
}
