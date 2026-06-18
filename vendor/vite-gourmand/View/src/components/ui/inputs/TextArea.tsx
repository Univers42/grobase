/**
 * TextArea - Multi-line text input field
 * Used for longer text entries like notes, descriptions
 */

import type { InputBaseProps } from './types';
import './TextArea.css';

interface TextAreaProps extends InputBaseProps {
  value: string;
  onChange: (value: string) => void;
  rows?: number;
  maxLength?: number;
}

export function TextArea({
  id,
  name,
  label,
  placeholder,
  value,
  onChange,
  rows = 4,
  maxLength,
  disabled = false,
  required = false,
  error,
}: Readonly<TextAreaProps>) {
  const textareaClasses = buildTextAreaClasses(error);

  return (
    <div className="textarea-wrapper">
      {label && <TextAreaLabel htmlFor={id} required={required} label={label} />}
      <textarea
        id={id}
        name={name}
        className={textareaClasses}
        placeholder={placeholder}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        rows={rows}
        maxLength={maxLength}
        disabled={disabled}
        required={required}
        aria-invalid={!!error}
      />
      <TextAreaFooter value={value} maxLength={maxLength} error={error} id={id} />
    </div>
  );
}

function buildTextAreaClasses(error?: string): string {
  const classes = ['textarea'];
  if (error) classes.push('textarea-error');
  return classes.join(' ');
}

function TextAreaLabel({
  htmlFor,
  required,
  label,
}: Readonly<{
  htmlFor: string;
  required: boolean;
  label: string;
}>) {
  return (
    <label htmlFor={htmlFor} className="textarea-label">
      {label}
      {required && <span className="textarea-required">*</span>}
    </label>
  );
}

function TextAreaFooter({
  value,
  maxLength,
  error,
  id,
}: Readonly<{
  value: string;
  maxLength?: number;
  error?: string;
  id: string;
}>) {
  return (
    <div className="textarea-footer">
      {error && (
        <span id={`${id}-error`} className="textarea-error-msg" role="alert">
          {error}
        </span>
      )}
      {maxLength && (
        <span className="textarea-count">
          {value.length}/{maxLength}
        </span>
      )}
    </div>
  );
}
