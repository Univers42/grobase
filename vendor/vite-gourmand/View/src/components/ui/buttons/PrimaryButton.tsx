/**
 * PrimaryButton - Main call-to-action button
 * Used for primary actions like "Run Test", "Save", "Submit"
 */

import type { ButtonBaseProps } from './types';
import './PrimaryButton.css';

export function PrimaryButton({
  children,
  size = 'md',
  disabled = false,
  loading = false,
  fullWidth = false,
  type = 'button',
  onClick,
  ariaLabel,
}: Readonly<ButtonBaseProps>) {
  const classNames = buildClassNames(size, fullWidth, loading);

  return (
    <button
      type={type}
      className={classNames}
      disabled={disabled || loading}
      onClick={onClick}
      aria-label={ariaLabel}
      aria-busy={loading}
    >
      {loading ? <LoadingContent /> : children}
    </button>
  );
}

function buildClassNames(size: string, fullWidth: boolean, loading: boolean): string {
  const classes = ['btn', 'btn-primary', `btn-${size}`];
  if (fullWidth) classes.push('btn-full');
  if (loading) classes.push('btn-loading');
  return classes.join(' ');
}

function LoadingContent() {
  return <span className="btn-spinner" aria-hidden="true" />;
}
