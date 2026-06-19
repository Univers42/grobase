// Navigation + footer + announcement model for the whole site.
// The header's mega-menus, the footer columns, the announcement card and the
// social row all read from HERE — one source of truth so a renamed page or a
// new audience changes in exactly one place.
//
// HONESTY: every blurb describes a real Grobase capability (8 engines, one API;
// per-tenant isolation; the 5 MB nano binary; full-text + vector search;
// realtime; storage; functions; RLS/owner-scoping; tiers nano→max). No invented
// numbers, no competitor framing. Pages that don't exist yet point at the
// nearest real page (the homepage, /pricing/, /docs/, /blog/) so no link 404s.
//
// `icon` values are NAMES in src/icons/registry.ts (the fixed, injection-proof
// path map). Use only names that exist there; consumers render them via
// src/components/ui/Icon.astro.
import { SITE } from './site';

export interface NavLink {
	label: string;
	href: string;
	/** registry.ts icon name */
	icon: string;
	/** one honest line about what this audience / resource gets */
	blurb: string;
}

/** Which mega-menu a top-nav item opens (keys below). */
export type MenuKey = 'solutions' | 'resources';

export interface TopNavItem {
	label: string;
	/** opens a mega-menu… */
	menu?: MenuKey;
	/** …or links straight to a page. */
	href?: string;
}

// ── SOLUTIONS mega-menu — "who is building" ────────────────────────────────
// Each maps to a per-audience page (content lives in solutions.ts). The blurb
// is the value to THAT audience, in plain language, grounded in real features.
export const SOLUTIONS: NavLink[] = [
	{
		label: 'Founders',
		href: '/solutions/founders/',
		icon: 'rocket',
		blurb: 'Ship the whole backend on a 5 MB binary, grow to thousands of customers — no rewrite.',
	},
	{
		label: 'Sales',
		href: '/solutions/sales/',
		icon: 'chart',
		blurb: 'Stand up a customer-facing data app over your existing database in days, not quarters.',
	},
	{
		label: 'Product managers',
		href: '/solutions/product/',
		icon: 'compass',
		blurb: 'Validate a feature against real data with realtime updates and an honest, capped cost.',
	},
	{
		label: 'Designers',
		href: '/solutions/designers/',
		icon: 'palette',
		blurb: 'Wire a prototype to live CRUD, realtime and storage from one SDK — no backend to wait on.',
	},
	{
		label: 'Marketers',
		href: '/solutions/marketers/',
		icon: 'megaphone',
		blurb: 'Run campaign sites and capture forms with built-in accounts, storage and email.',
	},
	{
		label: 'Ops',
		href: '/solutions/ops/',
		icon: 'gauge',
		blurb: 'Self-host one stack with measured RAM, per-tenant isolation and audit you can verify.',
	},
	{
		label: 'People',
		href: '/solutions/people/',
		icon: 'users',
		blurb: 'Build internal HR and team tools where every person only sees their own records.',
	},
	{
		label: 'Prototyping',
		href: '/solutions/prototyping/',
		icon: 'sparkle',
		blurb: 'Go from idea to a working backend in minutes — accounts, data and realtime, no setup.',
	},
	{
		label: 'Internal tools',
		href: '/solutions/internal-tools/',
		icon: 'wrench',
		blurb: 'Front any database — Postgres, MySQL, Mongo and more — with one secure, scoped API.',
	},
];

// ── RESOURCES mega-menu — "how to go further" ──────────────────────────────
export const RESOURCES: NavLink[] = [
	{
		label: 'Blog',
		href: '/blog/',
		icon: 'pen',
		blurb: 'Release notes, engineering write-ups and the measured story behind every claim.',
	},
	{
		label: 'Partners',
		href: '/resources/partners/',
		icon: 'handshake',
		blurb: 'Hosting, agency and integration partners who deploy and extend Grobase.',
	},
	{
		label: 'Templates',
		href: '/resources/templates/',
		icon: 'layers',
		blurb: 'Starter projects — SaaS, internal tool, data API — wired to the SDK on day one.',
	},
	{
		label: 'Guides',
		href: '/docs/guides/',
		icon: 'book',
		blurb: 'Task-first walkthroughs: auth, realtime, storage, functions and multi-engine queries.',
	},
	{
		label: 'Connectors',
		href: '/resources/connectors/',
		icon: 'plug',
		blurb: 'The 8 database engines Grobase speaks behind one uniform API — no per-engine rewrite.',
	},
	{
		label: 'Docs',
		href: '/docs/',
		icon: 'book',
		blurb: 'API reference, SDK guides and self-host runbooks for the whole platform.',
	},
];

