// SINGLE SOURCE OF TRUTH for every tier number on this site.
// Transcribed from apps/baas/wiki/cost-analysis.md + service-tiers.md
// (all RAM figures measured live 2026-06-11 via `make bench-footprint`;
// Fly.io rates from fly.io/docs/about/pricing, June 2026).
export type TierId = 'nano' | 'basic' | 'essential' | 'pro' | 'max';

export interface Tier {
	id: TierId;
	name: string;
	colorVar: string;
	ram: string;
	services: string;
	images: string;
	provision: string;
	computeUsd: number;
	volumeUsd: number;
	volumeNote: string;
	egressUsd: number;
	allIn: string;
	idleNote?: string;
	retail: string;
	retailNote: string;
	engines: string[];
	rateLimit?: string;
	maxMounts?: string;
	features: string[];
	audience: string;
	flag?: string;
}

export const FLY_RATES = {
	sharedVcpu: 0.77,
	ramPerGb: 5.0,
	volumePerGb: 0.15,
	egressPerGb: 0.02,
	scaleToZero: 'a stopped Machine bills only $0.15/GB rootfs',
} as const;

export const TIERS: Tier[] = [
	{
		id: 'nano',
		name: 'Nano',
		colorVar: '--gb-tier-nano',
		ram: '2.0 MiB (measured)',
		services: '1 binary',
		images: '5.1 MB',
		provision: '1 vCPU · 256 MB',
		computeUsd: 2.02,
		volumeUsd: 0.3,
		volumeNote: '2 GB',
		egressUsd: 0.2,
		allIn: '≈ $2–3 / mo',
		idleNote: '< $1/mo idle (scale-to-zero)',
		retail: 'Free / $5',
		retailNote: 'per month',
		engines: ['SQLite (in-process)', 'external PostgreSQL (optional)'],
		features: [
			'One 5.1 MB static binary (scratch image)',
			'CRUD + schema + graph + scoped keys + live updates',
			'Tiny: ~2 MiB of RAM at idle (measured)',
			'Graduates to Basic with zero rewrites',
		],
		audience: 'Landing pages, prototypes, one tiny app',
		flag: 'Start free',
	},
	{
		id: 'basic',
		name: 'Basic',
		colorVar: '--gb-tier-basic',
		ram: '~460 MiB',
		services: '11 services · 0 Node',
		images: '~0.9 GB',
		provision: '1 vCPU · 1 GB',
		computeUsd: 5.77,
		volumeUsd: 0.45,
		volumeNote: '3 GB',
		egressUsd: 0.5,
		allIn: '≈ $6–7 / mo',
		idleNote: '< $2/mo idle (scale-to-zero)',
		retail: 'Free / $9',
		retailNote: 'per month',
		engines: ['SQLite', 'PostgreSQL'],
		rateLimit: '100 rps · burst 200',
		maxMounts: '1 mount',
		features: [
			'Node-free data plane: Kong → Rust → engine',
			'CRUD + owner-scoping + api-key scopes',
			'Per-tenant rate limits',
			'Runs on a Pi or a $5 VPS',
		],
		audience: 'A private app, prototyping',
	},
	{
		id: 'essential',
		name: 'Essential',
		colorVar: '--gb-tier-essential',
		ram: '~950 MiB',
		services: '19 services',
		images: '~3 GB',
		provision: '2 vCPU · 2 GB',
		computeUsd: 11.54,
		volumeUsd: 0.75,
		volumeNote: '5 GB',
		egressUsd: 1.0,
		allIn: '≈ $12–14 / mo',
		retail: '$25–39',
		retailNote: 'per month (~3× infra markup)',
		engines: ['SQLite', 'PostgreSQL'],
		rateLimit: '200 rps · burst 400',
		maxMounts: '2 mounts',
		features: [
			'Adds aggregate (count/sum/group-by) over basic',
			'Graph, field masks, automations',
			'Webhooks + email + GDPR services',
			'Everything under 1 GB of RAM',
		],
		audience: 'A single full-feature product',
	},
	{
		id: 'pro',
		name: 'Pro',
		colorVar: '--gb-tier-pro',
		ram: '~1.4 GiB',
		services: '28 services',
		images: '~5.3 GB',
		provision: '4 vCPU · 3 GB',
		computeUsd: 18.08,
		volumeUsd: 1.5,
		volumeNote: '10 GB',
		egressUsd: 1.5,
		allIn: '≈ $20–23 / mo',
		retail: '$59–99',
		retailNote: 'per month — < $1/tenant amortized multi-tenant',
		engines: ['SQLite', 'PostgreSQL', 'MySQL/MariaDB', 'MongoDB', 'Redis', 'CockroachDB'],
		rateLimit: '200 rps · burst 400',
		maxMounts: '10 mounts',
		features: [
			'Multi-engine: 6 engines, one API',
			'Realtime WebSocket CDC + object storage',
			'Batch, aggregate and transaction capabilities',
		],
		audience: 'A multi-engine SaaS with realtime',
	},
	{
		id: 'max',
		name: 'Max',
		colorVar: '--gb-tier-max',
		ram: '~3.1 GiB',
		services: '41 services',
		images: '~11 GB',
		provision: '8 vCPU · 6 GB',
		computeUsd: 36.15,
		volumeUsd: 3.0,
		volumeNote: '20 GB',
		egressUsd: 2.0,
		allIn: '≈ $40–45 / mo',
		retail: '$149–299',
		retailNote: 'per month — < $1/tenant amortized multi-tenant',
		engines: ['Everything in Pro', 'MSSQL', 'HTTP federation', 'Trino/Iceberg analytics'],
		rateLimit: '800 rps · burst 1600',
		maxMounts: '50 mounts',
		features: [
			'All capabilities incl. DDL + introspection',
			'Analytics plane (Trino + Iceberg)',
			'AI service, edge functions, observability',
			'SECURITY_MODE=max: TLS verify-full, audit, Vault',
		],
		audience: 'A multi-tenant cloud platform',
	},
];

// Headline performance facts (cost-analysis.md §4 + cutover-status.md).
export const HOT_PATH = {
	oldRam: '127 MiB of Node',
	oldDetail: 'query-router 62.7 MiB + permission-engine 64.7 MiB',
	newRam: '3.3 MiB of Rust',
	ramFactor: '~38× lighter',
	oldLatency: '40 ms/req',
	newLatency: '8 ms/req',
	latencyFactor: '5× faster',
} as const;

export const AMORTIZATION = {
	proHostUsd: 21,
	tenantsPerHost: 50,
	perTenant: '$0.40–1.00 / tenant / month',
	marginal: 'Marginal cost of tenant N+1 ≈ storage only ($0.15/GB) + a few MiB of RAM.',
} as const;
