// useOverview.ts — owns the dashboard's live data. One mount-time fetch pulls the
// real rows behind every KPI (posted revenue, active users, open mail, total
// balance), the revenue chart, and the activity feed from the Postgres + Mongo
// mounts, narrows them through the section model, and exposes a single reactive
// snapshot so the page stays presentational. Failures surface as `error`, never a
// crash — a broken query degrades one tile, the dashboard still renders.

import { useEffect, useState } from 'react';
import { useBaas } from '../../providers/useBaas';
import type { ChartPoint } from '../../ds/chart-geometry';
import type { Kpi, ActivityItem } from './overview-data';
import { toActivityItem, revenueSeries, sumCents, seriesTail } from './overview-data';
import { formatCents } from '../revenue/money';

/** OverviewData is the reactive dashboard snapshot the page renders. */
export type OverviewData = {
  kpis: Kpi[];
  revenue: ChartPoint[];
  activity: ActivityItem[];
  loading: boolean;
  error: string | null;
};

/** buildKpis assembles the four headline tiles from the fetched aggregates. */
function buildKpis(revenueCents: number, activeUsers: number, openMail: number, balanceCents: number, series: ChartPoint[]): Kpi[] {
  const trend = seriesTail(series, 7);
  return [
    { label: 'Revenue (posted)', value: formatCents(revenueCents), delta: 0, icon: 'revenue', series: trend },
    { label: 'Active users', value: activeUsers.toLocaleString('en-US'), delta: 0, icon: 'users', series: trend },
    { label: 'Open mail', value: openMail.toLocaleString('en-US'), delta: 0, icon: 'inbox', series: trend },
    { label: 'Total balance', value: formatCents(balanceCents), delta: 0, icon: 'shield', series: trend },
  ];
}

/** useOverview fetches and narrows every live figure the overview dashboard shows. */
export function useOverview(): OverviewData {
  const { db } = useBaas();
  const [data, setData] = useState<OverviewData>({ kpis: [], revenue: [], activity: [], loading: true, error: null });

  useEffect(() => {
    let cancelled = false;
    setData((prev) => ({ ...prev, loading: true, error: null }));
    Promise.all([
      db.pg.listAll('txns', { filter: { status: { $eq: 'posted' } }, sort: { created_at: 'desc' } }),
      db.pg.count('app_users', { filter: { status: { $eq: 'active' } } }),
      db.mongo.count('messages', { filter: { status: { $eq: 'open' } } }),
      db.pg.listAll('accounts', {}),
      db.mongo.list('activity', { sort: { ts: 'desc' }, limit: 8 }),
    ])
      .then(([txns, activeUsers, openMail, accounts, activity]) => {
        if (cancelled) return;
        const series = revenueSeries(txns);
        const revenueCents = sumCents(txns, 'amount_cents');
        const balanceCents = sumCents(accounts, 'balance_cents');
        setData({
          kpis: buildKpis(revenueCents, activeUsers, openMail, balanceCents, series),
          revenue: series,
          activity: activity.rows.map(toActivityItem),
          loading: false,
          error: null,
        });
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setData((prev) => ({ ...prev, loading: false, error: e instanceof Error ? e.message : 'failed to load dashboard' }));
      });
    return () => {
      cancelled = true;
    };
  }, [db]);

  return data;
}
