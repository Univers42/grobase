// RecordPaymentDialog.tsx — the ACID showcase. The operator picks a customer
// account and an amount; submit posts ONE atomic batch (payment + balanced ledger
// pair + both balance updates). The before→after projection makes the all-or-
// nothing money move visible; on a duplicate reference / bad data the server
// rolls back (HTTP 409) and the projection never lands.

import { Dialog } from '../../ds/Dialog';
import { Button } from '../../ds/Button';
import { Input } from '../../ds/Input';
import { Field } from '../../ds/Field';
import { Badge } from '../../ds/Badge';
import type { Account } from './money';
import { formatCents, dollarsToCents } from './money';
import { useRecordPayment } from './useRecordPayment';

/** RecordPaymentDialogProps wires the modal to the live accounts + refresh. */
export type RecordPaymentDialogProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  customers: Account[];
  revenueAccount: Account | undefined;
  onRecorded: () => void;
};

/** projection renders the customer's before→after balance for the entered amount. */
function projection(customer: Account | undefined, amount: string) {
  if (!customer) return null;
  const after = customer.balanceCents - dollarsToCents(amount);
  return (
    <div className="flex items-center justify-between rounded-xl border border-accent/20 bg-white/[0.03] px-3.5 py-3 text-sm">
      <span className="text-muted">{formatCents(customer.balanceCents)}</span>
      <span className="text-accent">→</span>
      <span className="font-semibold tabular-nums text-ink">{formatCents(after)}</span>
    </div>
  );
}

/** RecordPaymentDialog is the modal form that records one atomic payment. */
export function RecordPaymentDialog({ open, onOpenChange, customers, revenueAccount, onRecorded }: RecordPaymentDialogProps) {
  const form = useRecordPayment(customers, () => {
    onRecorded();
    onOpenChange(false);
  });
  const selected = customers.find((c) => c.id === form.customerId);

  const handleSubmit = (event: React.FormEvent) => {
    event.preventDefault();
    void form.submit(revenueAccount?.id ?? '');
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange} title="Record payment" description="One atomic double-entry batch — all-or-nothing.">
      <form className="space-y-4" onSubmit={handleSubmit}>
        <Field label="Customer account">
          {({ id }) => (
            <select
              id={id}
              value={form.customerId}
              onChange={(e) => form.setCustomerId(e.target.value)}
              className="h-11 w-full rounded-2xl border border-line bg-surface-2/70 px-4 text-sm text-ink"
            >
              {customers.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.kind} · {formatCents(c.balanceCents)}
                </option>
              ))}
            </select>
          )}
        </Field>
        <Field label="Amount (USD)" hint="Stored as integer cents; posted to the revenue account.">
          {({ id, invalid }) => (
            <Input id={id} invalid={invalid} type="number" min="0.01" step="0.01" placeholder="0.00" value={form.amount} onChange={(e) => form.setAmount(e.target.value)} />
          )}
        </Field>
        <Field label="Reference" hint="Unique idempotency key — a duplicate rolls back (409).">
          {({ id }) => <Input id={id} value={form.reference} onChange={(e) => form.setReference(e.target.value)} />}
        </Field>
        {projection(selected, form.amount)}
        <p className="flex items-center gap-2 text-xs text-muted">
          <Badge tone="accent">double-entry</Badge> debit customer · credit revenue · committed together or not at all.
        </p>
        <div className="flex justify-end gap-2 pt-1">
          <Button variant="ghost" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button type="submit" loading={form.submitting} disabled={!revenueAccount}>Record payment</Button>
        </div>
      </form>
    </Dialog>
  );
}
