// ── MEGA-MENU controller — CSP-safe header interactivity.
//
// Drives the Solutions / Resources mega-menu panels and the mobile drawer.
// STRICT CSP discipline:
//   • toggles CLASSES + ATTRIBUTES + ARIA only — never innerHTML / insertAdjacentHTML.
//   • the only "style" it ever writes is element.style.setProperty (allowed), and even
//     that is unused here — all visuals come from classes the SCSS reacts to.
//   • no inline handlers — every listener is bound in code from a hashed Astro bundle.
//
// Behaviour:
//   • DESKTOP: each <button aria-controls> opens its panel on click; hover-intent opens
//     on pointer-enter (after a short delay) and closes on pointer-leave (after a longer
//     delay so a diagonal trip to the panel doesn't drop it). Only one panel open at once.
//   • Escape closes the open panel/drawer and returns focus to its trigger.
//   • A click outside the header closes everything.
//   • MOBILE: a hamburger toggles a drawer (body + nav class); inside it the same
//     aria-expanded buttons become accordions (independent open/close).
//
// No-JS / keyboard baseline lives in CSS (:focus-within reveals panels), so this script
// is pure enhancement — its absence never hides navigation.

const OPEN_DELAY = 90; // hover-intent: wait before opening (ignores fly-over)
const CLOSE_DELAY = 220; // grace before closing so the cursor can reach the panel

type Trigger = HTMLButtonElement;

function init(): void {
	const header = document.querySelector<HTMLElement>('[data-megamenu-root]');
	if (!header) return;

	const nav = header.querySelector<HTMLElement>('.gb-header__nav');
	const triggers = Array.from(header.querySelectorAll<Trigger>('[data-menu-trigger]'));
	const hamburger = header.querySelector<HTMLButtonElement>('[data-drawer-toggle]');

	const mql = window.matchMedia('(width <= 60rem)');
	const isMobile = () => mql.matches;

	let openTrigger: Trigger | null = null;
	let openTimer = 0;
	let closeTimer = 0;

	const panelFor = (t: Trigger): HTMLElement | null => {
		const id = t.getAttribute('aria-controls');
		return id ? header.querySelector<HTMLElement>(`#${CSS.escape(id)}`) : null;
	};

	// ── DESKTOP: single-panel open/close ──────────────────────────────────────
	const setOpen = (t: Trigger, open: boolean): void => {
		t.setAttribute('aria-expanded', open ? 'true' : 'false');
		const panel = panelFor(t);
		if (panel) panel.classList.toggle('is-open', open);
		if (open) {
			openTrigger = t;
			header.classList.add('has-open-menu');
		} else if (openTrigger === t) {
			openTrigger = null;
			header.classList.remove('has-open-menu');
		}
	};

	const closeAllDesktop = (): void => {
		for (const t of triggers) setOpen(t, false);
	};

	const clearTimers = (): void => {
		window.clearTimeout(openTimer);
		window.clearTimeout(closeTimer);
	};

	// ── MOBILE: accordions (independent) + the drawer ─────────────────────────
	const toggleAccordion = (t: Trigger): void => {
		const open = t.getAttribute('aria-expanded') !== 'true';
		t.setAttribute('aria-expanded', open ? 'true' : 'false');
		const panel = panelFor(t);
		if (panel) panel.classList.toggle('is-open', open);
	};

	const setDrawer = (open: boolean): void => {
		if (!hamburger) return;
		hamburger.setAttribute('aria-expanded', open ? 'true' : 'false');
		header.classList.toggle('is-drawer-open', open);
		document.body.classList.toggle('gb-no-scroll', open);
		if (!open) {
			// collapse every accordion when the drawer closes
			for (const t of triggers) {
				t.setAttribute('aria-expanded', 'false');
				const panel = panelFor(t);
				if (panel) panel.classList.remove('is-open');
			}
		}
	};

	// ── Wire triggers ─────────────────────────────────────────────────────────
	for (const t of triggers) {
		t.addEventListener('click', (e) => {
			e.preventDefault();
			if (isMobile()) {
				toggleAccordion(t);
				return;
			}
			const willOpen = t.getAttribute('aria-expanded') !== 'true';
			closeAllDesktop();
			if (willOpen) setOpen(t, true);
		});

		// hover-intent (desktop only — pointer events are inert on touch taps here
		// because the click handler already toggled, and we re-check isMobile()).
		t.addEventListener('pointerenter', (e) => {
			if (isMobile() || e.pointerType === 'touch') return;
			clearTimers();
			openTimer = window.setTimeout(() => {
				if (openTrigger && openTrigger !== t) closeAllDesktop();
				setOpen(t, true);
			}, OPEN_DELAY);
		});
		t.addEventListener('pointerleave', (e) => {
			if (isMobile() || e.pointerType === 'touch') return;
			scheduleClose();
		});

		// keep a panel open while the pointer is inside its trigger's panel
		const panel = panelFor(t);
		if (panel) {
			panel.addEventListener('pointerenter', () => {
				if (!isMobile()) clearTimers();
			});
			panel.addEventListener('pointerleave', () => {
				if (!isMobile()) scheduleClose();
			});
		}
	}

	function scheduleClose(): void {
		clearTimers();
		closeTimer = window.setTimeout(closeAllDesktop, CLOSE_DELAY);
	}

	// ── Hamburger ─────────────────────────────────────────────────────────────
	if (hamburger) {
		hamburger.addEventListener('click', () => {
			const open = hamburger.getAttribute('aria-expanded') !== 'true';
			setDrawer(open);
		});
	}

	// ── Global: Escape closes, click-outside closes ───────────────────────────
	document.addEventListener('keydown', (e) => {
		if (e.key !== 'Escape') return;
		if (header.classList.contains('is-drawer-open')) {
			setDrawer(false);
			hamburger?.focus();
			return;
		}
		if (openTrigger) {
			const t = openTrigger;
			closeAllDesktop();
			t.focus();
		}
	});

	document.addEventListener('pointerdown', (e) => {
		const target = e.target as Node | null;
		if (target && header.contains(target)) return;
		closeAllDesktop();
	});

	// ── Viewport change: leaving mobile collapses the drawer & resets state ────
	mql.addEventListener('change', () => {
		clearTimers();
		closeAllDesktop();
		setDrawer(false);
	});

	// keep the linter happy: nav is referenced for its presence guard only
	void nav;
}

if (document.querySelector('[data-megamenu-root]')) {
	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init, { once: true });
	} else {
		init();
	}
}
