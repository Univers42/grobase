// ── ICON REGISTRY — a FIXED, local, injection-impossible map of SVG geometry.
//
// Each entry is DATA ONLY: a `viewBox` and the inner `body` of an <svg>. The
// body contains ONLY safe primitive geometry — <path> <circle> <line> <rect>
// <polyline> <polygon> <g>. There are NO <script>, NO on* event attributes, NO
// `javascript:` / `data:text/html`, NO <foreignObject>, NO xlink:href, and NO
// external href/src. Colour is never baked in: the consuming <Icon> renders the
// outer <svg> with `stroke="currentColor" fill="none"`, so every icon inherits
// the surrounding text colour (drive it with .accent-N etc — never inline style).
//
// Geometry is Lucide/Feather-style (24×24, 2px round stroke). To add an icon,
// paste only its inner geometry here; `scripts/audit/icon-safety.mjs` proves the
// whole file can never inject script. Do not import anything into this file.

// Each value is the inner SVG geometry (the `body`) of a 24×24 icon — a plain
// string. The consuming <Icon> wraps it in an <svg viewBox="0 0 24 24">.
export const ICONS: Record<string, string> = {
	// ─────────────────────────────── AUDIENCES ──────────────────────────────
	founders:
		'<path d="m12 3 2.1 4.6L19 8.2l-3.6 3.3.9 5L12 14.2 7.7 16.5l.9-5L5 8.2l4.9-.6z"/><path d="M5 21h14"/>',
	sales:
		'<path d="M3 3v18h18"/><path d="m7 14 3-3 3 3 5-6"/><path d="M21 8v3h-3"/>',
	product:
		'<path d="m12 2 9 5v10l-9 5-9-5V7z"/><path d="m12 12 9-5"/><path d="M12 12v10"/><path d="m12 12-9-5"/>',
	designers:
		'<circle cx="13.5" cy="6.5" r="1.5"/><circle cx="17.5" cy="10.5" r="1.5"/><circle cx="8.5" cy="7.5" r="1.5"/><circle cx="6.5" cy="12.5" r="1.5"/><path d="M12 2a10 10 0 0 0 0 20 2 2 0 0 0 2-2 2 2 0 0 1 2-2h1.5a4.5 4.5 0 0 0 4.5-4.5A10 10 0 0 0 12 2z"/>',
	marketers:
		'<path d="m3 11 14-6v14L3 13z"/><path d="M3 11v2"/><path d="M17 8a3 3 0 0 1 0 6"/><path d="M7 13v5l3 1"/>',
	ops: '<path d="M12 2v3"/><path d="M12 19v3"/><path d="m4.9 4.9 2.1 2.1"/><path d="m17 17 2.1 2.1"/><path d="M2 12h3"/><path d="M19 12h3"/><path d="m4.9 19.1 2.1-2.1"/><path d="m17 7 2.1-2.1"/><circle cx="12" cy="12" r="3.5"/>',
	people:
		'<circle cx="9" cy="8" r="3"/><path d="M3 20a6 6 0 0 1 12 0"/><path d="M16 5.5a3 3 0 0 1 0 5.5"/><path d="M17 14a6 6 0 0 1 4 6"/>',
	prototyping:
		'<rect x="3" y="4" width="18" height="14" rx="2"/><path d="M3 9h18"/><path d="M7 13h5"/><circle cx="6" cy="6.5" r=".6"/><path d="M9 21h6"/>',
	'internal-tools':
		'<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',

	// ─────────────────────────────── RESOURCES ──────────────────────────────
	blog: '<path d="M4 4h12a2 2 0 0 1 2 2v13a1 1 0 0 1-1 1H6a2 2 0 0 1-2-2z"/><path d="M8 8h8"/><path d="M8 12h8"/><path d="M8 16h5"/>',
	partners:
		'<path d="m11 17-3 3a2.83 2.83 0 0 1-4-4l5-5a3 3 0 0 1 4 0l.5.5"/><path d="m13 7 3-3a2.83 2.83 0 0 1 4 4l-5 5a3 3 0 0 1-4 0l-.5-.5"/>',
	templates:
		'<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18"/><path d="M9 21V9"/>',
	guides:
		'<path d="M4 5a2 2 0 0 1 2-2h12v17H6a2 2 0 0 0-2 2z"/><path d="M9 7h5"/><path d="M9 11h5"/><circle cx="12" cy="17" r="2.5"/><path d="M12 14.5v-.5"/>',
	connectors:
		'<rect x="2" y="9" width="6" height="6" rx="1"/><rect x="16" y="9" width="6" height="6" rx="1"/><path d="M8 12h3"/><path d="M13 12h3"/><circle cx="12" cy="12" r="1"/>',
	docs: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M8 13h8"/><path d="M8 17h8"/>',

	// ──────────────────────────────── FEATURES ──────────────────────────────
	database:
		'<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v6c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 11v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/>',
	realtime:
		'<path d="M2 12h3l2-7 4 16 3-12 2 5h6"/>',
	storage:
		'<rect x="3" y="4" width="18" height="5" rx="1"/><rect x="3" y="11" width="18" height="5" rx="1"/><path d="M7 6.5h.01"/><path d="M7 13.5h.01"/><path d="M3 16v2a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-2"/>',
	functions:
		'<path d="M9 4h-.5A2.5 2.5 0 0 0 6 6.5V9a2 2 0 0 1-2 2 2 2 0 0 1 2 2v2.5A2.5 2.5 0 0 0 8.5 18H9"/><path d="M15 4h.5A2.5 2.5 0 0 1 18 6.5V9a2 2 0 0 0 2 2 2 2 0 0 0-2 2v2.5a2.5 2.5 0 0 1-2.5 2.5H15"/>',
	search:
		'<circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/>',
	auth: '<rect x="3" y="11" width="18" height="10" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/><circle cx="12" cy="16" r="1.2"/>',
	shield:
		'<path d="M12 2 4 5v6c0 5 3.4 8.5 8 10 4.6-1.5 8-5 8-10V5z"/><path d="m9 12 2 2 4-4"/>',
	zap: '<polygon points="13 2 4 14 11 14 10 22 19 10 12 10 13 2"/>',
	globe:
		'<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3a14 14 0 0 1 0 18 14 14 0 0 1 0-18z"/>',
	smartphone:
		'<rect x="6" y="2" width="12" height="20" rx="2"/><path d="M11 18h2"/>',
	chart:
		'<path d="M3 3v18h18"/><rect x="7" y="11" width="3" height="6"/><rect x="12" y="7" width="3" height="10"/><rect x="17" y="13" width="3" height="4"/>',
	plug: '<path d="M9 2v6"/><path d="M15 2v6"/><path d="M7 8h10v3a5 5 0 0 1-10 0z"/><path d="M12 16v6"/>',
	layers:
		'<polygon points="12 2 21 7 12 12 3 7 12 2"/><polyline points="3 12 12 17 21 12"/><polyline points="3 17 12 22 21 17"/>',
	server:
		'<rect x="3" y="4" width="18" height="7" rx="1"/><rect x="3" y="13" width="18" height="7" rx="1"/><path d="M7 7.5h.01"/><path d="M7 16.5h.01"/><path d="M11 7.5h6"/><path d="M11 16.5h6"/>',
	cloud:
		'<path d="M17.5 18H7a4 4 0 0 1-.8-7.9 5.5 5.5 0 0 1 10.6-1.1 3.5 3.5 0 0 1 .7 9z"/>',
	gauge:
		'<path d="M12 14 16 9"/><path d="M3.5 18a9 9 0 1 1 17 0z"/><circle cx="12" cy="14" r="1.4"/>',
	'git-branch':
		'<line x1="6" y1="3" x2="6" y2="15"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="6" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/>',
	rocket:
		'<path d="M5 16c-1.5 1.3-2 5-2 5s3.7-.5 5-2a2.1 2.1 0 0 0-3-3z"/><path d="M9 15c-1.5-1.5-1.5-4 0-7a9 9 0 0 1 9-5c0 4-1 7-3 9-2.5 2-5 2-6 3z"/><circle cx="15" cy="9" r="1.6"/>',
	lock: '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
	key: '<circle cx="7.5" cy="15.5" r="3.5"/><path d="m10 13 9-9"/><path d="m16 4 3 3"/><path d="m14 6 2 2"/>',
	users:
		'<circle cx="9" cy="8" r="3.2"/><path d="M3 20a6 6 0 0 1 12 0"/><path d="M16 5.2a3.2 3.2 0 0 1 0 5.6"/><path d="M17 13.5a6 6 0 0 1 4 6.5"/>',
	settings:
		'<circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.3 1a7 7 0 0 0-1.7-1l-.3-2.6h-4l-.3 2.6a7 7 0 0 0-1.7 1l-2.3-1-2 3.4 2 1.5a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.3-1a7 7 0 0 0 1.7 1l.3 2.6h4l.3-2.6a7 7 0 0 0 1.7-1l2.3 1 2-3.4-2-1.5a7 7 0 0 0 .1-1z"/>',
	wrench:
		'<path d="M14.5 6a3.5 3.5 0 0 0 4.6 4.6L21 12.5l-8.5 8.5a2.1 2.1 0 0 1-3-3L18 9.5 16.1 7.6A3.5 3.5 0 0 1 14.5 6z"/>',
	palette:
		'<circle cx="13.5" cy="6.5" r="1.4"/><circle cx="17" cy="10.5" r="1.4"/><circle cx="8" cy="7" r="1.4"/><circle cx="6.5" cy="12" r="1.4"/><path d="M12 2a10 10 0 0 0 0 20 2 2 0 0 0 2-2 2 2 0 0 1 2-2h1.6a4.4 4.4 0 0 0 4.4-4.4A10 10 0 0 0 12 2z"/>',
	megaphone:
		'<path d="M3 11v2a1 1 0 0 0 1 1h2l8 5V5L6 10H4a1 1 0 0 0-1 1z"/><path d="M17 8a4 4 0 0 1 0 8"/><path d="M7 14v4l3 1"/>',
	handshake:
		'<path d="m8 12 2.5 2.5a1.5 1.5 0 0 0 2.1 0L17 10"/><path d="M3 11 7 7h4l2 2"/><path d="m21 11-4-4h-3"/><path d="M7 7v8a1 1 0 0 0 1 1"/><path d="M17 10v5a1 1 0 0 1-1 1"/>',
	'book-open':
		'<path d="M12 6a4 4 0 0 0-4-2H3v14h5a4 4 0 0 1 4 2"/><path d="M12 6a4 4 0 0 1 4-2h5v14h-5a4 4 0 0 0-4 2"/><path d="M12 6v14"/>',
	'file-text':
		'<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M9 13h6"/><path d="M9 17h6"/><path d="M9 9h2"/>',
	activity:
		'<path d="M3 12h4l2-7 4 16 2-9h6"/>',

	// ──────────────────────────────── UI / NAV ──────────────────────────────
	'arrow-right':
		'<line x1="4" y1="12" x2="20" y2="12"/><polyline points="14 6 20 12 14 18"/>',
	'arrow-up-right':
		'<line x1="6" y1="18" x2="18" y2="6"/><polyline points="9 6 18 6 18 15"/>',
	'chevron-down':
		'<polyline points="5 9 12 16 19 9"/>',
	check:
		'<polyline points="4 12 9 17 20 6"/>',
	star: '<polygon points="12 2 15 9 22 9.3 16.5 14 18.5 21 12 17 5.5 21 7.5 14 2 9.3 9 9 12 2"/>',
	sparkle:
		'<path d="M12 3c.6 4 1.4 4.8 5.4 5.4C13.4 9 12.6 9.8 12 13.8 11.4 9.8 10.6 9 6.6 8.4 10.6 7.8 11.4 7 12 3z"/><path d="M18 14c.3 1.8.7 2.2 2.5 2.5-1.8.3-2.2.7-2.5 2.5-.3-1.8-.7-2.2-2.5-2.5 1.8-.3 2.2-.7 2.5-2.5z"/>',
	menu: '<line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/>',
	close:
		'<line x1="6" y1="6" x2="18" y2="18"/><line x1="18" y1="6" x2="6" y2="18"/>',
	'external-link':
		'<path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M19 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h6"/>',
	quote:
		'<path d="M7 7H4a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v3a4 4 0 0 1-3 3.8"/><path d="M18 7h-3a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v3a4 4 0 0 1-3 3.8"/>',

	// ───────────────────────────────── SOCIAL ───────────────────────────────
	github:
		'<path d="M9 19c-4 1.4-4-2-6-2.5"/><path d="M15 21v-3.3a3 3 0 0 0-.8-2.3c2.8-.3 5.5-1.4 5.5-6a4.6 4.6 0 0 0-1.3-3.2 4.3 4.3 0 0 0-.1-3.2S17 2 14.5 3.6a12 12 0 0 0-6 0C6 2 5 2.7 5 2.7a4.3 4.3 0 0 0-.1 3.2A4.6 4.6 0 0 0 3.5 9.1c0 4.6 2.7 5.7 5.5 6a3 3 0 0 0-.8 2.3V21"/>',
	'x-twitter':
		'<path d="M4 3h4.5l4 5.7L17.5 3H21l-6.4 8L21 21h-4.5l-4.3-6.1L6.5 21H3l6.8-8.5z"/>',
	discord:
		'<path d="M8 4.5a18 18 0 0 0-4 1.5C2.2 9 1.6 12 2 15a13 13 0 0 0 4 2l1-1.6"/><path d="M16 4.5a18 18 0 0 1 4 1.5c1.8 3 2.4 6 2 9a13 13 0 0 1-4 2l-1-1.6"/><path d="M7.5 14c3 1.3 6 1.3 9 0"/><circle cx="9" cy="11" r="1"/><circle cx="15" cy="11" r="1"/>',
	rss: '<path d="M4 11a9 9 0 0 1 9 9"/><path d="M4 4a16 16 0 0 1 16 16"/><circle cx="5" cy="19" r="1.6"/>',
	mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>',
};
