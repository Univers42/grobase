/**
 * IconButton - Button with icon only
 * Used for compact actions like close, edit, delete
 */

import './IconButton.css';

type IconButtonVariant = 'ghost' | 'subtle' | 'danger';
type IconButtonSize = 'sm' | 'md' | 'lg';

interface IconButtonProps {
  icon: React.ReactNode;
  ariaLabel: string;
  onClick: () => void;
  variant?: IconButtonVariant;
  size?: IconButtonSize;
  disabled?: boolean;
}

export function IconButton({
  icon,
  ariaLabel,
  onClick,
  variant = 'ghost',
  size = 'md',
  disabled = false,
}: Readonly<IconButtonProps>) {
  const classes = buildClasses(variant, size);

  return (
    <button
      type="button"
      className={classes}
      onClick={onClick}
      disabled={disabled}
      aria-label={ariaLabel}
    >
      {icon}
    </button>
  );
}

function buildClasses(variant: IconButtonVariant, size: IconButtonSize): string {
  return ['icon-btn', `icon-btn-${variant}`, `icon-btn-${size}`].join(' ');
}
