/**
 * ShellModal - Floating, draggable, resizable shell
 */

import { Shell } from './Shell';
import { useDraggable } from './useDraggable';
import { useResizable } from './useResizable';
import './Shell.css';

interface Props {
  isOpen: boolean;
  onClose: () => void;
}

export function ShellModal({ isOpen, onClose }: Readonly<Props>) {
  const drag = useDraggable({ x: globalThis.innerWidth / 2 - 350, y: 80 });
  const resize = useResizable({ width: 700, height: 420 });

  if (!isOpen) return null;

  const style: React.CSSProperties = {
    position: 'fixed',
    left: drag.position.x,
    top: drag.position.y,
    width: resize.size.width,
    zIndex: 1002,
  };

  return (
    <div className="shell-backdrop">
      <Shell
        onClose={onClose}
        style={style}
        onHeaderMouseDown={drag.onMouseDown}
        onResizeStart={resize.onResizeStart}
      />
      <style>{`.shell-body { height: ${resize.size.height}px !important; }`}</style>
    </div>
  );
}
