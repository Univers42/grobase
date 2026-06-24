/**
 * Card Types - Shared type definitions for all card variants
 */

export type CardVariant = 'default' | 'elevated' | 'outlined';

export interface CardBaseProps {
  children: React.ReactNode;
  variant?: CardVariant;
  padding?: 'sm' | 'md' | 'lg';
  onClick?: () => void;
  className?: string;
}
