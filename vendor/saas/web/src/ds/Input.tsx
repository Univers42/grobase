// Input.tsx — the dark text input. Pairs with Field for label/error wiring;
// `invalid` toggles the danger ring for inline validation.

import { forwardRef } from 'react';
import type { InputHTMLAttributes } from 'react';
import clsx from 'clsx';

/** InputProps extends a native input with an invalid flag. */
export type InputProps = InputHTMLAttributes<HTMLInputElement> & { invalid?: boolean };

const base =
  'w-full h-11 rounded-2xl bg-surface-2/70 border px-4 text-sm text-ink placeholder:text-muted/70 ' +
  'transition focus-visible:border-accent/60';

/** Input renders a styled text field; `invalid` shows the error border. */
export const Input = forwardRef<HTMLInputElement, InputProps>(function Input(
  { invalid, className, ...rest },
  ref,
) {
  return (
    <input
      ref={ref}
      aria-invalid={invalid || undefined}
      className={clsx(base, invalid ? 'border-danger/60' : 'border-line', className)}
      {...rest}
    />
  );
});
