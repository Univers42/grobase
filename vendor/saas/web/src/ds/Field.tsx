// Field.tsx — a labeled form row that aria-wires a label, optional hint, and an
// error message to its control via a shared id, so screen readers announce them.

import { useId } from 'react';
import type { ReactNode } from 'react';

/** FieldProps describes the label/hint/error around a single control. */
export type FieldProps = {
  label: string;
  error?: string;
  hint?: string;
  children: (props: { id: string; describedBy?: string; invalid: boolean }) => ReactNode;
};

/** Field renders the label + control + error, wiring aria-describedby/invalid. */
export function Field({ label, error, hint, children }: FieldProps) {
  const id = useId();
  const hintId = `${id}-hint`;
  const errId = `${id}-err`;
  const describedBy = error ? errId : hint ? hintId : undefined;
  return (
    <div className="space-y-1.5">
      <label htmlFor={id} className="block text-xs font-medium text-muted tracking-wide">
        {label}
      </label>
      {children({ id, describedBy, invalid: Boolean(error) })}
      {hint && !error && (
        <p id={hintId} className="text-xs text-muted/80">
          {hint}
        </p>
      )}
      {error && (
        <p id={errId} role="alert" className="text-xs text-danger">
          {error}
        </p>
      )}
    </div>
  );
}
