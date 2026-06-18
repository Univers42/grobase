// LandingPage.tsx — the public front door. Composes the aurora hero and feature
// grid into a single dark, premium marketing page with a minimal header/footer.

import { Link } from 'react-router-dom';
import { Hero } from './Hero';
import { FeatureGrid } from './FeatureGrid';
import { Icon } from '../../ds/Icon';
import { buttonClass } from '../../ds/Button';

/** LandingPage renders the unauthenticated marketing surface. */
export function LandingPage() {
  return (
    <div className="relative min-h-screen">
      <header className="mx-auto flex max-w-6xl items-center justify-between px-6 py-5">
        <span className="flex items-center gap-2.5">
          <span className="grid size-8 place-items-center rounded-lg bg-gradient-to-br from-accent to-cyan text-accent-fg">
            <Icon name="zap" size={16} />
          </span>
          <span className="text-lg font-semibold tracking-tight text-ink">Nimbus</span>
        </span>
        <Link to="/login" className={buttonClass('secondary', 'sm')}>
          Sign in
        </Link>
      </header>
      <Hero />
      <FeatureGrid />
      <footer className="border-t border-line px-6 py-8 text-center text-sm text-muted">
        Nimbus · a Grobase admin console · built dark, built fast.
      </footer>
    </div>
  );
}
