// useRevenueData.ts — loads accounts, recent txns and ledger entries for the
// revenue showcase and exposes a single refetch the page calls after a payment,
// so every panel re-reads the post-transaction (committed) state together.

import { useCallback, useEffect, useState } from 'react';
import { useBaas } from '../../providers/useBaas';
import type { Account, Txn, LedgerEntry } from './money';
import { toAccount, toTxn, toLedgerEntry } from './money';

/** RevenueData is the loaded snapshot plus reload/refetch controls. */
export type RevenueData = {
  accounts: Account[];
  txns: Txn[];
  ledger: LedgerEntry[];
  loading: boolean;
  error: string | null;
  refetch: () => void;
};

/** useRevenueData fetches the three money tables and reloads them on demand. */
export function useRevenueData(): RevenueData {
  const baas = useBaas();
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [txns, setTxns] = useState<Txn[]>([]);
  const [ledger, setLedger] = useState<LedgerEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    const pg = baas.db.pg;
    Promise.all([
      pg.list('accounts'),
      pg.list('txns', { sort: { created_at: 'desc' }, limit: 50 }),
      pg.list('ledger_entries', { sort: { id: 'desc' }, limit: 20 }),
    ])
      .then(([a, t, l]) => {
        if (cancelled) return;
        setAccounts(a.rows.map(toAccount));
        setTxns(t.rows.map(toTxn));
        setLedger(l.rows.map(toLedgerEntry));
      })
      .catch((e: unknown) => !cancelled && setError(e instanceof Error ? e.message : 'failed to load revenue data'))
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
  }, [baas, tick]);

  const refetch = useCallback(() => setTick((t) => t + 1), []);
  return { accounts, txns, ledger, loading, error, refetch };
}
