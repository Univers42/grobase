// The pricing comparison matrix + per-tier advantages/trade-offs.
// Numbers are consistent with tiers.ts (the site's single source of truth) —
// the throughput figures here use the tiers.ts rate limits (100/200/200/800),
// superseding the old CapabilityMatrix component which had drifted (10/20/200/2000).
import type { TierId } from './tiers';

export const MATRIX_TIERS: { id: TierId; name: string }[] = [
	{ id: 'nano', name: 'Nano' },
	{ id: 'basic', name: 'Basic' },
	{ id: 'essential', name: 'Essential' },
	{ id: 'pro', name: 'Pro' },
	{ id: 'max', name: 'Max' },
];

/** A matrix cell is either a value (string) or a yes/no capability (boolean). */
export type Cell = string | boolean;
export interface MatrixRow {
	label: string;
	cells: Record<TierId, Cell>;
}
export interface MatrixGroup {
	group: string;
	rows: MatrixRow[];
}

const row = (label: string, nano: Cell, basic: Cell, essential: Cell, pro: Cell, max: Cell): MatrixRow => ({
	label,
	cells: { nano, basic, essential, pro, max },
});

export const MATRIX: MatrixGroup[] = [
	{
		group: 'Pricing & footprint',
		rows: [
			row('Price / month', 'Free / $5', 'Free / $9', '$25–39', '$59–99', '$149–299'),
			row('Runs on (measured RAM)', '2.0 MiB', '~460 MiB', '~950 MiB', '~1.4 GiB', '~3.1 GiB'),
			row('Image size', '5.1 MB', '~0.9 GB', '~3 GB', '~5.3 GB', '~11 GB'),
		],
	},
	{
		group: 'Engines & throughput',
		rows: [
			row('Database engines', 'SQLite (+PG opt.)', 'SQLite · PostgreSQL', 'SQLite · PostgreSQL', '6 engines', '8 engines (all)'),
			row('Throughput', '—', '100 rps', '200 rps', '200 rps', '800 rps'),
			row('Database mounts', '1', '1', '2', '10', '50'),
		],
	},
	{
		group: 'Operations',
		rows: [
			row('CRUD + upsert', true, true, true, true, true),
			row('Aggregate (count / sum / group-by)', false, false, true, true, true),
			row('Batch writes', false, false, false, true, true),
			row('Transactions', false, false, false, true, true),
			row('DDL + introspection', false, false, false, false, true),
		],
	},
	{
		group: 'Realtime, storage & analytics',
		rows: [
			row('Realtime CDC (WebSocket)', 'SSE (read)', false, false, true, true),
			row('Object storage (S3)', false, false, false, true, true),
			row('Analytics (Trino + Iceberg)', false, false, false, false, true),
			row('AI service + edge functions', false, false, false, false, true),
		],
	},
	{
		group: 'Tenancy & security',
		rows: [
			row('Isolation models', 'in-process', 'shared-RLS', '+ schema-per-tenant', '+ database-per-tenant', 'all 4 (+ tenant-owned)'),
			row('Field masks / ABAC', false, false, true, true, true),
			row('Webhooks · email · GDPR', false, false, true, true, true),
			row('SECURITY_MODE=max (TLS verify-full · audit · Vault)', false, false, false, false, true),
		],
	},
];

export interface Verdict {
	id: TierId;
	name: string;
	advantages: string[];
	tradeoffs: string[];
	bestWhen: string;
	outgrowWhen: string;
}

export const VERDICTS: Verdict[] = [
	{
		id: 'nano',
		name: 'Nano',
		advantages: ['Free — one 5.1 MB static binary', 'Zero config: SQLite in-process', '~2 MiB idle RSS (measured)', 'Graduates to Basic with no rewrite'],
		tradeoffs: ['SQLite-centric (PostgreSQL optional)', 'No rate limiting or tenant isolation', 'No realtime CDC, batch, aggregate or transactions'],
		bestWhen: 'Landing pages, prototypes, or one tiny app where a 5 MB binary on a $5 box is all you need.',
		outgrowWhen: 'You need PostgreSQL as primary, per-tenant rate limits, or more than one app.',
	},
	{
		id: 'basic',
		name: 'Basic',
		advantages: ['Node-free data plane: Kong → Rust → engine', 'Per-tenant rate limits + API-key scopes', 'Owner-scoped CRUD on SQLite + PostgreSQL', 'Runs on a Pi or a $5 VPS'],
		tradeoffs: ['Single database mount', 'No aggregate, batch or transactions', 'No realtime, object storage or webhooks'],
		bestWhen: 'A private app or prototype that needs real Postgres plus rate limiting, cheaply.',
		outgrowWhen: 'You need aggregates/group-by, webhooks, email, or more than one mount.',
	},
	{
		id: 'essential',
		name: 'Essential',
		advantages: ['Adds aggregate (count / sum / group-by)', 'Graph, field masks (ABAC) + automations', 'Webhooks + email + GDPR services', 'The full single-product surface, under 1 GB RAM'],
		tradeoffs: ['Still SQLite + PostgreSQL only', 'No multi-engine, realtime or transactions', 'Two mounts'],
		bestWhen: 'One full-feature product that needs reporting, masks, webhooks and GDPR — without multi-engine.',
		outgrowWhen: 'You need MySQL / Mongo / Redis, realtime, object storage or transactions.',
	},
	{
		id: 'pro',
		name: 'Pro',
		advantages: ['6 engines behind one API (PG, MySQL, Mongo, Redis, Cockroach, SQLite)', 'Realtime WebSocket CDC + object storage', 'Batch, aggregate AND transactions', '10 mounts · database-per-tenant isolation', 'Under $1 / tenant amortized multi-tenant'],
		tradeoffs: ['No MSSQL or HTTP federation', 'No analytics plane, AI or edge functions', 'No DDL / introspection'],
		bestWhen: 'A multi-engine SaaS with realtime and several customers per host.',
		outgrowWhen: 'You need MSSQL, an analytics lakehouse, AI, edge functions, or runtime DDL.',
	},
	{
		id: 'max',
		name: 'Max',
		advantages: ['All 8 engines incl. MSSQL + HTTP federation', 'Analytics plane (Trino + Iceberg)', 'AI service, edge functions, observability', 'DDL + introspection · all 4 isolation models', 'SECURITY_MODE=max: TLS verify-full, audit, Vault'],
		tradeoffs: ['Heaviest footprint (~3.1 GiB)', 'Highest price — overkill for a single app', 'You pay for capabilities you may not use yet'],
		bestWhen: 'A multi-tenant cloud platform that needs every engine, analytics and the strictest security.',
		outgrowWhen: "You don't — this is the top of the ladder; scale horizontally from here.",
	},
];
