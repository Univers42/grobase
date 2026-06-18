/**
 * BurgerIcon - Animated burger/close SVG icon
 */

import './BurgerIcon.css';

interface BurgerIconProps {
  isOpen: boolean;
  onClick: () => void;
  className?: string;
}

export function BurgerIcon({ isOpen, onClick, className = '' }: Readonly<BurgerIconProps>) {
  return (
    <button
      type="button"
      className={`burger-icon ${isOpen ? 'burger-icon--open' : ''} ${className}`}
      onClick={onClick}
      aria-label={isOpen ? 'Close menu' : 'Open menu'}
      aria-expanded={isOpen}
    >
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
        <line className="burger-line burger-line--top" x1="3" y1="6" x2="21" y2="6" />
        <line className="burger-line burger-line--middle" x1="3" y1="12" x2="21" y2="12" />
        <line className="burger-line burger-line--bottom" x1="3" y1="18" x2="21" y2="18" />
      </svg>
    </button>
  );
}
