// FeatureGrid.tsx — the landing feature trio, each a glass card revealed on scroll
// via Motion. Static copy; the section agents own the real marketing later.

import { GlassCard } from '../../ds/GlassCard';
import { Motion } from '../../ds/Motion';
import { Icon } from '../../ds/Icon';
import type { IconName } from '../../ds/Icon';

type Feature = { icon: IconName; title: string; body: string };

const features: readonly Feature[] = [
  { icon: 'users', title: 'Every user, one view', body: 'Search, sort and inspect your tenant’s accounts with owner-scoped reads — never a cross-tenant leak.' },
  { icon: 'revenue', title: 'Revenue you can trust', body: 'Double-entry payments through atomic transactions, charted from real ledger rows, not guesses.' },
  { icon: 'zap', title: 'Realtime, by default', body: 'Live row changes stream over a single WebSocket so the console reflects your data the instant it moves.' },
];

/** FeatureGrid renders the three landing value cards with staggered entrances. */
export function FeatureGrid() {
  return (
    <section className="mx-auto grid max-w-5xl gap-4 px-6 pb-24 sm:grid-cols-3">
      {features.map((f, i) => (
        <Motion key={f.title} delay={i * 90}>
          <GlassCard className="h-full">
            <span className="mb-4 grid size-11 place-items-center rounded-xl bg-accent-soft text-accent">
              <Icon name={f.icon} size={20} />
            </span>
            <h3 className="text-base font-semibold tracking-tight text-ink">{f.title}</h3>
            <p className="mt-2 text-sm leading-relaxed text-muted">{f.body}</p>
          </GlassCard>
        </Motion>
      ))}
    </section>
  );
}
