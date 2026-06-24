/**
 * ShellFab - Floating action button
 */

import './Shell.css';

interface Props {
  onClick: () => void;
}

export function ShellFab({ onClick }: Readonly<Props>) {
  return (
    <button className="shell-fab" onClick={onClick} title="Terminal (Ctrl+`)">
      <span>⌨️</span>
    </button>
  );
}
