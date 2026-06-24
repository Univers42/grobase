/**
 * Select - Dropdown selection input
 * Used for choosing from predefined options
 */

import type { InputBaseProps } from './types';
import './Select.css';

interface SelectOption {
  value: string;
  label: string;
}

interface SelectProps extends InputBaseProps {
  value: string;
  onChange: (value: string) => void;
  options: SelectOption[];
}

export function Select({
  id,
  name,
  label,
  value,
  onChange,
  options,
  placeholder,
  disabled = false,
  required = false,
  error,
  size = 'md',
}: Readonly<SelectProps>) {
  const selectClasses = buildSelectClasses(size, error);

  return (
    <div className="select-wrapper">
      {label && <SelectLabel htmlFor={id} required={required} label={label} />}
      <div className="select-container">
        <select
          id={id}
          name={name}
          className={selectClasses}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          disabled={disabled}
          required={required}
          aria-invalid={!!error}
        >
          {placeholder && <option value="">{placeholder}</option>}
          {options.map((opt) => (
            <option key={opt.value} value={opt.value}>
              {opt.label}
            </option>
          ))}
        </select>
        <ChevronIcon />
      </div>
      {error && <SelectError message={error} />}
    </div>
  );
}

function buildSelectClasses(size: string, error?: string): string {
  const classes = ['select', `select-${size}`];
  if (error) classes.push('select-error');
  return classes.join(' ');
}

function SelectLabel({
  htmlFor,
  required,
  label,
}: Readonly<{
  htmlFor: string;
  required: boolean;
  label: string;
}>) {
  return (
    <label htmlFor={htmlFor} className="select-label">
      {label}
      {required && <span className="select-required">*</span>}
    </label>
  );
}

function SelectError({ message }: Readonly<{ message: string }>) {
  return (
    <span className="select-error-msg" role="alert">
      {message}
    </span>
  );
}

function ChevronIcon() {
  return (
    <svg className="select-chevron" viewBox="0 0 20 20" fill="currentColor">
      <path
        fillRule="evenodd"
        d="M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z"
        clipRule="evenodd"
      />
    </svg>
  );
}
