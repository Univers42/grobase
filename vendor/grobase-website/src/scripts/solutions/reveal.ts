// ── Solutions word-reveal — CSP-safe progressive manifesto illumination.
//
// The manifesto words start dark (CSS sets --p:0 only when [data-reveal] is
// present AND motion is allowed) and are re-illuminated one by one as the block
// scrolls through the viewport. This module ONLY:
//   • toggles classes / data-attributes, and
//   • sets a numeric CSS custom property (--p in [0..1]) per word via
//     element.style.setProperty — which strict CSP permits.
// It NEVER touches innerHTML / insertAdjacentHTML / inline style strings / eval.
//
// No-JS or reduced-motion → this never runs (or never sets [data-reveal]), so
// the words stay at their default --p:1 (fully white, AAA). The effect is pure
// progressive enhancement.

// `export {}` makes this an ES module (not an ambient global script), so the
// type checker treats it as isolated — no duplicate-declaration across the
// component <script src> reference.
export {};

const REDUCED = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

function clamp01(n: number): number {
	if (n < 0) return 0;
	if (n > 1) return 1;
	return n;
}

// Drive each word's --p from the container's progress through the viewport:
// p ramps 0→1 across the lower-middle band of the scroll, staggered per word so
// they light left-to-right.
function driveReveal(container: HTMLElement, words: HTMLElement[]): void {
	const rect = container.getBoundingClientRect();
	const vh = window.innerHeight || document.documentElement.clientHeight;
	// 0 when the block's top is at the bottom of the viewport, 1 once it has
	// risen to ~35% from the top — a calm, readable band.
	const raw = (vh - rect.top) / (vh * 0.85);
	const progress = clamp01(raw);
	const n = words.length;
	for (let i = 0; i < n; i += 1) {
		// each word gets its own window so the reveal sweeps across the line
		const start = (i / n) * 0.6;
		const local = clamp01((progress - start) / 0.4);
		words[i].style.setProperty('--p', local.toFixed(3));
	}
}

function init(): void {
	const container = document.querySelector<HTMLElement>('[data-reveal-words]');
	if (!container) return;
	const words = Array.from(container.querySelectorAll<HTMLElement>('.reveal-words__w'));
	if (words.length === 0) return;

	// reduced-motion: leave the default lit state untouched, do nothing.
	if (REDUCED) return;

	// opt into the dark baseline (CSS: [data-reveal] .reveal-words__w { --p:0 }).
	container.setAttribute('data-reveal', '');

	let ticking = false;
	const onScroll = () => {
		if (ticking) return;
		ticking = true;
		window.requestAnimationFrame(() => {
			driveReveal(container, words);
			ticking = false;
		});
	};

	// Only attach the scroll listener while the block is near the viewport, to
	// keep the main thread quiet (LH-friendly). An IntersectionObserver gates it.
	const io = new IntersectionObserver(
		(entries) => {
			for (const e of entries) {
				if (e.isIntersecting) {
					window.addEventListener('scroll', onScroll, { passive: true });
					driveReveal(container, words);
				} else {
					window.removeEventListener('scroll', onScroll);
				}
			}
		},
		{ rootMargin: '0px 0px -10% 0px' },
	);
	io.observe(container);

	// initial paint
	driveReveal(container, words);
}

if (document.readyState === 'loading') {
	document.addEventListener('DOMContentLoaded', init, { once: true });
} else {
	init();
}
