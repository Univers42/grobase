// PagePlaceholder.tsx — the shared "coming soon" scaffold the section agents
// replace. Shows the section heading + an empty-state so routes resolve today.

import { GlassCard } from '../ds/GlassCard';
import { EmptyState } from '../ds/EmptyState';
import type { IconName } from '../ds/Icon';

/** PagePlaceholderProps describes the section being stubbed. */
export type PagePlaceholderProps = { title: string; description: string; icon: IconName };

/** PagePlaceholder renders a section header over a friendly empty panel. */
export function PagePlaceholder({ title, description, icon }: PagePlaceholderProps) {
  return (
    <section className="space-y-5">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight text-ink">{title}</h1>
        <p className="mt-1 text-sm text-muted">{description}</p>
      </header>
      <GlassCard>
        <EmptyState icon={icon} title="Coming soon" description="This section is being built. The foundation, data client and design system are ready for it." />
      </GlassCard>
    </section>
  );
}
