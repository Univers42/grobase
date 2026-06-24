/**
 * ShellInput - Command input with Enter to execute
 */

import { useRef, useEffect } from 'react';

interface Props {
  value: string;
  prompt: string;
  loading: boolean;
  onChange: (v: string) => void;
  onSubmit: () => void;
  onNavigate: (dir: 'up' | 'down') => void;
}

export function ShellInput({ value, prompt, loading, onChange, onSubmit, onNavigate }: Readonly<Props>) {
  const ref = useRef<HTMLInputElement>(null);

  useEffect(() => {
    ref.current?.focus();
  }, [loading]);

  const handleKey = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !loading) {
      e.preventDefault();
      onSubmit();
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      onNavigate('up');
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      onNavigate('down');
    }
  };

  return (
    <div className="shell-input">
      <span className="shell-prompt">{prompt} $</span>
      <input
        ref={ref}
        type="text"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={handleKey}
        disabled={loading}
        autoFocus
        spellCheck={false}
        autoComplete="off"
      />
      {loading && <span className="shell-loading">⏳</span>}
    </div>
  );
}
