/**
 * BaseCard - Foundation card component
 * Used as the base for all card variants
 */

import type { CardBaseProps } from './types';
import './BaseCard.css';

export function BaseCard({
  children,
  variant = 'default',
  padding = 'md',
  onClick,
  className = '',
}: Readonly<CardBaseProps>) {
  const cardClasses = buildCardClasses(variant, padding, onClick, className);
  const Tag = onClick ? 'button' : 'div';

  return (
    <Tag className={cardClasses} onClick={onClick} type={onClick ? 'button' : undefined}>
      {children}
    </Tag>
  );
}

function buildCardClasses(
  variant: string,
  padding: string,
  onClick: (() => void) | undefined,
  className: string,
): string {
  const classes = ['base-card', `base-card-${variant}`, `base-card-padding-${padding}`];
  if (onClick) classes.push('base-card-clickable');
  if (className) classes.push(className);
  return classes.join(' ');
}
