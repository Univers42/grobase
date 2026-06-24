// Button.tsx — the primary action element. Variants are composed with clsx; the
// focus-visible ring comes from the global token. No CVA dependency (minimalism).

import { forwardRef } from 'react';
import type { ButtonHTMLAttributes } from 'react';
import clsx from 'clsx';

/** ButtonVariant selects the visual treatment. */
export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger';

/** ButtonSize selects the padding/typography scale. */
export type ButtonSize = 'sm' | 'md' | 'lg';

/** ButtonProps extends a native button with variant/size/loading. */
export type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: ButtonVariant;
  size?: ButtonSize;
  loading?: boolean;
};

const base =
  'inline-flex items-center justify-center gap-2 rounded-2xl font-medium tracking-tight transition ' +
  'disabled:opacity-50 disabled:pointer-events-none select-none';

const variants: Record<ButtonVariant, string> = {
  primary: 'bg-accent text-accent-fg hover:bg-accent/90 shadow-[0_8px_30px_-12px_rgba(124,92,255,0.8)]',
  secondary: 'glass text-ink hover:bg-white/5',
  ghost: 'text-muted hover:text-ink hover:bg-white/5',
  danger: 'bg-danger/15 text-danger hover:bg-danger/25 border border-danger/30',
};

const sizes: Record<ButtonSize, string> = {
  sm: 'h-9 px-3.5 text-sm',
  md: 'h-11 px-5 text-sm',
  lg: 'h-12 px-7 text-base',
};

/** buttonClass composes the button styling for non-button elements (e.g. links). */
export function buttonClass(variant: ButtonVariant = 'primary', size: ButtonSize = 'md', extra?: string): string {
  return clsx(base, variants[variant], sizes[size], extra);
}

/** Button renders a styled, accessible action with an optional loading spinner. */
export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = 'primary', size = 'md', loading, className, children, disabled, type = 'button', ...rest },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type}
      disabled={disabled ?? loading}
      aria-busy={loading || undefined}
      className={clsx(base, variants[variant], sizes[size], className)}
      {...rest}
    >
      {loading && <span className="size-4 rounded-full border-2 border-current border-r-transparent animate-spin" aria-hidden />}
      {children}
    </button>
  );
});
