/**
 * Shell - Main terminal component (resizable & draggable)
 */

import { useShell } from './useShell';
import { ShellOutput } from './ShellOutput';
import { ShellInput } from './ShellInput';
import './Shell.css';

interface Props {
  onClose?: () => void;
  style?: React.CSSProperties;
  onHeaderMouseDown?: (e: React.MouseEvent) => void;
  onResizeStart?: (e: React.MouseEvent) => void;
}

export function Shell({ onClose, style, onHeaderMouseDown, onResizeStart }: Readonly<Props>) {
  const sh = useShell();

  return (
    <div className="shell" style={style}>
      <header className="shell-header">
        <div className="shell-dots">
          <button className="dot red" onClick={onClose} aria-label="Close terminal" type="button" />
          <button className="dot yellow" onClick={sh.clear} aria-label="Clear terminal" type="button" />
          <span className="dot green" aria-hidden="true" />
        </div>
        <button
          className="shell-title shell-drag-handle"
          onMouseDown={onHeaderMouseDown}
          type="button"
          aria-label="Move terminal"
        >
          cloud-shell — {sh.cwd}
        </button>
        <div className="shell-actions">
          <button onClick={sh.clear} title="Clear">
            ⌫
          </button>
          {onClose && (
            <button onClick={onClose} title="Close">
              ×
            </button>
          )}
        </div>
      </header>
      <div className="shell-body">
        <ShellOutput lines={sh.lines} />
        <ShellInput
          value={sh.input}
          prompt={sh.cwd}
          loading={sh.loading}
          onChange={sh.setInput}
          onSubmit={sh.run}
          onNavigate={sh.navigateHistory}
        />
      </div>
      {onResizeStart && (
        <button
          className="shell-resize-handle"
          onMouseDown={onResizeStart}
          type="button"
          aria-label="Resize terminal"
        />
      )}
    </div>
  );
}
