// ── Hero scene animator — cross-browser (Firefox-safe) SVG motion.
//
// Firefox renders CSS `transform` animations on SVG elements (with
// `transform-box: fill-box` + `transform-origin`) inconsistently, so the leg /
// hills / shooting-star sat frozen there. SMIL is blocked by the icon-safety
// gate. The robust answer: drive the transforms from JS in a requestAnimationFrame
// loop via setAttribute — plain DOM writes that behave identically in every
// engine. CSP-safe (no innerHTML / eval, attribute writes only). Star twinkle
// stays a CSS opacity animation (cross-browser fine). Respects reduced-motion:
// when the user prefers reduced motion we leave the scene as a calm static night.

const KX = 30; // knee pivot X in the leg's local coords (matches path M30 -6)
const KY = -6; // knee pivot Y
const TWO_PI = Math.PI * 2;

function init(): void {
	const leg = document.querySelector<SVGGElement>('.gb-scene__leg');
	if (!leg) return; // no scene on this page

	const hillBack = document.querySelector<SVGPathElement>('.gb-scene__hill--back');
	const hillMid = document.querySelector<SVGPathElement>('.gb-scene__hill--mid');
	const shoot = document.querySelector<SVGGElement>('.gb-scene__shoot');
	const moonRim = document.querySelector<SVGGElement>('.gb-scene__moon-rim');
	const fog = document.querySelector<SVGGElement>('.gb-scene__fog');
	const starField = document.querySelector<SVGGElement>('.gb-scene__stars');

	// pixel-art life
	const cars = Array.from(document.querySelectorAll<SVGGElement>('.gb-scene__car'));
	const personW = document.querySelector<SVGGElement>('.gb-scene__person');
	const mouseW = document.querySelector<SVGGElement>('.gb-scene__mouse');
	const personF = personW ? Array.from(personW.querySelectorAll<SVGGElement>('.px-frame')) : [];
	const mouseF = mouseW ? Array.from(mouseW.querySelectorAll<SVGGElement>('.px-frame')) : [];

	// a sprite that paces back and forth, flips to face its direction, and swaps
	// its two walk frames (legs) on a timer.
	function walk(
		el: SVGGElement | null,
		fr: SVGGElement[],
		min: number,
		max: number,
		y: number,
		speed: number,
		width: number,
		swap: number,
		s: number,
	): void {
		if (!el) return;
		const span = max - min;
		const period = (span / speed) * 2;
		const u = (s % period) / period;
		let x: number;
		let dir: number;
		if (u < 0.5) {
			x = min + span * (u * 2);
			dir = 1;
		} else {
			x = max - span * ((u - 0.5) * 2);
			dir = -1;
		}
		el.setAttribute('transform', dir > 0 ? `translate(${x.toFixed(1)} ${y})` : `translate(${(x + width).toFixed(1)} ${y}) scale(-1 1)`);
		if (fr.length === 2) {
			const i = Math.floor(s / swap) % 2;
			fr[i].setAttribute('display', 'inline');
			fr[1 - i].setAttribute('display', 'none');
		}
	}

	const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');

	// A pleasant resting frame for reduced-motion (and the no-JS default already
	// renders the scene at rest, so this just confirms it).
	function rest(): void {
		leg!.setAttribute('transform', `rotate(6 ${KX} ${KY})`);
		if (shoot) shoot.setAttribute('opacity', '0');
	}

	let raf = 0;
	function frame(t: number): void {
		const s = t / 1000;

		// leg swing: a gentle pendulum, −13°..+24°, ~2.3s period, pivot at the knee
		const a = 5.5 + 18.5 * Math.sin(s * (TWO_PI / 2.3));
		leg!.setAttribute('transform', `rotate(${a.toFixed(2)} ${KX} ${KY})`);

		// slow parallax drift of the hill layers (kept within the 40px overscan)
		if (hillBack) hillBack.setAttribute('transform', `translate(${(Math.sin(s / 6) * -12).toFixed(1)} 0)`);
		if (hillMid) hillMid.setAttribute('transform', `translate(${(Math.sin(s / 8 + 1) * 9).toFixed(1)} 0)`);

		// the neon moon rim breathes
		if (moonRim) moonRim.setAttribute('opacity', (0.55 + 0.35 * Math.sin(s * 0.9)).toFixed(2));

		// fog wisps drift slowly across the hills
		if (fog) fog.setAttribute('transform', `translate(${(Math.sin(s / 11) * 26).toFixed(1)} 0)`);

		// the whole star field turns slowly around a celestial pole (~4 min/rev),
		// like the night sky revolving — stars near the pole barely move, outer
		// ones trace long arcs.
		if (starField) starField.setAttribute('transform', `rotate(${(s * 1.4).toFixed(2)} 1180 70)`);

		// traffic: cars cruise the street rightward and loop
		for (let i = 0; i < cars.length; i++) {
			const y = i % 2 ? 752 : 748;
			const speed = 70 + i * 24;
			const x = (((i * 380) + speed * s) % 1620) - 80;
			cars[i].setAttribute('transform', `translate(${x.toFixed(1)} ${y})`);
		}

		// a person strolls, a mouse scurries — both pace, flip + swap legs
		walk(personW, personF, 150, 880, 724, 46, 28, 0.3, s);
		walk(mouseW, mouseF, 90, 1300, 747, 150, 30, 0.13, s);

		// a shooting star streaks across every ~9s
		if (shoot) {
			const c = (s % 9) / 9;
			if (c < 0.14) {
				const k = c / 0.14;
				shoot.setAttribute('transform', `translate(${(k * 260).toFixed(0)} ${(k * 140).toFixed(0)})`);
				shoot.setAttribute('opacity', (k < 0.2 ? (k * 4.5).toFixed(2) : (1 - k).toFixed(2)));
			} else {
				shoot.setAttribute('opacity', '0');
			}
		}

		raf = window.requestAnimationFrame(frame);
	}

	function start(): void {
		if (reduce.matches) {
			window.cancelAnimationFrame(raf);
			raf = 0;
			rest();
		} else if (!raf) {
			raf = window.requestAnimationFrame(frame);
		}
	}

	start();
	// react live if the user toggles the OS reduced-motion setting
	reduce.addEventListener?.('change', start);
}

if (document.readyState !== 'loading') init();
else document.addEventListener('DOMContentLoaded', init);
