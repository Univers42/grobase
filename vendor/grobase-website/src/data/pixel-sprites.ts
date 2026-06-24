// ── Pixel-art sprites — ORIGINAL, authored as colour grids (no external/fetched
// art: the strict CSP blocks remote images and stray art is a licensing risk).
// Each grid is an array of rows; each character maps to a palette colour, ' '
// (space) = transparent. Two frames per character give a simple walk cycle.
// Rendered by PixelSprite.astro as crisp <rect>s; animated by scene.ts.

export type Palette = Record<string, string>;

// ── Mouse — side view, facing right (head/ear right, tail left). ──────────────
export const MOUSE_PAL: Palette = { m: '#aab0c8', d: '#6b7090', p: '#ff8fd6', e: '#0b0b14' };

export const MOUSE_A: string[] = [
	'          ',
	'       dd ',
	'      dppd',
	' mmmmmmd  ',
	'tmmmmmmemd',
	' mmmmmmmdp',
	' m  m  m  ',
];
export const MOUSE_B: string[] = [
	'          ',
	'       dd ',
	'      dppd',
	' mmmmmmd  ',
	'tmmmmmmemd',
	' mmmmmmmdp',
	'  m  m  m ',
];

// ── Person — side view, walking. ──────────────────────────────────────────────
export const PERSON_PAL: Palette = {
	h: '#4a2f63', // hair (lifted so it reads on the dark street)
	s: '#f0c19c', // skin
	j: '#33285e', // jacket (lit, not near-black)
	c: '#00f5d4', // neon trim
	p: '#4d3a7a', // trousers
	k: '#161226', // shoes
};

export const PERSON_A: string[] = [
	'   hhh ',
	'  hsssh',
	'  hsss ',
	'   js  ',
	'  cjjjc',
	'  cjjjc',
	'   jjj ',
	'   jjj ',
	'   ppp ',
	'  pp pp',
	'  pp pp',
	'  kk kk',
];
export const PERSON_B: string[] = [
	'   hhh ',
	'  hsssh',
	'  hsss ',
	'   js  ',
	'  cjjjc',
	'  cjjjc',
	'   jjj ',
	'   jjj ',
	'   ppp ',
	'   ppp ',
	'   p p ',
	'   k k ',
];

// ── Car — side view, facing right (headlight right, taillight left). ──────────
// 'b' is the body colour; swap it per car via the variant palettes below.
export const CAR: string[] = [
	'                  ',
	'       bbbbb      ',
	'      bcccccb     ',
	'   bbbbbbbbbbbb h ',
	' t bbbbbbbbbbbbbh ',
	'   bbbbbbbbbbbbb  ',
	'   kk      kk     ',
	'   kk      kk     ',
];

const CAR_BASE: Palette = { c: '#9ff7ec', h: '#ffe600', t: '#ff3b6b', k: '#0a0a14' };
export const CAR_PALETTES: Palette[] = [
	{ ...CAR_BASE, b: '#ff3af2' }, // magenta
	{ ...CAR_BASE, b: '#22c3d6' }, // cyan
	{ ...CAR_BASE, b: '#ff7a3d' }, // orange
	{ ...CAR_BASE, b: '#9a6bff' }, // violet
];