// ── Top navigation bar ─────────────────────────────────────────────────────
// Two items open mega-menus; the rest are direct links. NOTE: there is
// intentionally NO /compare/ link (e2e invariant + no-competitor ethos).
export const TOP_NAV: TopNavItem[] = [
	{ label: 'Solutions', menu: 'solutions' },
	{ label: 'Resources', menu: 'resources' },
	{ label: 'Enterprise', href: '/enterprise/' },
	{ label: 'Pricing', href: '/pricing/' },
	{ label: 'Security', href: '/security/' },
];

// Lookup so the header can resolve a menu key → its links without a switch.
export const MENUS: Record<MenuKey, NavLink[]> = {
	solutions: SOLUTIONS,
	resources: RESOURCES,
};

// ── Mega-menu announcement card (liquid-glass) ─────────────────────────────
// Honest headline: a real, shipped capability. The image is a LOCAL asset
// (CSP img-src 'self' data:) — never an external URL.
export interface Announcement {
	image: string;
	eyebrow: string;
	title: string;
	body: string;
	href: string;
	cta: string;
}

export const ANNOUNCEMENT: Announcement = {
	image: '/img/announcement.svg',
	eyebrow: 'One codebase',
	title: 'From a 5 MB binary to a 10K-tenant platform.',
	body: 'Start on a single static binary, grow to thousands of customers on one stack — same SDK, same API, no rewrite. Full-text and vector search are first-class across the engines.',
	href: '/pricing/',
	cta: 'Learn more',
};

// ── Footer ─────────────────────────────────────────────────────────────────
export interface FooterLink {
	label: string;
	href: string;
}
export interface FooterGroup {
	title: string;
	links: FooterLink[];
}

// Pages that don't exist yet point at the nearest real page so nothing 404s:
//   About/Contact → homepage · Roadmap → /#roadmap · Changelog → /blog/
//   Privacy/Terms/License → /security/ (the nearest published trust page).
export const FOOTER_GROUPS: FooterGroup[] = [
	{
		title: 'Product',
		links: [
			{ label: 'Overview', href: '/' },
			{ label: 'Pricing', href: '/pricing/' },
			{ label: 'Security', href: '/security/' },
			{ label: 'Enterprise', href: '/enterprise/' },
			{ label: 'Docs', href: '/docs/' },
		],
	},
	{
		title: 'Solutions',
		links: [
			{ label: 'Founders', href: '/solutions/founders/' },
			{ label: 'Internal tools', href: '/solutions/internal-tools/' },
			{ label: 'Prototyping', href: '/solutions/prototyping/' },
			{ label: 'Ops', href: '/solutions/ops/' },
		],
	},
	{
		title: 'Resources',
		links: [
			{ label: 'Blog', href: '/blog/' },
			{ label: 'Guides', href: '/docs/guides/' },
			{ label: 'Templates', href: '/resources/templates/' },
			{ label: 'Connectors', href: '/resources/connectors/' },
			{ label: 'Partners', href: '/resources/partners/' },
		],
	},
	{
		title: 'Company',
		links: [
			{ label: 'About', href: '/' },
			{ label: 'Roadmap', href: '/#roadmap' },
			{ label: 'Changelog', href: '/blog/' },
			{ label: 'Contact', href: '/' },
		],
	},
	{
		title: 'Legal',
		links: [
			{ label: 'Privacy', href: '/security/' },
			{ label: 'Terms', href: '/security/' },
			{ label: 'License', href: '/security/' },
		],
	},
];

// ── Social row ─────────────────────────────────────────────────────────────
// GitHub points at the real repo (from SITE). The rest use registry icon names
// (x-twitter / discord / rss). Hrefs stay on real destinations; the RSS feed is
// a LOCAL path so it never violates the egress / no-external rule when present.
export interface SocialLink {
	label: string;
	href: string;
	/** registry.ts icon name */
	icon: string;
}

export const SOCIAL: SocialLink[] = [
	{ label: 'GitHub', href: SITE.repoUrl, icon: 'github' },
	{ label: 'X', href: `${SITE.repoUrl}`, icon: 'x-twitter' },
	{ label: 'Discord', href: `${SITE.repoUrl}`, icon: 'discord' },
	{ label: 'RSS', href: '/rss.xml', icon: 'rss' },
];
