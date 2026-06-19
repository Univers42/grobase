// Per-audience solution content, keyed by the slug used in /solutions/<slug>/.
// Each entry maps an audience to the REAL Grobase capabilities that serve it:
//   8 engines behind one API · per-tenant isolation (4 models) · the 5 MB nano
//   binary · full-text + vector search · realtime · object storage · functions ·
//   RLS / owner-scoping per request · tiers nano → max, one codebase no rewrite.
//
// HONESTY: no invented numbers, no competitor mentions. The few figures that
// appear (5 MB, 8 engines, 10K-tenant) are the same measured headline facts the
// rest of the site uses (tiers.ts / engines.ts). `icon` + every point.icon are
// names in src/icons/registry.ts; consumers render with Icon.astro.

export interface SolutionPoint {
	/** registry.ts icon name */
	icon: string;
	title: string;
	body: string;
}

export interface Solution {
	slug: string;
	/** short page/menu title */
	title: string;
	/** the hero line for this audience */
	headline: string;
	/** one supporting sentence under the headline */
	sub: string;
	/** registry.ts icon name (matches nav.ts SOLUTIONS) */
	icon: string;
	/** 3–4 concrete capability points */
	points: SolutionPoint[];
	ctaLabel: string;
	ctaHref: string;
}

export const SOLUTIONS_CONTENT: Record<string, Solution> = {
	founders: {
		slug: 'founders',
		title: 'Founders',
		headline: 'One backend from the first commit to your ten-thousandth customer.',
		sub: 'Start on a 5 MB binary on a spare box, grow to a multi-tenant platform on one stack — the same SDK the whole way.',
		icon: 'rocket',
		points: [
			{
				icon: 'package',
				title: 'Ship on day one',
				body: 'Accounts, database, realtime, files, search and functions are built in. There is no per-project server code to write before you have a product.',
			},
			{
				icon: 'layers',
				title: 'Grow without a rewrite',
				body: 'Nano, Basic, Essential, Pro and Max are the same codebase. Moving up a tier is a deployment decision, never a migration project.',
			},
			{
				icon: 'shield',
				title: 'Multi-tenant when you need it',
				body: 'Per-request owner-scoping keeps every customer’s data separate, so thousands of tenants can share one set of servers safely.',
			},
			{
				icon: 'scale',
				title: 'Costs you can defend',
				body: 'Every RAM figure is measured and every price is rate-card arithmetic. You always know what the next customer costs to serve.',
			},
		],
		ctaLabel: 'See the tiers',
		ctaHref: '/pricing/',
	},
	sales: {
		slug: 'sales',
		title: 'Sales',
		headline: 'A customer-facing data app over the database you already have.',
		sub: 'Front Postgres, MySQL, Mongo or your warehouse with one secure API — no data migration, no new system of record.',
		icon: 'chart',
		points: [
			{
				icon: 'plug',
				title: 'Connect, don’t copy',
				body: 'Eight engines speak one uniform query API. Point Grobase at the database your data already lives in and serve it directly.',
			},
			{
				icon: 'lock',
				title: 'Scoped access by default',
				body: 'Owner-scoping and field masks mean each rep, region or account only sees the rows they are allowed to — enforced on every request.',
			},
			{
				icon: 'bolt',
				title: 'Live numbers',
				body: 'Realtime change feeds push updates to dashboards as deals move, without polling or a separate streaming stack.',
			},
		],
		ctaLabel: 'Explore connectors',
		ctaHref: '/resources/connectors/',
	},
	product: {
		slug: 'product',
		title: 'Product managers',
		headline: 'Validate a feature against real data, with a cost you can cap.',
		sub: 'Stand up a working backend behind a prototype in minutes and keep it honest as it grows into the real thing.',
		icon: 'compass',
		points: [
			{
				icon: 'bolt',
				title: 'Realtime out of the box',
				body: 'Live updates over WebSocket change-data-capture let you test collaborative and live features without building the plumbing.',
			},
			{
				icon: 'search',
				title: 'Search built in',
				body: 'First-class full-text and vector search ship with the platform, so discovery and similarity features don’t need a second service.',
			},
			{
				icon: 'gauge',
				title: 'Capped, capability-gated tiers',
				body: 'Each tier carries an explicit capability mask and rate limit. Experiments stay inside a predictable, honest budget.',
			},
		],
		ctaLabel: 'Read the guides',
		ctaHref: '/docs/guides/',
	},
	designers: {
		slug: 'designers',
		title: 'Designers',
		headline: 'Wire a prototype to a real backend — without waiting on one.',
		sub: 'Live CRUD, realtime and file storage from a single SDK, so your design is backed by real data the moment it loads.',
		icon: 'palette',
		points: [
			{
				icon: 'code',
				title: 'One SDK, no server code',
				body: 'Read and write real records straight from the frontend through the SDK. There is no backend project to spin up first.',
			},
			{
				icon: 'image',
				title: 'Storage for real assets',
				body: 'Built-in object storage holds uploads and media, so mockups use the same files the shipped product will.',
			},
			{
				icon: 'bolt',
				title: 'Realtime interactions',
				body: 'Presence and live updates make multiplayer and collaborative prototypes feel real in a usability test.',
			},
		],
		ctaLabel: 'Browse templates',
		ctaHref: '/resources/templates/',
	},
	marketers: {
		slug: 'marketers',
		title: 'Marketers',
		headline: 'Campaign sites and capture forms with the backend already attached.',
		sub: 'Accounts, storage and email come built in, so a landing page can sign people up and follow up on its own.',
		icon: 'megaphone',
		points: [
			{
				icon: 'users',
				title: 'Sign-ups without a stack',
				body: 'Built-in accounts and scoped API keys let a microsite capture and store leads without a separate auth service.',
			},
			{
				icon: 'mail',
				title: 'Email and webhooks included',
				body: 'Trigger confirmation mail and downstream webhooks from the same platform — no extra integration to wire up.',
			},
			{
				icon: 'package',
				title: 'Tiny to run',
				body: 'A campaign site can run on the 5 MB nano binary on a $5 box and scale up only if the campaign takes off.',
			},
		],
		ctaLabel: 'Start free',
		ctaHref: '/pricing/',
	},
	ops: {
		slug: 'ops',
		title: 'Ops',
		headline: 'One self-hosted stack you can measure, isolate and audit.',
		sub: 'Run the whole platform yourself with measured resource use, per-tenant isolation you choose, and verifiable audit.',
		icon: 'gauge',
		points: [
			{
				icon: 'gauge',
				title: 'Measured footprint',
				body: 'Every tier’s RAM is benchmarked live, from a ~2 MiB nano floor to a full platform — so capacity planning starts from real numbers.',
			},
			{
				icon: 'shield',
				title: 'Isolation you pick',
				body: 'Choose the isolation model per mount, from shared pools for density to dedicated pools for hard tenant separation.',
			},
			{
				icon: 'lock',
				title: 'Security by default',
				body: 'Secrets stay in Vault, access goes through an ABAC policy decision point, and owner-scoping is enforced per request.',
			},
			{
				icon: 'list',
				title: 'Audit you can verify',
				body: 'Tamper-evident, exportable audit logs and per-tenant observability let you prove what happened, not just assert it.',
			},
		],
		ctaLabel: 'See security',
		ctaHref: '/security/',
	},
	people: {
		slug: 'people',
		title: 'People',
		headline: 'Internal HR and team tools where everyone sees only their own records.',
		sub: 'Owner-scoping and field masks make least-privilege the default, so sensitive people-data stays compartmentalised.',
		icon: 'users',
		points: [
			{
				icon: 'lock',
				title: 'Private by construction',
				body: 'Each person’s records are scoped to them on every request. There is no query that quietly returns someone else’s data.',
			},
			{
				icon: 'eye',
				title: 'Field-level masks',
				body: 'Sensitive columns can be masked by role, so a manager view and an employee view come from one dataset, safely.',
			},
			{
				icon: 'wrench',
				title: 'Build the tool, not the backend',
				body: 'Directories, onboarding trackers and approval flows are just CRUD over a scoped API — no bespoke server to maintain.',
			},
		],
		ctaLabel: 'Read the guides',
		ctaHref: '/docs/guides/',
	},
	prototyping: {
		slug: 'prototyping',
		title: 'Prototyping',
		headline: 'Idea to a working backend in minutes, not a sprint.',
		sub: 'Spin up accounts, data and realtime on a single binary, then keep exactly what you built if the idea sticks.',
		icon: 'sparkle',
		points: [
			{
				icon: 'package',
				title: 'One binary to start',
				body: 'The 5 MB nano edition starts in milliseconds and runs anywhere — even a Raspberry Pi — with nothing to sign up for.',
			},
			{
				icon: 'bolt',
				title: 'Real features immediately',
				body: 'CRUD, schema, scoped keys and live updates are there from the first request, so a prototype behaves like a product.',
			},
			{
				icon: 'layers',
				title: 'Nothing thrown away',
				body: 'When the prototype wins, it graduates to a bigger tier on the same codebase — you keep the backend you already built.',
			},
		],
		ctaLabel: 'Start free',
		ctaHref: '/pricing/',
	},
	'internal-tools': {
		slug: 'internal-tools',
		title: 'Internal tools',
		headline: 'Front any database with one secure, scoped API.',
		sub: 'Put Postgres, MySQL, Mongo, SQLite, Redis and more behind a single uniform API — no per-engine rewrite.',
		icon: 'wrench',
		points: [
			{
				icon: 'plug',
				title: 'Eight engines, one API',
				body: 'The data plane speaks Postgres, MySQL, Mongo, MSSQL, SQLite, Redis, DynamoDB and any HTTP/JSON source through one query interface.',
			},
			{
				icon: 'lock',
				title: 'Scoped keys, not a shared admin login',
				body: 'Issue capability-scoped API keys per tool and per person, with owner-scoping enforced per request — no over-broad credentials.',
			},
			{
				icon: 'search',
				title: 'Search and aggregate over your data',
				body: 'Full-text search, vector search and count/sum/group-by aggregates work across the engine you connect, without exporting it first.',
			},
		],
		ctaLabel: 'Explore connectors',
		ctaHref: '/resources/connectors/',
	},
};

/** Convenience: array form for index pages / iteration in stable menu order. */
export const SOLUTIONS_LIST: Solution[] = [
	'founders',
	'sales',
	'product',
	'designers',
	'marketers',
	'ops',
	'people',
	'prototyping',
	'internal-tools',
].map((slug) => SOLUTIONS_CONTENT[slug]!);
