// Hero.tsx — the landing hero: an aurora gradient backdrop drifting slowly behind
// a large Instrument-Serif-italic headline and the primary CTA into the console.

import { Link } from 'react-router-dom';
import { buttonClass } from '../../ds/Button';
import { Badge } from '../../ds/Badge';
import { Icon } from '../../ds/Icon';

/** Hero renders the gradient headline section and the sign-in CTA. */
export function Hero() {
  return (
    <section className="relative overflow-hidden px-6 pb-20 pt-28 text-center">
      <div className="aurora animate-drift-slow" aria-hidden />
      <div className="relative mx-auto max-w-3xl">
        <Badge tone="accent" className="mb-6">
          <Icon name="sparkles" size={13} /> The premium backend console
        </Badge>
        <h1 className="text-5xl font-semibold leading-tightest tracking-tightest text-ink sm:text-7xl">
          Your backend,
          <br />
          <span className="display-italic bg-gradient-to-r from-accent via-ink to-cyan bg-clip-text text-transparent">
            beautifully observed.
          </span>
        </h1>
        <p className="mx-auto mt-6 max-w-xl text-balance text-lg text-muted">
          Nimbus is a fast, glass-dark admin console for users, revenue, content and realtime —
          one client over your Grobase tenant, no per-project server code.
        </p>
        <div className="mt-9 flex items-center justify-center gap-3">
          <Link to="/login" className={buttonClass('primary', 'lg')}>
            Sign in <Icon name="arrowRight" size={16} />
          </Link>
          <Link to="/register" className={buttonClass('secondary', 'lg')}>
            Create account
          </Link>
        </div>
      </div>
    </section>
  );
}
