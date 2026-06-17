// ── DOCS TOC scroll-spy + mobile sidebar drawer — CSP-safe.
//
// No inline handlers, no innerHTML, no inline style attributes: this module is
// imported from a component <script> (Astro bundles + hashes it), and it only
// toggles classes / attributes and reads the DOM. All motion lives in CSS behind
// prefers-reduced-motion; this file just flips state.
//
// 1) Scroll-spy: an IntersectionObserver watches every heading the TOC links to
//    and marks the link for the heading currently in view with aria-current
//    ("location" — the WAI-ARIA value for "the current item within a set"). The
//    active highlight is therefore class-free CSS via [aria-current].
// 2) Mobile drawer: a single <button> toggles the left sidebar via aria-expanded
//    on the button + a class on the shell; Escape and a backdrop click close it.

function initScrollSpy(): void {
	const toc = document.querySelector<HTMLElement>('[data-docs-toc]');
	if (!toc) return;

	const links = Array.from(toc.querySelectorAll<HTMLAnchorElement>('[data-toc-link]'));
	if (links.length === 0) return;

	const bySlug = new Map<string, HTMLAnchorElement>();
	const targets: HTMLElement[] = [];
	for (const link of links) {
		const slug = link.getAttribute('data-toc-link');
		if (!slug) continue;
		const heading = document.getElementById(slug);
		if (!heading) continue;
		bySlug.set(slug, link);
		targets.push(heading);
	}
	if (targets.length === 0) return;

	const setActive = (slug: string): void => {
		for (const link of links) link.removeAttribute('aria-current');
		const active = bySlug.get(slug);
		if (active) active.setAttribute('aria-current', 'location');
	};

	// Track which headings are intersecting; the topmost visible one is active.
	const visible = new Set<string>();
	const observer = new IntersectionObserver(
		(entries) => {
			for (const entry of entries) {
				const id = entry.target.id;
				if (entry.isIntersecting) visible.add(id);
				else visible.delete(id);
			}
			// pick the first heading (document order) that is currently visible
			for (const heading of targets) {
				if (visible.has(heading.id)) {
					setActive(heading.id);
					return;
				}
			}
		},
		// a band near the top of the viewport so the "current" section is the one
		// you're reading, not one just scrolling past the bottom
		{ rootMargin: '0px 0px -70% 0px', threshold: 0 },
	);

	for (const heading of targets) observer.observe(heading);
	setActive(targets[0].id);
}

function initDrawer(): void {
	const shell = document.querySelector<HTMLElement>('[data-docs-shell]');
	const toggle = document.querySelector<HTMLButtonElement>('[data-docs-nav-toggle]');
	const backdrop = document.querySelector<HTMLElement>('[data-docs-nav-backdrop]');
	if (!shell || !toggle) return;

	const open = (): void => {
		shell.classList.add('is-nav-open');
		toggle.setAttribute('aria-expanded', 'true');
	};
	const close = (): void => {
		shell.classList.remove('is-nav-open');
		toggle.setAttribute('aria-expanded', 'false');
	};
	const isOpen = (): boolean => shell.classList.contains('is-nav-open');

	toggle.addEventListener('click', () => (isOpen() ? close() : open()));
	backdrop?.addEventListener('click', close);
	document.addEventListener('keydown', (e) => {
		if (e.key === 'Escape' && isOpen()) {
			close();
			toggle.focus();
		}
	});
	// closing the drawer after following an in-drawer link keeps mobile tidy
	shell
		.querySelector('[data-docs-sidebar]')
		?.addEventListener('click', (e) => {
			if ((e.target as HTMLElement).closest('a')) close();
		});
}

function init(): void {
	initScrollSpy();
	initDrawer();
}

if (document.readyState === 'loading') {
	document.addEventListener('DOMContentLoaded', init, { once: true });
} else {
	init();
}
