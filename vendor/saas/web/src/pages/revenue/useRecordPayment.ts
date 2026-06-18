// useRecordPayment.ts — form state + submit for the atomic payment flow. It calls
// baas.tx.recordPayment (the all-or-nothing /query/v1/txn batch); on success the
// server has committed the inserts + balanced ledger pair + both balance updates,
// on failure it rolled everything back, so we never mutate local balances here.

import { useCallback, useMemo, useState } from 'react';
import { useBaas } from '../../providers/useBaas';
import { useToast } from '../../providers/useToast';
import type { Account } from './money';
import { dollarsToCents } from './money';

/** defaultReference mints a unique idempotency reference for a new payment. */
export function defaultReference(): string {
  return `pay_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
}

/** RecordPaymentForm is the dialog's reactive state + submit surface. */
export type RecordPaymentForm = {
  customerId: string;
  amount: string;
  reference: string;
  submitting: boolean;
  setCustomerId: (id: string) => void;
  setAmount: (amount: string) => void;
  setReference: (reference: string) => void;
  submit: (revenueAccountId: string) => Promise<boolean>;
};

/** useRecordPayment wires the payment form to baas.tx.recordPayment with toasts. */
export function useRecordPayment(customers: Account[], onSuccess: () => void): RecordPaymentForm {
  const baas = useBaas();
  const toast = useToast();
  const [customerId, setCustomerId] = useState('');
  const [amount, setAmount] = useState('');
  const [reference, setReference] = useState(defaultReference());
  const [submitting, setSubmitting] = useState(false);

  const resolvedCustomer = useMemo(
    () => customerId || customers[0]?.id || '',
    [customerId, customers],
  );

  const submit = useCallback(
    async (revenueAccountId: string): Promise<boolean> => {
      const amountCents = dollarsToCents(amount);
      if (!resolvedCustomer || !revenueAccountId || amountCents <= 0) {
        toast.error('Cannot record payment', 'Pick a customer and a positive amount.');
        return false;
      }
      setSubmitting(true);
      try {
        await baas.tx.recordPayment({ customerAccountId: resolvedCustomer, revenueAccountId, amountCents, reference });
        toast.success('Payment recorded atomically', 'Double-entry committed — both balances moved.');
        setAmount('');
        setReference(defaultReference());
        onSuccess();
        return true;
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : 'Transaction failed';
        toast.error('Rolled back — balances unchanged', message);
        return false;
      } finally {
        setSubmitting(false);
      }
    },
    [amount, resolvedCustomer, reference, baas, toast, onSuccess],
  );

  return { customerId: resolvedCustomer, amount, reference, submitting, setCustomerId, setAmount, setReference, submit };
}
