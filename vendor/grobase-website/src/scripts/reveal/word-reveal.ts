// Word-reveal — CSP-safe scroll-driven manifesto reveal.
//
// As a `.reveal-words` container scrolls through the viewport, each
// `.reveal-words__w` word lights up in a left-to-right wave. We never touch
// innerHTML, never write an inline style="" attribute in markup, and never
// attach an inline handler: the ONLY mutation is `element.style.setProperty`
// (CSSOM, permitted under strict CSP) for a per-word `--p` in [0..1], plus a
// single `data-reveal` attribute that opts the container into the dark
// baseline. The CSS in _premium.scss / _testimonial.scss does the painting.
//
// DEFAULT IS READABLE. With no JS, or under prefers-reduced-motion, this module
// never runs (or returns early), so `--p` stays at its CSS default of 1 and the
// manifesto renders at full white. The dark-then-illuminate effect is purely an
// enhancement that requires both JS and motion-allowed.

// How far the lit "wavefront" leads/extends past the raw scroll progress. A
// word is fully lit a little before the front reaches it and fades in over this
// span, so the sweep reads as a soft gradient rather than a hard on/off line.
const FEATHER = 0.18;

// Map raw container progress (0 = container bottom hits viewport bottom,
// 1 = container top hits viewport top) onto a comfortable reveal window so the
// words finish lighting up while the statement is still well inside the frame.
const START = 0.05;
const END = 0.7;

function clamp01(n: number): number {
	if (n < 0) return 0;
	if (n > 1) return 1;
	return n;
}

// Progress of a single word given the overall sweep position. `frac` is the
// word's normalised index in [0..1]; `front` is the current wavefront in [0..1].
function wordProgress(frac: number, front: number): number {
	return clamp01((front - frac) / FEATHER + 1);
}

function setup(root: HTMLElement): void {
	const words = Array.from(
		root.querySelectorAll<HTMLElement>('.reveal-words__w'),
	);
	if (words.length === 0) return;

	const count = words.length;
	// Opt the container into the dark baseline only now that JS is driving it;
	// without this attribute (no-JS) CSS keeps every word fully lit.
	root.setAttribute('data-reveal', '');

	let ticking = false;

	const paint = (): void => {
		ticking = false;
		const rect = root.getBoundingClientRect();
		const vh = window.innerHeight || document.documentElement.clientHeight;
		// raw: 0 when the top of the block is at the viewport bottom, 1 when the
		// bottom of the block has reached the viewport top.
		const total = rect.height + vh;
		const raw = clamp01((vh - rect.top) / total);
		// remap into the [START, END] reveal window, then push the wavefront a
		// little past 1 so the last word can reach full brightness.
		const mapped = clamp01((raw - START) / (END - START));
		const front = mapped * (1 + FEATHER);

		for (let i = 0; i < count; i += 1) {
			const frac = count === 1 ? 1 : i / (count - 1);
			const p = wordProgress(frac, front);
			words[i].style.setProperty('--p', p.toFixed(3));
		}
	};

	const onScroll = (): void => {
		if (ticking) return;
		ticking = true;
		window.requestAnimationFrame(paint);
	};

	// Only animate while the block is anywhere near the viewport — otherwise
	// detach the scroll listener so idle scrolling stays cheap.
	let attached = false;
	const attach = (): void => {
		if (attached) return;
		attached = true;
		window.addEventListener('scroll', onScroll, { passive: true });
		window.addEventListener('resize', onScroll, { passive: true });
		paint();
	};
	const detach = (): void => {
		if (!attached) return;
		attached = false;
		window.removeEventListener('scroll', onScroll);
		window.removeEventListener('resize', onScroll);
	};

	if ('IntersectionObserver' in window) {
		const io = new IntersectionObserver(
			(entries) => {
				for (const entry of entries) {
					if (entry.isIntersecting) attach();
					else detach();
				}
			},
			{ rootMargin: '20% 0px 20% 0px' },
		);
		io.observe(root);
	} else {
		// No IO: just wire the scroll listener directly.
		attach();
	}

	// Paint once at start so the initial above-the-fold state is correct.
	paint();
}

function init(): void {
	// Reduced motion → leave the markup at its readable default; do nothing.
	if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
	const roots = document.querySelectorAll<HTMLElement>('.reveal-words');
	roots.forEach((root) => setup(root));
}

if (document.querySelector('.reveal-words')) {
	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init, { once: true });
	} else {
		init();
	}
}
