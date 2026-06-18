// Badge.tsx — a small status pill. Tone selects the color treatment.

import type { ReactNode } from 'react';
import clsx from 'clsx';

/** BadgeTone selects the badge color. */
export type BadgeTone = 'neutral' | 'accent' | 'success' | 'warn' | 'danger';

/** BadgeProps describes the pill content and tone. */
export type BadgeProps = { tone?: BadgeTone; className?: string; children: ReactNode };

const tones: Record<BadgeTone, string> = {
  neutral: 'bg-white/5 text-muted border-line',
  accent: 'bg-accent-soft text-accent border-accent/30',
  success: 'bg-success/10 text-success border-success/30',
  warn: 'bg-warn/10 text-warn border-warn/30',
  danger: 'bg-danger/10 text-danger border-danger/30',
};

/** Badge renders a compact bordered status pill. */
export function Badge({ tone = 'neutral', className, children }: BadgeProps) {
  return (
    <span
      className={clsx(
        'inline-flex items-center gap-1 rounded-full border px-2.5 py-0.5 text-xs font-medium',
        tones[tone],
        className,
      )}
    >
      {children}
    </span>
  );
}
