// OverviewPage.tsx — the dashboard landing: a live KPI row over the hand-rolled SVG
// revenue chart, beside the recent-activity feed. All figures come from real
// Postgres + Mongo queries via useOverview; loading and error states degrade
// gracefully so a slow or failed query never blanks the dashboard.

import { KpiCard } from './KpiCard';
import { ActivityFeed } from './ActivityFeed';
import { useOverview } from './useOverview';
import { GlassCard } from '../../ds/GlassCard';
import { RevenueChart } from '../../ds/RevenueChart';
import { Spinner } from '../../ds/Spinner';
import { EmptyState } from '../../ds/EmptyState';
import { Badge } from '../../ds/Badge';
import { Motion } from '../../ds/Motion';
import { useAuth } from '../../providers/useAuth';
import { formatCents } from '../revenue/money';

/** KpiRow renders the four headline tiles, or a spinner while the figures load. */
function KpiRow({ loading, kpis }: { loading: boolean; kpis: ReturnType<typeof useOverview>['kpis'] }) {
  if (loading && kpis.length === 0) {
    return (
      <GlassCard className="grid place-items-center py-10">
        <Spinner label="Loading metrics" />
      </GlassCard>
    );
  }
  return (
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      {kpis.map((k, i) => (
        <Motion key={k.label} delay={i * 70}>
          <KpiCard {...k} />
        </Motion>
      ))}
    </div>
  );
}

/** RevenuePanel renders the revenue chart, or loading/empty fallbacks. */
function RevenuePanel({ loading, revenue }: { loading: boolean; revenue: ReturnType<typeof useOverview>['revenue'] }) {
  const hasData = revenue.some((p) => p.value > 0);
  return (
    <GlassCard>
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-base font-semibold tracking-tight text-ink">Revenue</h2>
        <span className="text-sm text-muted">posted · last {revenue.length || 8} days</span>
      </div>
      {loading && revenue.length === 0 ? (
        <div className="grid place-items-center py-10">
          <Spinner label="Loading revenue" />
        </div>
      ) : hasData ? (
        <RevenueChart data={[...revenue]} format={(v) => formatCents(Math.round(v * 100))} ariaLabel="Posted revenue by day" />
      ) : (
        <EmptyState icon="revenue" title="No posted revenue yet" description="Posted transactions will chart here as they land." />
      )}
    </GlassCard>
  );
}

/** OverviewPage renders the live KPI tiles, revenue chart, and activity feed. */
export function OverviewPage() {
  const { user } = useAuth();
  const greeting = user?.username || user?.email?.split('@')[0] || 'there';
  const { kpis, revenue, activity, loading, error } = useOverview();

  return (
    <section className="space-y-5">
      <header className="flex items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-ink">
            Welcome back, <span className="display-italic text-accent">{greeting}</span>
          </h1>
          <p className="mt-1 text-sm text-muted">Here’s how your workspace is doing today.</p>
        </div>
        <Badge tone={error ? 'danger' : 'accent'}>{error ? 'Degraded' : 'Live'}</Badge>
      </header>

      <KpiRow loading={loading} kpis={kpis} />

      <div className="grid gap-4 lg:grid-cols-3">
        <Motion delay={120} className="lg:col-span-2">
          <RevenuePanel loading={loading} revenue={revenue} />
        </Motion>
        <Motion delay={160}>
          <ActivityFeed items={activity} loading={loading} error={error} />
        </Motion>
      </div>
    </section>
  );
}
