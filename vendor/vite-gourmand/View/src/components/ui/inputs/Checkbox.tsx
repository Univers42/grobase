/**
 * Checkbox - Toggle boolean input
 * Used for boolean selections like "Mark as complete"
 */

import './Checkbox.css';

interface CheckboxProps {
  id: string;
  name: string;
  label: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
  disabled?: boolean;
}

export function Checkbox({ id, name, label, checked, onChange, disabled = false }: Readonly<CheckboxProps>) {
  return (
    <label className="checkbox-wrapper" htmlFor={id}>
      <input
        id={id}
        name={name}
        type="checkbox"
        className="checkbox-input"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        disabled={disabled}
      />
      <span className="checkbox-box" aria-hidden="true">
        {checked && <CheckIcon />}
      </span>
      <span className="checkbox-label">{label}</span>
    </label>
  );
}

function CheckIcon() {
  return (
    <svg className="checkbox-icon" viewBox="0 0 12 12" fill="none">
      <path
        d="M2 6L5 9L10 3"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
