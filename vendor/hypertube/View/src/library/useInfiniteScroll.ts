import { useEffect, useRef } from 'react';

/** useInfiniteScroll observes a sentinel element and invokes onReach when it
 *  scrolls into view (only while `enabled`). Returns the sentinel ref. */
export function useInfiniteScroll(onReach: () => void, enabled: boolean) {
  const sentinel = useRef<HTMLDivElement | null>(null);
  const cb = useRef(onReach);
  cb.current = onReach;

  useEffect(() => {
    const node = sentinel.current;
    if (!node || !enabled) return;
    const observer = new IntersectionObserver(
      (entries) => entries[0]?.isIntersecting && cb.current(),
      { rootMargin: '400px' },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [enabled]);

  return sentinel;
}
