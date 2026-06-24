// Spinner.tsx — a minimal accessible loading indicator (CSS ring, no icon dep).

import clsx from 'clsx';

/** SpinnerProps sizes the spinner and labels it for screen readers. */
export type SpinnerProps = { size?: number; className?: string; label?: string };

/** Spinner renders a spinning ring with an accessible status label. */
export function Spinner({ size = 20, className, label = 'Loading' }: SpinnerProps) {
  return (
    <span
      role="status"
      aria-label={label}
      style={{ width: size, height: size }}
      className={clsx('inline-block rounded-full border-2 border-white/15 border-t-accent animate-spin', className)}
    />
  );
}
