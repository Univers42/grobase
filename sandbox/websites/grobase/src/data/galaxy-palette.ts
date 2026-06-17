// Canvas color constants — the SINGLE source for the galaxy's node colours.
// These hex values mirror the MAXIMALISM accents in
// src/styles/abstracts/_brand-tokens.scss (--gb-a1..a5). The canvas can't read
// CSS vars cheaply per frame, so the hexes live here and seed.ts imports them
// (keep this file and _brand-tokens.scss in sync when the identity changes).
//
// The five accents (rotated through engines/tiers/planes so the drifting nodes
// match the rest of the site):
//   A1 magenta #FF3AF2 · A2 cyan #00F5D4 · A3 yellow #FFE600
//   A4 orange  #FF6B35 · A5 purple #7B2FFF
const A1 = '#ff3af2';
const A2 = '#00f5d4';
const A3 = '#ffe600';
const A4 = '#ff6b35';
const A5 = '#7b2fff';

export const GALAXY_COLORS = {
	// Warm void: a faint purple-tinted black so the backdrop reads in-family
	// instead of cold blue-black.
	bg: '#0d0d1a',
	// Drift links: a low-alpha magenta haze (was cold grey-blue).
	link: 'rgba(255, 58, 242, 0.14)',
	engines: {
		postgres: A2, // cyan
		mysql: A4, // orange
		mongodb: A2, // cyan-green family
		sqlite: A5, // purple
		redis: A1, // magenta
		cockroach: A5, // purple
		mssql: A1, // magenta
		http: A3, // yellow
	},
	tiers: {
		nano: A1, // magenta
		basic: A2, // cyan
		essential: A3, // yellow
		pro: A4, // orange
		max: A5, // purple
	},
	planes: {
		ts: A2, // cyan
		go: A3, // yellow
		rust: A4, // orange
	},
} as const;
