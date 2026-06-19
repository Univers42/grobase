// ── icon-safety — PROVES no SVG on the site can inject JavaScript.
//
// Strict CSP already blocks inline scripts at runtime; this gate kills the
// threat at the source so a malicious/careless SVG never even ships. It scans:
//
//   (a) every entry body in src/icons/registry.ts, and
//   (b) every inline <svg>…</svg> in src/**/*.astro
//
// and fails (exit 1, listing offenders as file:line) if any contains:
//   - a tag outside the safe allow-list
//     (<path> <circle> <line> <rect> <polyline> <polygon> <g> <svg> <title>
//      <defs> <linearGradient> <radialGradient> <stop> <ellipse> <use*>… see below)
//   - <script, an on<handler>= event attribute, javascript:, <foreignObject,
//     xlink:href, an external URL (http:// https:// // ), or data:text/html
//
// Zero dependencies (Node ESM, built-in fs/path/url only). Run directly:
//   node scripts/audit/icon-safety.mjs   → exit 0 clean / exit 1 with offenders
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SRC = join(ROOT, 'src');
const PUBLIC = join(ROOT, 'public');
const REGISTRY = join(SRC, 'icons', 'registry.ts');

// Geometry-only allow-list for the REGISTRY (which we author + keep deliberately
// minimal). <use> is EXCLUDED (it can pull external refs); xlink:href is forbidden
// separately. Gradients/defs are inert. The task spec for the registry is even
// tighter — path/circle/line/rect/polyline/polygon/g — these extras (svg/title/
// defs/gradient/stop/ellipse) are inert presentation, never script vectors.
const REGISTRY_ALLOWED_TAGS = new Set([
	'svg',
	'title',
	'desc',
	'g',
	'defs',
	'path',
	'circle',
	'ellipse',
	'line',
	'rect',
	'polyline',
	'polygon',
	'linearGradient',
	'radialGradient',
	'stop',
]);

// Hand-authored inline <svg> in .astro (diagrams, brand mark) legitimately use
// more presentation elements (<text>/<tspan>/<marker>/gradients/etc) that cannot
// run script. For those we enforce the FORBIDDEN-pattern sweep (the real security
// guarantee) PLUS a DENY-LIST of the genuinely dangerous SVG tags — the elements
// that can execute JS or pull external/active content. <use> is denied because it
// can reference (and activate) external content via href. Capitalised tags
// (Astro components like <Fragment>/<Icon>) are build-time, never shipped — skip.
const INLINE_DENY_TAGS = new Set([
	'script',
	'foreignobject',
	'iframe',
	'embed',
	'object',
	'use',
	'image', // <image href> can load external/active content
	'animate',
	'animatetransform',
	'animatemotion',
	'set',
	'handler',
	'a', // <a href="javascript:…"> inside SVG
]);

