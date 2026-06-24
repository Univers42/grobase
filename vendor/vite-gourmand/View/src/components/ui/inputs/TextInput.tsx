/**
 * TextInput - Single-line text input field
 * Used for short text entries like names, emails
 */

import type { InputBaseProps } from './types';
import './TextInput.css';

interface TextInputProps extends InputBaseProps {
  value: string;
  onChange: (value: string) => void;
  type?: 'text' | 'email' | 'password' | 'search';
}

export function TextInput({
  id,
  name,
  label,
  placeholder,
  value,
  onChange,
  type = 'text',
  disabled = false,
  required = false,
  error,
  size = 'md',
}: Readonly<TextInputProps>) {
  const inputClasses = buildInputClasses(size, error);

  return (
    <div className="input-wrapper">
      {label && <InputLabel htmlFor={id} required={required} label={label} />}
      <input
        id={id}
        name={name}
        type={type}
        className={inputClasses}
        placeholder={placeholder}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        disabled={disabled}
        required={required}
        aria-invalid={!!error}
        aria-describedby={error ? `${id}-error` : undefined}
      />
      {error && <InputError id={`${id}-error`} message={error} />}
    </div>
  );
}

function buildInputClasses(size: string, error?: string): string {
  const classes = ['text-input', `text-input-${size}`];
  if (error) classes.push('text-input-error');
  return classes.join(' ');
}

function InputLabel({
  htmlFor,
  required,
  label,
}: Readonly<{
  htmlFor: string;
  required: boolean;
  label: string;
}>) {
  return (
    <label htmlFor={htmlFor} className="input-label">
      {label}
      {required && <span className="input-required">*</span>}
    </label>
  );
}

function InputError({ id, message }: Readonly<{ id: string; message: string }>) {
  return (
    <span id={id} className="input-error" role="alert">
      {message}
    </span>
  );
}
