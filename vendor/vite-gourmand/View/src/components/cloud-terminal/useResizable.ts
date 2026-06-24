/**
 * useResizable - Hook for resizable elements
 */

import { useState, useCallback, useEffect } from 'react';

interface Size {
  width: number;
  height: number;
}

const DEFAULT_SIZE: Size = { width: 700, height: 400 };

export function useResizable(initialSize: Size = DEFAULT_SIZE) {
  const [size, setSize] = useState(initialSize);
  const [isResizing, setIsResizing] = useState(false);

  const onResizeStart = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setIsResizing(true);
  }, []);

  useEffect(() => {
    if (!isResizing) return;

    const startSize = { ...size };
    const startPos = { x: 0, y: 0 };

    const onMove = (e: MouseEvent) => {
      if (startPos.x === 0) {
        startPos.x = e.clientX;
        startPos.y = e.clientY;
        return;
      }
      setSize({
        width: Math.max(400, startSize.width + (e.clientX - startPos.x)),
        height: Math.max(200, startSize.height + (e.clientY - startPos.y)),
      });
    };

    const onUp = () => setIsResizing(false);

    globalThis.addEventListener('mousemove', onMove);
    globalThis.addEventListener('mouseup', onUp);
    return () => {
      globalThis.removeEventListener('mousemove', onMove);
      globalThis.removeEventListener('mouseup', onUp);
    };
  }, [isResizing, size]);

  return { size, isResizing, onResizeStart };
}
