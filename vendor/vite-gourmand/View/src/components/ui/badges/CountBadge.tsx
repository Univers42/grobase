/**
 * CountBadge - Displays numeric counts
 * Used for showing number of tests, errors, etc.
 */

import './CountBadge.css';

export type CountVariant = 'default' | 'success' | 'danger' | 'warning';

interface CountBadgeProps {
  count: number;
  variant?: CountVariant;
  max?: number;
}

export function CountBadge({ count, variant = 'default', max = 99 }: Readonly<CountBadgeProps>) {
  const displayValue = formatCount(count, max);
  const classes = buildClasses(variant);

  return (
    <span className={classes} aria-label={`${count} items`}>
      {displayValue}
    </span>
  );
}

function formatCount(count: number, max: number): string {
  return count > max ? `${max}+` : count.toString();
}

function buildClasses(variant: CountVariant): string {
  return ['count-badge', `count-badge-${variant}`].join(' ');
}
