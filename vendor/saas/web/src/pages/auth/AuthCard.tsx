// AuthCard.tsx — the glass shell shared by login/register/forgot: an aurora-lit
// centered card with the brand mark, a title, the form slot, and a footer link.

import { Link } from 'react-router-dom';
import type { ReactNode } from 'react';
import { GlassCard } from '../../ds/GlassCard';
import { Icon } from '../../ds/Icon';

/** AuthCardProps describes the title, body, and footer of an auth screen. */
export type AuthCardProps = { title: string; subtitle: string; children: ReactNode; footer: ReactNode };

/** AuthCard centers a glass auth panel over the aurora backdrop. */
export function AuthCard({ title, subtitle, children, footer }: AuthCardProps) {
  return (
    <div className="relative grid min-h-screen place-items-center overflow-hidden px-5 py-12">
      <div className="aurora animate-drift" aria-hidden />
      <div className="relative w-full max-w-md">
        <Link to="/" className="mb-6 flex items-center justify-center gap-2.5">
          <span className="grid size-9 place-items-center rounded-xl bg-gradient-to-br from-accent to-cyan text-accent-fg">
            <Icon name="zap" size={18} />
          </span>
          <span className="text-xl font-semibold tracking-tight text-ink">Nimbus</span>
        </Link>
        <GlassCard glow className="p-7">
          <h1 className="text-2xl font-semibold tracking-tight text-ink">{title}</h1>
          <p className="mt-1 text-sm text-muted">{subtitle}</p>
          <div className="mt-6">{children}</div>
        </GlassCard>
        <p className="mt-5 text-center text-sm text-muted">{footer}</p>
      </div>
    </div>
  );
}
