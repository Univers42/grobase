/**
 * Button Types - Shared type definitions for all button variants
 */

export type ButtonSize = 'sm' | 'md' | 'lg';

export interface ButtonBaseProps {
  children: React.ReactNode;
  size?: ButtonSize;
  disabled?: boolean;
  loading?: boolean;
  fullWidth?: boolean;
  type?: 'button' | 'submit' | 'reset';
  onClick?: () => void;
  ariaLabel?: string;
}
