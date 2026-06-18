// RevenuePage.tsx — the revenue section: the showcase of the ACID double-entry
// money model. A KPI strip over accounts + transactions, a "Record payment" button
// that opens the atomic batch dialog, and the balanced ledger. Every panel reads
// the same committed snapshot and refreshes together after a payment commits.

import { useState } from 'react';
import { Button } from '../../ds/Button';
import { Badge } from '../../ds/Badge';
import { Icon } from '../../ds/Icon';
import { Spinner } from '../../ds/Spinner';
import { Motion } from '../../ds/Motion';
import { RevenueSummary } from './RevenueSummary';
import { AccountsPanel } from './AccountsPanel';
import { TxTable } from './TxTable';
import { LedgerPanel } from './LedgerPanel';
import { RecordPaymentDialog } from './RecordPaymentDialog';
import { useRevenueData } from './useRevenueData';

/** RevenuePage composes the money model showcase and the payment flow. */
export function RevenuePage() {
  const { accounts, txns, ledger, postedRevenueCents, loading, error, refetch } = useRevenueData();
  const [dialogOpen, setDialogOpen] = useState(false);

  const customers = accounts.filter((a) => a.kind === 'customer');
  const revenueAccount = accounts.find((a) => a.kind === 'revenue');

  return (
    <section className="space-y-5">
      <header className="flex items-end justify-between gap-4">
        <div>
          <h1 className="flex items-center gap-2 text-2xl font-semibold tracking-tight text-ink">
            Revenue <Badge tone="accent">ACID</Badge>
          </h1>
          <p className="mt-1 text-sm text-muted">Double-entry, all-or-nothing payments over a transactional ledger.</p>
        </div>
        <Button onClick={() => setDialogOpen(true)} disabled={!revenueAccount}>
          <Icon name="plus" size={16} /> Record payment
        </Button>
      </header>

      {error && <p className="rounded-2xl border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger" role="alert">{error}</p>}
      {loading && accounts.length === 0 ? (
        <div className="flex items-center gap-2 text-sm text-muted"><Spinner /> Loading revenue data…</div>
      ) : (
        <>
          <RevenueSummary accounts={accounts} postedRevenueCents={postedRevenueCents} />
          <div className="grid gap-5 lg:grid-cols-2">
            <Motion><AccountsPanel accounts={accounts} /></Motion>
            <Motion delay={70}><TxTable txns={txns} /></Motion>
          </div>
          <Motion delay={140}><LedgerPanel entries={ledger} accounts={accounts} /></Motion>
        </>
      )}

      <RecordPaymentDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        customers={customers}
        revenueAccount={revenueAccount}
        onRecorded={refetch}
      />
    </section>
  );
}
