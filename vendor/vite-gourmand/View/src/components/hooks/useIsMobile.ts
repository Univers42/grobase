/**
 * useIsMobile - Hook to detect mobile viewport
 */

import { useState, useEffect } from 'react';

const MOBILE_BREAKPOINT = 768;

export function useIsMobile(breakpoint = MOBILE_BREAKPOINT): boolean {
  const [isMobile, setIsMobile] = useState(
    () => globalThis.window !== undefined && globalThis.innerWidth <= breakpoint,
  );

  useEffect(() => {
    const checkMobile = () => setIsMobile(globalThis.innerWidth <= breakpoint);
    const media = globalThis.matchMedia(`(max-width: ${breakpoint}px)`);

    media.addEventListener('change', checkMobile);
    return () => media.removeEventListener('change', checkMobile);
  }, [breakpoint]);

  return isMobile;
}
