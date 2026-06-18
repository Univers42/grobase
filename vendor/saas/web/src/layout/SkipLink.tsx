// SkipLink.tsx — keyboard skip-to-content link, visually hidden until focused.

/** SkipLink jumps focus to the #main landmark for keyboard users. */
export function SkipLink() {
  return (
    <a
      href="#main"
      className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[70] focus:rounded-xl focus:bg-accent focus:px-4 focus:py-2 focus:text-sm focus:text-accent-fg"
    >
      Skip to content
    </a>
  );
}
