// KpiCard.tsx — a single KPI tile: label, big value, delta badge, and a sparkline.
// Pure presentation; the overview page supplies the (currently sample) numbers.

import { GlassCard } from '../../ds/GlassCard';
import { Sparkline } from '../../ds/Sparkline';
import { Badge } from '../../ds/Badge';
import { Icon } from '../../ds/Icon';
import type { IconName } from '../../ds/Icon';

/** KpiCardProps describes one metric tile. */
export type KpiCardProps = {
  label: string;
  value: string;
  delta: number;
  icon: IconName;
  series: number[];
};

/** KpiCard renders a metric with its trend and signed delta. */
export function KpiCard({ label, value, delta, icon, series }: KpiCardProps) {
  const up = delta >= 0;
  return (
    <GlassCard className="flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <span className="flex items-center gap-2 text-sm text-muted">
          <Icon name={icon} size={16} /> {label}
        </span>
        <Badge tone={up ? 'success' : 'danger'}>
          <Icon name={up ? 'up' : 'down'} size={12} /> {Math.abs(delta)}%
        </Badge>
      </div>
      <p className="text-3xl font-semibold tracking-tight text-ink tabular-nums">{value}</p>
      <Sparkline data={series} width={160} height={34} stroke={up ? '#39E5C8' : '#FF6B6B'} label={`${label} trend`} />
    </GlassCard>
  );
}
