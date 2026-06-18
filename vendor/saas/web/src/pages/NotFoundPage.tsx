// NotFoundPage.tsx — the 404 surface: a centered glass card with a route back home.

import { Link } from 'react-router-dom';
import { GlassCard } from '../ds/GlassCard';
import { buttonClass } from '../ds/Button';

/** NotFoundPage renders the dark 404 screen. */
export function NotFoundPage() {
  return (
    <div className="grid min-h-screen place-items-center px-6">
      <GlassCard className="max-w-md text-center" glow>
        <p className="display-italic text-6xl text-accent">404</p>
        <h1 className="mt-2 text-xl font-semibold tracking-tight text-ink">Page not found</h1>
        <p className="mt-2 text-sm text-muted">The page you’re after doesn’t exist or has moved.</p>
        <Link to="/" className={buttonClass('secondary', 'md', 'mt-6')}>
          Back home
        </Link>
      </GlassCard>
    </div>
  );
}
