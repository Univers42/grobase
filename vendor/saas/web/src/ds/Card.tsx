// Card.tsx — a plain surface panel (opaque, bordered, rounded). Use GlassCard when
// you want the blurred translucent treatment.

import type { HTMLAttributes } from 'react';
import clsx from 'clsx';

/** CardProps extends a div with the card surface styling. */
export type CardProps = HTMLAttributes<HTMLDivElement>;

/** Card renders an opaque rounded surface panel. */
export function Card({ className, ...rest }: CardProps) {
  return <div className={clsx('rounded-2xl border border-line bg-surface p-5', className)} {...rest} />;
}
