// ── HERO PARALLAX — CSP-safe scroll progress for the cinematic visual.
//
// The visual already drifts via the pure-CSS .parallax helper (animation-timeline:
// view()) in _premium.scss, which is the primary mechanism and works with zero JS.
// This module is a PROGRESSIVE ENHANCEMENT for browsers without scroll-driven
// animation support: it sets a single CSS custom property `--p` (0→1, scroll
// progress of the hero through the viewport) on the frame element so the SCSS can
// translate the visual. It NEVER writes an inline style attribute in markup and
// NEVER touches innerHTML — it only calls element.style.setProperty, which strict
// CSP permits. The whole thing is gated behind prefers-reduced-motion AND behind a
// feature check so we don't double-drive the CSS-native path.
//
// LH-safe: one passive scroll listener, rAF-throttled, a single setProperty per
// frame, and it bails entirely under reduced-motion or when the element is absent.

const REDUCED = window.matchMedia('(prefers-reduced-motion: reduce)');

// If the browser supports CSS scroll-driven animation, the .parallax keyframes
// already do the drift — adding JS on top would fight it. Let CSS own it.
const CSS_NATIVE =
	typeof CSS !== 'undefined' &&
	typeof CSS.supports === 'function' &&
	CSS.supports('animation-timeline: view()');

function initHeroParallax(): void {
	if (REDUCED.matches || CSS_NATIVE) return;

	const frame = document.querySelector<HTMLElement>('[data-hero-parallax]');
	if (!frame) return;

	let ticking = false;

	const update = (): void => {
		ticking = false;
		const rect = frame.getBoundingClientRect();
		const vh = window.innerHeight || document.documentElement.clientHeight;
		// progress 0 when the frame top is at the bottom of the viewport,
		// 1 when its bottom has reached the top — clamped to [0,1].
		const span = rect.height + vh;
		const raw = (vh - rect.top) / span;
		const p = Math.min(1, Math.max(0, raw));
		// CSSOM write only — allowed under strict CSP (no inline style= attribute).
		frame.style.setProperty('--p', p.toFixed(4));
	};

	const onScroll = (): void => {
		if (ticking) return;
		ticking = true;
		requestAnimationFrame(update);
	};

	window.addEventListener('scroll', onScroll, { passive: true });
	window.addEventListener('resize', onScroll, { passive: true });
	update();
}

if (document.readyState === 'loading') {
	document.addEventListener('DOMContentLoaded', initHeroParallax, { once: true });
} else {
	initHeroParallax();
}
