// ── ENTERPRISE WORD-REVEAL — CSP-safe scroll-driven manifesto reveal.
//
// Drives a per-word `--p` in [0..1] on the .reveal-words__w spans as the
// manifesto scrolls through the viewport, so the statement re-illuminates
// word-by-word. STRICT CSP discipline:
//   • the ONLY DOM mutation is element.style.setProperty / setAttribute —
//     never innerHTML / insertAdjacentHTML / document.write / new Function;
//   • no inline handlers, no external resources.
//
// Graceful + accessible by default:
//   • no JS, or the .reveal-words default (--p:1) → words are fully lit;
//   • prefers-reduced-motion → we leave the words lit and never start;
//   • IntersectionObserver/scroll unsupported → words stay lit.
// The dark→reveal effect only happens once we set [data-reveal] AND drive --p.

const WORD_SEL = '.reveal-words__w';

function clamp01(n: number): number {
	return n < 0 ? 0 : n > 1 ? 1 : n;
}

// Map the container's vertical progress through the viewport to a [0..1] value,
// then light words progressively: earlier words reach full --p sooner.
function drive(container: HTMLElement, words: HTMLElement[]): void {
	const rect = container.getBoundingClientRect();
	const vh = window.innerHeight || document.documentElement.clientHeight;
	// progress 0 when the block's top is one viewport below the fold,
	// 1 when its top has risen to ~30% of the viewport height.
	const start = vh;
	const end = vh * 0.3;
	const raw = (start - rect.top) / (start - end);
	const progress = clamp01(raw);

	const n = words.length;
	for (let i = 0; i < n; i++) {
		// each word gets its own ramp window across the overall progress
		const wStart = i / (n + 2);
		const wEnd = (i + 3) / (n + 2);
		const p = clamp01((progress - wStart) / (wEnd - wStart));
		words[i].style.setProperty('--p', p.toFixed(3));
	}
}

export function initReveal(): void {
	const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
	if (reduce) return; // leave the words lit; never start the effect

	const container = document.querySelector<HTMLElement>('[data-reveal-target]');
	if (!container) return;
	const words = Array.from(container.querySelectorAll<HTMLElement>(WORD_SEL));
	if (words.length === 0) return;

	// opt into the dark baseline only now that JS + motion are confirmed
	container.setAttribute('data-reveal', '');

	let ticking = false;
	const onScroll = (): void => {
		if (ticking) return;
		ticking = true;
		window.requestAnimationFrame(() => {
			drive(container, words);
			ticking = false;
		});
	};

	// only run while the block is near the viewport (cheap when off-screen)
	if ('IntersectionObserver' in window) {
		const io = new IntersectionObserver((entries) => {
			for (const e of entries) {
				if (e.isIntersecting) {
					window.addEventListener('scroll', onScroll, { passive: true });
					onScroll();
				} else {
					window.removeEventListener('scroll', onScroll);
				}
			}
		}, { rootMargin: '0px 0px -10% 0px' });
		io.observe(container);
	} else {
		window.addEventListener('scroll', onScroll, { passive: true });
	}
	onScroll();
}
