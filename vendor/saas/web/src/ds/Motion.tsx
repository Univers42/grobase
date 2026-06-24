// Motion.tsx — entrance animation on scroll via IntersectionObserver. Adds the
// `in` class when the element enters the viewport; honors prefers-reduced-motion
// (the CSS disables the transition, so it just appears).

import { useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import clsx from 'clsx';

/** MotionProps wraps children that fade/rise in on first view. */
export type MotionProps = { children: ReactNode; delay?: number; className?: string };

/** Motion reveals its children once when they scroll into view. */
export function Motion({ children, delay = 0, className }: MotionProps) {
  const ref = useRef<HTMLDivElement>(null);
  const [shown, setShown] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el || shown) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          setShown(true);
          io.disconnect();
        }
      },
      { threshold: 0.12 },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [shown]);

  return (
    <div ref={ref} style={{ transitionDelay: `${delay}ms` }} className={clsx('entrance', shown && 'in', className)}>
      {children}
    </div>
  );
}
