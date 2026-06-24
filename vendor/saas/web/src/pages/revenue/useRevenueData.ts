// useRevenueData.ts — loads accounts, recent txns and ledger entries for the
// revenue showcase and exposes a single refetch the page calls after a payment,
// so every panel re-reads the post-transaction (committed) state together.

import { useCallback, useEffect, useState } from 'react';
import { useBaas } from '../../providers/useBaas';
import { asNumber } from '../../lib/guards';
import type { Account, Txn, LedgerEntry } from './money';
import { toAccount, toTxn, toLedgerEntry } from './money';

/** RevenueData is the loaded snapshot plus reload/refetch controls. Accounts are
 *  fetched in full (listAll) so the single revenue account is always present even
 *  past the data plane's per-page cap; the recent txns/ledger lists are capped for
 *  display; postedRevenueCents is a TRUE aggregate, so it stays correct at scale. */
export type RevenueData = {
  accounts: Account[];
  txns: Txn[];
  ledger: LedgerEntry[];
  postedRevenueCents: number;
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
  const [postedRevenueCents, setPostedRevenueCents] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    const pg = baas.db.pg;
    Promise.all([
      pg.listAll('accounts', { sort: { id: 'asc' } }),
      pg.list('txns', { sort: { created_at: 'desc' }, limit: 50 }),
      pg.list('ledger_entries', { sort: { id: 'desc' }, limit: 20 }),
      pg.listAll('txns', { filter: { status: { $eq: 'posted' }, kind: { $eq: 'payment' } } }),
    ])
      .then(([a, t, l, posted]) => {
        if (cancelled) return;
        setAccounts(a.map(toAccount));
        setTxns(t.rows.map(toTxn));
        setLedger(l.rows.map(toLedgerEntry));
        setPostedRevenueCents(posted.reduce((acc, row) => acc + asNumber(row.amount_cents), 0));
      })
      .catch((e: unknown) => !cancelled && setError(e instanceof Error ? e.message : 'failed to load revenue data'))
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
  }, [baas, tick]);

  const refetch = useCallback(() => setTick((t) => t + 1), []);
  return { accounts, txns, ledger, postedRevenueCents, loading, error, refetch };
}