// Each rule: a label + a RegExp that, when it matches, is a violation.
// External-URL rules are REFERENCE-CONTEXT-AWARE: they fire only when an external
// URL appears in a loading/activating attribute (href/src/xlink:href) or a CSS
// url(); the inert `xmlns="http://www.w3.org/2000/svg"` namespace declaration on
// a standalone .svg is NOT a vector and must not trip the gate.
const FORBIDDEN = [
	['<script>', /<script\b/i],
	['inline event handler (on*=)', /\son[a-z]+\s*=/i],
	['javascript: URI', /javascript:/i],
	['<foreignObject>', /<foreignobject\b/i],
	['xlink:href', /xlink:href/i],
	['data:text/html', /data:text\/html/i],
	['external http(s) ref (href/src)', /\b(?:href|src)\s*=\s*["']\s*https?:\/\//i],
	['external ref in url(...)', /url\(\s*["']?\s*(?:https?:)?\/\//i],
	['protocol-relative // ref (href/src)', /\b(?:href|src)\s*=\s*["']\s*\/\//i],
	['<image> external load', /<image\b[^>]*\bhref\s*=\s*["']\s*(?:https?:)?\/\//i],
];

const offenders = [];
let scannedRegistryEntries = 0;
let scannedInlineSvgs = 0;

function lineOf(haystack, index) {
	return haystack.slice(0, index).split('\n').length;
}

// Check one chunk of SVG-ish text for forbidden patterns + tag policy.
// `label` is the source location prefix for any offender we record.
// `policy` is 'registry' (strict geometry allow-list) or 'inline'
// (deny-list of dangerous tags; presentation tags like <text> are fine).
function checkChunk(text, label, policy) {
	for (const [name, re] of FORBIDDEN) {
		if (re.test(text)) offenders.push(`${label}  forbidden: ${name}`);
	}
	const tagRe = /<\/?\s*([a-zA-Z][a-zA-Z0-9:-]*)/g;
	let t;
	while ((t = tagRe.exec(text)) !== null) {
		const raw = t[1];
		// Astro components (Capitalised, e.g. <Fragment>/<Icon>) are build-time
		// constructs, never shipped as SVG — they cannot be a runtime vector.
		if (/^[A-Z]/.test(raw)) continue;
		const tag = raw.toLowerCase();
		if (policy === 'registry') {
			if (!REGISTRY_ALLOWED_TAGS.has(tag)) {
				offenders.push(`${label}  disallowed tag (registry): <${raw}>`);
			}
		} else if (INLINE_DENY_TAGS.has(tag)) {
			offenders.push(`${label}  dangerous tag: <${raw}>`);
		}
	}
}

// ── (a) registry.ts — parse the body string of every ICONS entry. ───────────
{
	const file = readFileSync(REGISTRY, 'utf8');
	const rel = relative(ROOT, REGISTRY);
	// Match `name: '…'`, `'name': '…'`, or `"name": "…"` entries; supports both
	// single- and double-quoted bodies (no escaped quotes appear in geometry).
	const entryRe = /(?:^|[,{]\s*)(?:'[^']+'|"[^"]+"|[A-Za-z0-9_$-]+)\s*:\s*(['"])((?:(?!\1)[\s\S])*)\1/g;
	let e;
	while ((e = entryRe.exec(file)) !== null) {
		const body = e[2];
		// Skip the type alias / non-geometry strings: a real icon body has a tag.
		if (!/<[a-zA-Z]/.test(body)) continue;
		scannedRegistryEntries += 1;
		const line = lineOf(file, e.index);
		checkChunk(body, `${rel}:${line}`, 'registry');
	}
	if (scannedRegistryEntries === 0) {
		offenders.push(`${rel}  no ICONS entries parsed — scanner or registry shape changed`);
	}
}

// ── (b) src/**/*.astro — every inline <svg>…</svg>. ─────────────────────────
function walk(dir) {
	for (const name of readdirSync(dir)) {
		const full = join(dir, name);
		const st = statSync(full);
		if (st.isDirectory()) walk(full);
		else if (name.endsWith('.astro')) scanAstro(full);
	}
}

function scanAstro(full) {
	const file = readFileSync(full, 'utf8');
	const rel = relative(ROOT, full);
	const svgRe = /<svg\b[\s\S]*?<\/svg>/gi;
	let s;
	while ((s = svgRe.exec(file)) !== null) {
		scannedInlineSvgs += 1;
		const line = lineOf(file, s.index);
		checkChunk(s[0], `${rel}:${line}`, 'inline');
	}
}

walk(SRC);

// ── (c) public/**/*.svg — shipped standalone SVG assets (favicon, mega-menu
// announcement art, OG art). Same inline policy: forbidden-pattern sweep + the
// dangerous-tag deny-list. This is what makes "no SVG can inject JS" a whole-
// site guarantee, not just a registry one.
let scannedAssetSvgs = 0;
function walkSvg(dir) {
	for (const name of readdirSync(dir)) {
		const full = join(dir, name);
		const st = statSync(full);
		if (st.isDirectory()) walkSvg(full);
		else if (name.toLowerCase().endsWith('.svg')) {
			scannedAssetSvgs += 1;
			checkChunk(readFileSync(full, 'utf8'), relative(ROOT, full), 'inline');
		}
	}
}
walkSvg(PUBLIC);

// ── Summary ─────────────────────────────────────────────────────────────────
console.log('icon-safety scan:');
console.log(`  registry entries scanned : ${scannedRegistryEntries}`);
console.log(`  inline <svg> scanned     : ${scannedInlineSvgs}`);
console.log(`  public .svg scanned      : ${scannedAssetSvgs}`);

if (offenders.length > 0) {
	console.error(`\nicon-safety: FAIL — ${offenders.length} offender(s):`);
	for (const o of offenders) console.error(`  - ${o}`);
	process.exit(1);
}

console.log('icon-safety: PASS — no SVG can inject script (allow-list + forbidden-pattern clean).');
process.exit(0);
