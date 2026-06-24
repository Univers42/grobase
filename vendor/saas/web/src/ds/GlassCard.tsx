// GlassCard.tsx — the glassmorphism panel: translucent blurred surface, subtle
// border + inner glow. `glow` adds the violet edge for hero/emphasis cards.

import type { HTMLAttributes } from 'react';
import clsx from 'clsx';

/** GlassCardProps extends a div with an optional accent glow. */
export type GlassCardProps = HTMLAttributes<HTMLDivElement> & { glow?: boolean };

/** GlassCard renders a blurred translucent panel, optionally with a violet glow. */
export function GlassCard({ glow, className, ...rest }: GlassCardProps) {
  return (
    <div
      className={clsx(
        'glass rounded-2xl p-6',
        glow && 'shadow-glow ring-1 ring-accent/20',
        className,
      )}
      {...rest}
    />
  );
}
