// Content for the Resources pages: partners, templates, connectors and guides.
// Each resource is {title, intro, items[]}; every item is honest and grounded in
// a real Grobase capability. No invented numbers, no competitor mentions.
//
// CONNECTORS is the keystone: the 8 database engines the Rust data plane speaks
// behind ONE uniform query API (mirrors engines.ts / data-plane-pool adapters:
// postgres mysql mongo mssql sqlite redis http dynamodb). `icon` values are
// names in src/icons/registry.ts; consumers render them with Icon.astro.

export interface ResourceItem {
	/** registry.ts icon name */
	icon: string;
	title: string;
	body: string;
	/** optional link to the nearest real page */
	href?: string;
}

export interface Resource {
	title: string;
	intro: string;
	items: ResourceItem[];
}

// ── Partners ────────────────────────────────────────────────────────────────
// Honest starter set: the KINDS of partner Grobase works with. No named logos
// (we don't fabricate customers/partners), described as roles to invite into.
export const PARTNERS: Resource = {
	title: 'Partners',
	intro: 'Grobase is open-source and self-hostable, so partners deploy, host and extend it rather than resell a black box. These are the partnerships we build — get in touch to join.',
	items: [
		{
			icon: 'cloud',
			title: 'Hosting partners',
			body: 'Providers who run managed Grobase on their infrastructure, from a single nano binary to a multi-tenant platform.',
			href: '/pricing/',
		},
		{
			icon: 'wrench',
			title: 'Agencies & integrators',
			body: 'Teams who build products on Grobase for clients — wiring the SDK, the engines and per-tenant isolation into shipping apps.',
			href: '/solutions/internal-tools/',
		},
		{
			icon: 'plug',
			title: 'Engine & tooling partners',
			body: 'Maintainers of databases and tools who help keep the adapter for their engine first-class behind the one query API.',
			href: '/resources/connectors/',
		},
		{
			icon: 'book',
			title: 'Education & community',
			body: 'Authors and communities producing guides, templates and courses on top of the open-source platform.',
			href: '/docs/',
		},
	],
};

// ── Templates ────────────────────────────────────────────────────────────────
// Honest starter set mapped to the use-cases in usecases.ts / tiers.ts.
export const TEMPLATES: Resource = {
	title: 'Templates',
	intro: 'Starter projects wired to the SDK on day one — clone one, point it at your Grobase instance, and you have accounts, data and realtime already connected.',
	items: [
		{
			icon: 'rocket',
			title: 'SaaS starter',
			body: 'A multi-tenant app skeleton with accounts, owner-scoped data and realtime — the shape behind the Pro tier.',
			href: '/solutions/founders/',
		},
		{
			icon: 'wrench',
			title: 'Internal tool',
			body: 'A private team app over an existing database, with capability-scoped API keys and per-person data access.',
			href: '/solutions/internal-tools/',
		},
		{
			icon: 'chart',
			title: 'Data API',
			body: 'One API in front of several engines, with full-text and vector search and count/sum/group-by aggregates.',
			href: '/solutions/sales/',
		},
		{
			icon: 'sparkle',
			title: 'Prototype kit',
			body: 'The 5 MB nano binary with CRUD, schema and live updates ready to go — idea to working backend in minutes.',
			href: '/solutions/prototyping/',
		},
	],
};

// ── Connectors — THE 8 ENGINES under one uniform API ─────────────────────────
// Kept in sync with engines.ts and the data-plane-pool adapters. Honest one-line
// note per engine; no benchmark numbers here (those live in the bench wiki).
export const CONNECTORS: Resource = {
	title: 'Connectors',
	intro: 'Eight database engines, one uniform query API. Point Grobase at the database your data already lives in and read, write, search and aggregate it through a single SDK — no per-engine rewrite, no data migration.',
	items: [
		{
			icon: 'database',
			title: 'PostgreSQL',
			body: 'Flagship OLTP engine — row-level security, logical-replication change-data-capture and full SQL.',
		},
		{
			icon: 'database',
			title: 'MySQL / MariaDB',
			body: 'Full CRUD over a pure-Rust driver, with owner-scoping enforced per request like every other engine.',
		},
		{
			icon: 'database',
			title: 'MongoDB',
			body: 'Document storage with change-stream CDC for realtime, addressed through the same uniform API.',
		},
		{
			icon: 'database',
			title: 'MSSQL',
			body: 'SQL Server over the TDS protocol via a pure-Rust client — no native driver to install.',
		},
		{
			icon: 'database',
			title: 'SQLite',
			body: 'Embedded in-process engine that adds zero extra RAM — the storage behind the 5 MB nano binary.',
		},
		{
			icon: 'database',
			title: 'Redis',
			body: 'Cache, session and key-value workloads behind the same query interface as the SQL engines.',
		},
		{
			icon: 'plug',
			title: 'HTTP / JSON',
			body: 'Federate any HTTP JSON API as a mount, so an external service reads like another table.',
		},
		{
			icon: 'database',
			title: 'DynamoDB',
			body: 'Key-value and document workloads, including transactional writes, through the one uniform API.',
		},
	],
};

// ── Guides — task-first walkthroughs ─────────────────────────────────────────
export const GUIDES: Resource = {
	title: 'Guides',
	intro: 'Task-first walkthroughs that take you from a fresh instance to a working feature — each one covers a real capability of the platform.',
	items: [
		{
			icon: 'lock',
			title: 'Auth & owner-scoping',
			body: 'Set up accounts, issue capability-scoped API keys and make every query see only the caller’s own rows.',
			href: '/docs/guides/',
		},
		{
			icon: 'bolt',
			title: 'Realtime updates',
			body: 'Subscribe to change-data-capture feeds and presence so your UI updates live without polling.',
			href: '/docs/guides/',
		},
		{
			icon: 'image',
			title: 'File storage',
			body: 'Upload, scope and serve files and media through built-in object storage from the SDK.',
			href: '/docs/guides/',
		},
		{
			icon: 'code',
			title: 'Functions',
			body: 'Run server-side functions on triggers and schedules, with secrets kept out of your client.',
			href: '/docs/guides/',
		},
		{
			icon: 'search',
			title: 'Search across engines',
			body: 'Add full-text and vector search and aggregate over your data — whichever engine it lives in.',
			href: '/docs/guides/',
		},
	],
};

/** Convenience map keyed by the slug used in /resources/<slug>/ + /docs/guides/. */
export const RESOURCES_CONTENT: Record<string, Resource> = {
	partners: PARTNERS,
	templates: TEMPLATES,
	connectors: CONNECTORS,
	guides: GUIDES,
};
