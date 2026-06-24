// MIRROR of mini-baas-infra/config/cost-model.json; the m145 gate enforces parity
// (the site build cannot read the infra file — its Docker build context is site/
// only). This is the SAME pattern as security.ts ↔ config/trust/posture.json
// (m144): a hand-authored typed mirror kept in lockstep with the canonical JSON.
//
// HONESTY (kernel rule #4 — measured, not claimed): every RAM/capacity number
// here is copied verbatim from the canonical cost-model.json, where each cites a
// measured artifact (artifacts/footprint-*.json, artifacts/scale/*.json,
// artifacts/bench/*.json, nano-vs-pocketbase.json) reproducible with
// `make bench-footprint` / `make bench-capacity` / `make bench-load`. Every
// price carries its source_url + the date read + a confidence flag. NO number is
// invented; anything not in an artifact is marked basis_kind/confidence so the
// simulator can flag it "estimated" in front of the user.
//
// COST != PRICE != MARGIN: components+density+storage+egress = the infra COST a
// node consumes; suggestedPriceUsdMonth is what we'd charge; margin = price-cost.
// Human/support/on-call/SRE is NON-INFRA — it is the last costDimension
// (driver="note") and is NEVER folded into the per-tenant RAM math.
//
// PARITY CONTRACT (gate m145): keep `AS_OF`, every hoster's numeric rate fields,
// every tier's `editionRamIdleMib` / `componentRamSumMib` / `rps` /
// `tenantsPerNode.value` / `infraCostUsdMonth` / `suggestedPriceUsdMonth`, and
// the `factors` numbers byte-equal to cost-model.json. Field names are
// camelCased here (TS convention); the gate maps snake_case→camelCase.

export const AS_OF = '2026-06-15';
export const CURRENCY = 'USD';

export type TierId = 'nano' | 'basic' | 'essential' | 'pro' | 'max';
export type HosterId = 'Hetzner' | 'Fly.io' | 'AWS';
/** dedicated = whole node attributed to one app; amortized = node ÷ packed tenants. */
export type CostModel = 'dedicated' | 'amortized';
export type BasisKind = 'measured' | 'mem_limit';

// ── Components — every plane's measured RAM, summed in front of the user. ──────
export interface CostComponent {
	name: string;
	plane: string;
	/** RAM basis in MiB — measured RSS, or the mem_limit ceiling budget. */
	memBasisMib: number;
	basisKind: BasisKind;
	/** The artifact + make target that backs the number (or the ceiling note). */
	source: string;
}

// The full component catalog (cost-model.json `components`). The per-tier
// `componentNames` lists below select from this by `name`.
export const COMPONENTS: CostComponent[] = [
	{ name: 'data-plane-router (Rust data plane)', plane: 'data', memBasisMib: 2.918, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS, holding 24,888 tenants) · make bench-footprint ; mem_limit=96m' },
	{ name: 'realtime (Rust realtime router)', plane: 'realtime', memBasisMib: 2.887, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint EDITION=pro ; mem_limit=128m' },
	{ name: 'tenant-control (Go control plane)', plane: 'control', memBasisMib: 6.562, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=160m' },
	{ name: 'adapter-registry (Go)', plane: 'control', memBasisMib: 8.047, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=192m' },
	{ name: 'orchestrator (Go)', plane: 'control', memBasisMib: 8.832, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=32m' },
	{ name: 'webhook-dispatcher (Go)', plane: 'control', memBasisMib: 10.12, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=96m' },
	{ name: 'function-scheduler (Go)', plane: 'control', memBasisMib: 5.004, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=96m' },
	{ name: 'query-router (TS/Node app plane)', plane: 'app', memBasisMib: 53.36, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=128m' },
	{ name: 'permission-engine (TS/Node ABAC PDP)', plane: 'app', memBasisMib: 56.41, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=128m' },
	{ name: 'storage-router (TS/Node)', plane: 'storage', memBasisMib: 54.64, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=128m' },
	{ name: 'session-service (TS/Node)', plane: 'app', memBasisMib: 65.7, basisKind: 'measured', source: 'artifacts/footprint-essential.json (RSS, essential edition) · make bench-footprint PACKAGE=essential ; mem_limit=128m' },
	{ name: 'schema-service (TS/Node)', plane: 'app', memBasisMib: 128, basisKind: 'mem_limit', source: 'docker-compose.yml mem_limit=128m (no measured RSS isolated; sibling Node services measure ~57-70 MiB RSS — treat 128 as the ceiling budget, not a measured floor)' },
	{ name: 'email-service (TS/Node)', plane: 'app', memBasisMib: 57.8, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS) · make bench-footprint PACKAGE=max ; mem_limit=128m' },
	{ name: 'newsletter-service (TS/Node)', plane: 'app', memBasisMib: 66.3, basisKind: 'measured', source: 'artifacts/footprint-essential.json (RSS) · make bench-footprint PACKAGE=essential ; mem_limit=128m' },
	{ name: 'gdpr-service (TS/Node)', plane: 'app', memBasisMib: 65.1, basisKind: 'measured', source: 'artifacts/footprint-essential.json (RSS) · make bench-footprint PACKAGE=essential ; mem_limit=128m' },
	{ name: 'log-service (TS/Node)', plane: 'app', memBasisMib: 69.7, basisKind: 'measured', source: 'artifacts/footprint-essential.json (RSS) · make bench-footprint PACKAGE=essential ; mem_limit=128m' },
	{ name: 'outbox-relay (TS/Node CDC relay)', plane: 'app', memBasisMib: 67.1, basisKind: 'measured', source: 'artifacts/footprint-essential.json (RSS) · make bench-footprint PACKAGE=essential ; mem_limit=256m' },
	{ name: 'analytics-service (TS/Node)', plane: 'app', memBasisMib: 65, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS, max edition) · make bench-footprint PACKAGE=max ; mem_limit=128m' },
	{ name: 'ai-service (TS/Node)', plane: 'app', memBasisMib: 66.4, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS) · make bench-footprint PACKAGE=max ; mem_limit=256m' },
	{ name: 'mongo-api (TS/Node mongo adapter API)', plane: 'app', memBasisMib: 64.6, basisKind: 'measured', source: 'artifacts/footprint-pro.json (RSS) · make bench-footprint PACKAGE=pro ; mem_limit=128m' },
	{ name: 'functions-runtime (TS/Node fn sandbox)', plane: 'app', memBasisMib: 256, basisKind: 'mem_limit', source: 'docker-compose.yml mem_limit=256m (measured state=down/0 MiB in footprint-max.json — runtime is on-demand, not standing; ceiling is the budget, do NOT count as steady-state)' },
	{ name: 'kong (API gateway / edge)', plane: 'gateway', memBasisMib: 102.4, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=1g. footprint-core.json measured 154.3 MiB, essential/pro 118.5 MiB — varies with load/edition.' },
	{ name: 'postgrest (auto-REST edge)', plane: 'gateway', memBasisMib: 12.04, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=128m' },
	{ name: 'waf (edge WAF)', plane: 'gateway', memBasisMib: 61.6, basisKind: 'measured', source: 'artifacts/footprint-essential.json (RSS) · make bench-footprint PACKAGE=essential ; mem_limit=256m (footprint-core.json measured 20.1 MiB cold)' },
	{ name: 'gotrue (auth / GoTrue)', plane: 'control', memBasisMib: 7.891, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=128m' },
	{ name: 'postgres (primary DB)', plane: 'db', memBasisMib: 43.99, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS, holding 24,888 tenants shared_rls) · make bench-footprint ; mem_limit=512m' },
	{ name: 'redis (cache/session store)', plane: 'db', memBasisMib: 4.176, basisKind: 'measured', source: 'artifacts/scale/footprint-live-24888-today.json (RSS) · make bench-footprint ; mem_limit=512m' },
	{ name: 'mysql', plane: 'db', memBasisMib: 63, basisKind: 'measured', source: 'artifacts/footprint-pro.json (RSS, pro edition) · make bench-footprint PACKAGE=pro ; mem_limit=384m' },
	{ name: 'mongo', plane: 'db', memBasisMib: 91, basisKind: 'measured', source: 'artifacts/footprint-pro.json (RSS) · make bench-footprint PACKAGE=pro ; mem_limit=512m' },
	{ name: 'mariadb', plane: 'db', memBasisMib: 8, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS, max edition) · make bench-footprint PACKAGE=max ; mem_limit=384m' },
	{ name: 'mssql', plane: 'db', memBasisMib: 422.5, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS) · make bench-footprint PACKAGE=max ; mem_limit=2g' },
	{ name: 'cockroach', plane: 'db', memBasisMib: 413.9, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS) · make bench-footprint PACKAGE=max ; mem_limit=1g' },
	{ name: 'minio (object storage / S3)', plane: 'storage', memBasisMib: 74.4, basisKind: 'measured', source: 'artifacts/footprint-pro.json (RSS, pro edition) · make bench-footprint PACKAGE=pro ; mem_limit=512m (docker-compose.prod.yml). NB cost driver is GB stored, not this compute RSS.' },
	{ name: 'trino (analytics query engine / JVM)', plane: 'observability', memBasisMib: 684.1, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS, max edition) · make bench-footprint PACKAGE=max ; mem_limit=2g — largest single component' },
	{ name: 'debezium (CDC connector / JVM)', plane: 'observability', memBasisMib: 248.1, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS) · make bench-footprint PACKAGE=max ; mem_limit=384m' },
	{ name: 'iceberg-rest (table catalog / JVM)', plane: 'storage', memBasisMib: 68.8, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS) · make bench-footprint PACKAGE=max ; mem_limit=384m' },
	{ name: 'loki (log aggregation)', plane: 'observability', memBasisMib: 333.5, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS) · make bench-footprint PACKAGE=max ; mem_limit=512m' },
	{ name: 'prometheus (metrics)', plane: 'observability', memBasisMib: 33, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS) · make bench-footprint PACKAGE=max ; mem_limit=512m (docker-compose.prod.yml)' },
	{ name: 'promtail (log shipper)', plane: 'observability', memBasisMib: 56.1, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS) · make bench-footprint PACKAGE=max ; mem_limit=128m (docker-compose.prod.yml)' },
	{ name: 'grafana (dashboards)', plane: 'observability', memBasisMib: 47.7, basisKind: 'measured', source: 'artifacts/footprint-max.json (RSS) · make bench-footprint PACKAGE=max ; mem_limit=256m (docker-compose.prod.yml)' },
];

const componentByName = new Map(COMPONENTS.map((c) => [c.name, c]));

/** Resolve a tier's component-name list to the full CostComponent objects. */
export function componentsFor(tier: Tier): CostComponent[] {
	return tier.componentNames.map((n) => componentByName.get(n)).filter((c): c is CostComponent => Boolean(c));
}

/**
 * The HONEST arithmetic sum of the itemised component rows for a tier — what the
 * rows shown actually add up to. This is DELIBERATELY distinct from the tier's
 * `componentRamSumMib` (the measured live edition floor from footprint-*.json):
 * per-component RSS is sampled across different editions/loads and the live
 * floor also carries JVM engines, db caches and headroom not itemised here, so
 * the floor exceeds the itemised planes. The simulator shows BOTH so the table
 * is auditable (rows sum to the row-sum, not to a number they don't reach).
 */
export function itemisedSumMib(tier: Tier): number {
	return componentsFor(tier).reduce((acc, c) => acc + c.memBasisMib, 0);
}

// ── Hosters — published rate cards, each with source_url + date + confidence. ──
export interface Hoster {
	id: HosterId;
	name: string;
	representativePlan: string;
	ramGb: number;
	vcpu: number;
	flatMonthlyUsd: number;
	usdPerGbRamMonth: number;
	usdPerVcpuMonth: number;
	usdPerGbStorageMonth: number;
	usdPerGbEgress: number;
	sourceUrl: string;
	confidence: 'published' | 'estimated';
	note: string;
}

// The three fully-worked hosters from cost-model.json (Hetzner cheapest /
// Fly.io metered / AWS expensive). The canonical file carries three more
// (Hostinger, DigitalOcean, Railway) that share the same formula and are kept
// only for the cross-hoster spread; the simulator focuses on these three.
export const HOSTERS: Hoster[] = [
	{
		id: 'Hetzner',
		name: 'Hetzner Cloud',
		representativePlan: 'CX22 (cost-optimized shared vCPU)',
		ramGb: 4,
		vcpu: 2,
		flatMonthlyUsd: 4.63,
		usdPerGbRamMonth: 1.16,
		usdPerVcpuMonth: 2.32,
		usdPerGbStorageMonth: 0,
		usdPerGbEgress: 0,
		sourceUrl: 'https://www.bitdoze.com/hetzner-cloud-cost-optimized-plans/',
		confidence: 'published',
		note: 'CX22 = 2 vCPU/4 GB/40 GB NVMe/20 TB traffic, EUR 3.99/mo @ 1.16 = $4.63 flat. Storage+egress bundled (40 GB disk + 20 TB egress; overage ~EUR 1/TB). Larger CX nodes used in tiers are DERIVED-linear from this line and flagged estimated.',
	},
	{
		id: 'Fly.io',
		name: 'Fly.io',
		representativePlan: 'shared-cpu-1x 1GB machine (RAM is a true per-GB add-on)',
		ramGb: 1,
		vcpu: 1,
		flatMonthlyUsd: 5.92,
		usdPerGbRamMonth: 5,
		usdPerVcpuMonth: 2,
		usdPerGbStorageMonth: 0.15,
		usdPerGbEgress: 0.02,
		sourceUrl: 'https://fly.io/docs/about/pricing/',
		confidence: 'published',
		note: 'RAM is a real per-GB line (~$5/GB/30d). usd_per_vcpu=$2 is ESTIMATED. Volume $0.15/GB/mo + egress $0.02/GB NA-EU (NO free allowance post-2025). For Fly, node_monthly is computed PER-GB (ram_gb*5 + vcpu*2), not from the flat plan.',
	},
	{
		id: 'AWS',
		name: 'AWS (EC2 + RDS reference)',
		representativePlan: 'EC2 t3.medium on-demand, us-east-1',
		ramGb: 4,
		vcpu: 2,
		flatMonthlyUsd: 30.37,
		usdPerGbRamMonth: 7.59,
		usdPerVcpuMonth: 15.18,
		usdPerGbStorageMonth: 0.08,
		usdPerGbEgress: 0.09,
		sourceUrl: 'https://www.economize.cloud/resources/aws/pricing/ec2/t3.medium/',
		confidence: 'published',
		note: 't3.medium = 2 vCPU/4 GB = $30.368/mo. EBS gp3 $0.08/GB/mo; egress $0.09/GB first 10 TB. RDS db.t3.medium single-AZ = $52.56/mo (~1.7x raw EC2) is the managed-Postgres comparator. Larger t3 nodes in tiers are DERIVED-linear and flagged estimated.',
	},
];

export const hosterById = new Map(HOSTERS.map((h) => [h.id, h]));

// ── Density — the moat. AT-REST holding cost vs UNDER-LOAD working set. ────────
export const DENSITY = {
	tenants: 24888,
	dataPlaneRamMib: 2.918,
	perTenantMarginalMib: 0.0001173,
	perTenantUnderloadMib: 0.003,
	source: 'artifacts/scale/footprint-live-24888-today.json (2026-06-15, RSS 2.918 MiB / 24,888 tenants, pools_open=0). THE MOAT: at-rest per-tenant marginal = 2.918/24888 ≈ 0.000117 MiB (~0.12 KiB) because pools_open=0 (SHARE_POOLS: pool count independent of tenant count). under-load = ~0.003 MiB/concurrently-loaded tenant (~30 MiB data plane / 10K zipf-concurrent, server_errors=0, multitenant-10000.json).',
} as const;

// ── Tunable factors — each with its artifact-backed default + estimated flag. ──
export interface Factors {
	headroomPct: number;
	overcommit: number;
	defaultMarginPct: number;
	/** ESTIMATED — the single biggest lever on amortized cost. */
	concurrencyPeakFraction: number;
	/** Measured max_sustained_rps before the pool cliff (capacity-essential.json). */
	rpsSinglePoolCeiling: number;
	storageGbPerTenantDefault: Record<TierId, number>;
	egressGbPerTenantDefault: Record<TierId, number>;
}

export const FACTORS: Factors = {
	headroomPct: 0.3,
	overcommit: 0.5,
	defaultMarginPct: 0.6,
	concurrencyPeakFraction: 0.1,
	rpsSinglePoolCeiling: 400,
	storageGbPerTenantDefault: { nano: 0.1, basic: 0.5, essential: 1.0, pro: 5.0, max: 20.0 },
	egressGbPerTenantDefault: { nano: 0.5, basic: 1.0, essential: 2.0, pro: 10.0, max: 50.0 },
};

// Which factor defaults are NOT artifact-backed (the simulator flags these so a
// number is never asserted as measured when it is reasoned).
export const ESTIMATED_FACTORS = new Set<keyof Factors>([
	'concurrencyPeakFraction',
	'storageGbPerTenantDefault',
	'egressGbPerTenantDefault',
]);

// ── Tiers — the offer ladder, each with its measured edition floor. ───────────
export interface Tier {
	id: TierId;
	name: string;
	rps: number;
	maxMounts: number;
	engines: number;
	tenancy: string;
	editionRamIdleMib: number;
	editionRamIdleSource: string;
	componentNames: string[];
	componentRamSumMib: number;
	/** Realistic packing cap + the binding constraint that sets it. */
	tenantsPerNode: { value: number; nodeRamGb: number; bindingConstraint: 'rps-bound' | 'RAM-bound' | 'proven-cap-10K'; basis: string };
	infraCostUsdMonth: Record<HosterId, number>;
	suggestedPriceUsdMonth: number;
	marginPct: number;
	/** "what this offer costs us, and why" — one honest paragraph per tier. */
	explainer: string;
	source: string;
}

export const TIERS: Tier[] = [
	{
		id: 'nano',
		name: 'Nano',
		rps: 50,
		maxMounts: 1,
		engines: 1,
		tenancy: 'single-tenant (one app per binary; graduates to basic with zero rewrites)',
		editionRamIdleMib: 2.008,
		editionRamIdleSource: 'artifacts/nano-vs-pocketbase.json (nano.rss=2.008 MiB, image_mb=4.9) — single static musl binary; reproduce with make nano-build + footprint. vs PocketBase 13.11 MiB RSS / 30.1 MB binary same box.',
		componentNames: [], // single static binary, not a compose edition — see explainer
		componentRamSumMib: 2.008,
		tenantsPerNode: {
			value: 80,
			nodeRamGb: 1,
			bindingConstraint: 'rps-bound',
			basis: 'rps-bound (not RAM): ceiling/tier_rps = 400/50 = 8 simultaneous-peak × (1/0.10) = 80. RAM at-rest would allow ~6.1M on a 1 GB node, so rps binds first by ~5 orders of magnitude. Single-tenant tier: dedicated = 1; 80 is the amortized cap.',
		},
		infraCostUsdMonth: { Hetzner: 1.16, 'Fly.io': 7.0, AWS: 7.59 },
		suggestedPriceUsdMonth: 0,
		marginPct: 0,
		explainer:
			'Nano is one 4.9 MB static binary holding ~2 MiB of RAM — its cost to us is a rounding error (≈$1.16/mo of a Hetzner 1 GB-class allocation, or ~$0.04–0.37/tenant amortized). It ships at $0 by product design: it is the free acquisition tier (the loss-leader), so margin is intentionally 0, with the amortized infra treated as customer-acquisition cost.',
		source: 'packages.json packages.nano + nano-vs-pocketbase.json',
	},
	{
		id: 'basic',
		name: 'Basic',
		rps: 100,
		maxMounts: 1,
		engines: 2,
		tenancy: 'single-tenant (a private single-app BaaS on a Pi or $5 VPS)',
		editionRamIdleMib: 309.8,
		editionRamIdleSource: 'artifacts/footprint-basic.json (ram_mib_total=309.8, bar_mib=512, verdict=pass) · make bench-footprint PACKAGE=basic',
		componentNames: [
			'waf (edge WAF)', 'kong (API gateway / edge)', 'postgres (primary DB)', 'gotrue (auth / GoTrue)', 'postgrest (auto-REST edge)', 'redis (cache/session store)',
			'adapter-registry (Go)', 'tenant-control (Go control plane)', 'webhook-dispatcher (Go)',
			'orchestrator (Go)', 'data-plane-router (Rust data plane)',
		],
		componentRamSumMib: 309.8,
		tenantsPerNode: {
			value: 40,
			nodeRamGb: 1,
			bindingConstraint: 'rps-bound',
			basis: 'rps-bound: 400/100 = 4 simultaneous × (1/0.10) = 40. Edition floor 309.8 MiB fits a 1 GB node (716.8 MiB avail after 30% headroom). RAM at-rest allows ~3.5M; rps binds first. Single-tenant tier: dedicated = 1; 40 is the amortized cap.',
		},
		infraCostUsdMonth: { Hetzner: 1.16, 'Fly.io': 7.0, AWS: 7.59 },
		suggestedPriceUsdMonth: 2.9,
		marginPct: 0.6,
		explainer:
			'Basic is a Node-free data plane (Kong → Rust → engine) that fits a 1 GB node at a 309.8 MiB measured floor. Dedicated on Hetzner it costs us $1.16/mo → suggested $2.90 at a 60% margin; it literally runs cheaper than the "$5 VPS" it targets. Amortized across ~40 tenants the floor drops to roughly $0.07–0.80/tenant.',
		source: 'packages.json packages.basic + footprint-basic.json',
	},
	{
		id: 'essential',
		name: 'Essential',
		rps: 200,
		maxMounts: 2,
		engines: 2,
		tenancy: 'single-tenant (one full-feature product)',
		editionRamIdleMib: 821.7,
		editionRamIdleSource: 'artifacts/footprint-essential.json (ram_mib_total=821.7, bar_mib=1024, verdict=pass) · make bench-footprint PACKAGE=essential',
		componentNames: [
			'waf (edge WAF)', 'kong (API gateway / edge)', 'postgres (primary DB)', 'gotrue (auth / GoTrue)', 'postgrest (auto-REST edge)', 'redis (cache/session store)',
			'adapter-registry (Go)', 'tenant-control (Go control plane)', 'webhook-dispatcher (Go)',
			'orchestrator (Go)', 'data-plane-router (Rust data plane)',
			'query-router (TS/Node app plane)', 'permission-engine (TS/Node ABAC PDP)', 'schema-service (TS/Node)',
		],
		componentRamSumMib: 821.7,
		tenantsPerNode: {
			value: 20,
			nodeRamGb: 2,
			bindingConstraint: 'rps-bound',
			basis: 'rps-bound: 400/200 = 2 simultaneous × (1/0.10) = 20. Edition floor 821.7 MiB does NOT fit a 1 GB node (only 716.8 MiB after headroom) → MUST use ≥2 GB. On 2 GB RAM allows ~5.2M at rest; rps binds. Single-tenant: dedicated = 1; 20 amortized.',
		},
		infraCostUsdMonth: { Hetzner: 2.31, 'Fly.io': 12.0, AWS: 15.19 },
		suggestedPriceUsdMonth: 7.7,
		marginPct: 0.7,
		explainer:
			'Essential adds the TS app plane (aggregate / count-sum-group-by, field masks, automations, webhooks, email, GDPR) and crosses the 1 GB line at 821.7 MiB, so it needs a 2 GB node. Dedicated Hetzner cost floor $2.31/mo → suggested $7.70 (70% tiered margin). Amortized across ~20 tenants: roughly $0.29–2.55/tenant depending on the hoster. Real retail is value-based above this cost floor.',
		source: 'packages.json packages.essential + footprint-essential.json',
	},
	{
		id: 'pro',
		name: 'Pro',
		rps: 400,
		maxMounts: 10,
		engines: 7,
		tenancy: "one customer's SaaS, amortizable across a shared host (< $1/tenant per packages.json)",
		editionRamIdleMib: 1188.4,
		editionRamIdleSource: 'artifacts/footprint-pro.json (ram_mib_total=1188.4, bar_mib=1500, verdict=pass) · make bench-footprint PACKAGE=pro',
		componentNames: [
			'waf (edge WAF)', 'kong (API gateway / edge)', 'postgres (primary DB)', 'gotrue (auth / GoTrue)', 'postgrest (auto-REST edge)', 'redis (cache/session store)',
			'adapter-registry (Go)', 'tenant-control (Go control plane)', 'webhook-dispatcher (Go)',
			'orchestrator (Go)', 'data-plane-router (Rust data plane)',
			'query-router (TS/Node app plane)', 'permission-engine (TS/Node ABAC PDP)', 'schema-service (TS/Node)',
			'mysql', 'mongo', 'mongo-api (TS/Node mongo adapter API)', 'realtime (Rust realtime router)',
			'minio (object storage / S3)', 'storage-router (TS/Node)',
		],
		componentRamSumMib: 1188.4,
		tenantsPerNode: {
			value: 10,
			nodeRamGb: 2,
			bindingConstraint: 'rps-bound',
			basis: 'rps-bound: 400/400 = 1 simultaneous × (1/0.10) = 10. Edition floor 1188.4 MiB needs >1 GB (fits 2 GB: 1434.8 MiB avail). RAM at rest would allow ~2.1M; rps binds hardest here. The packages.json "<$1/tenant amortized" matches on Hetzner: $2.31 node ÷ 10 = $0.23.',
		},
		infraCostUsdMonth: { Hetzner: 2.31, 'Fly.io': 12.0, AWS: 15.19 },
		suggestedPriceUsdMonth: 11.55,
		marginPct: 0.8,
		explainer:
			'Pro is the multi-engine tier (6 live engines, realtime WebSocket CDC + object storage, batch + transactions) on a 2 GB node at a 1188.4 MiB floor. Dedicated Hetzner cost floor $2.31/mo → suggested $11.55 (80% tiered margin). Amortized across ~10 tenants its floor is $0.23/tenant on Hetzner — which CONFIRMS the "<$1/tenant" claim — but FLIPS to $2.15/tenant on Fly and $7.05 on AWS. The hoster choice, not the code, decides the unit economics here.',
		source: 'packages.json packages.pro + footprint-pro.json',
	},
	{
		id: 'max',
		name: 'Max',
		rps: 800,
		maxMounts: 50,
		engines: 9,
		tenancy: 'MULTI-TENANT PLATFORM (the 10K-tenant validation backs the density story; ONLY tier sold as multi-tenant)',
		editionRamIdleMib: 3634.0,
		editionRamIdleSource: 'artifacts/footprint-max.json (ram_mib_total=3634.0, bar_mib=3700, verdict=pass) · make bench-footprint PACKAGE=max',
		componentNames: [
			'waf (edge WAF)', 'kong (API gateway / edge)', 'postgres (primary DB)', 'gotrue (auth / GoTrue)', 'postgrest (auto-REST edge)', 'redis (cache/session store)',
			'adapter-registry (Go)', 'tenant-control (Go control plane)', 'webhook-dispatcher (Go)',
			'orchestrator (Go)', 'data-plane-router (Rust data plane)',
			'query-router (TS/Node app plane)', 'permission-engine (TS/Node ABAC PDP)', 'schema-service (TS/Node)',
			'mysql', 'mongo', 'mongo-api (TS/Node mongo adapter API)', 'realtime (Rust realtime router)',
			'minio (object storage / S3)', 'storage-router (TS/Node)',
			'trino (analytics query engine / JVM)', 'iceberg-rest (table catalog / JVM)', 'debezium (CDC connector / JVM)',
			'analytics-service (TS/Node)', 'ai-service (TS/Node)',
			'prometheus (metrics)', 'grafana (dashboards)', 'loki (log aggregation)', 'promtail (log shipper)',
			'function-scheduler (Go)', 'functions-runtime (TS/Node fn sandbox)',
			'mariadb', 'cockroach', 'mssql',
		],
		componentRamSumMib: 3634.0,
		tenantsPerNode: {
			value: 10000,
			nodeRamGb: 8,
			bindingConstraint: 'proven-cap-10K',
			basis: 'THE MULTI-TENANT TIER. Edition floor 3634 MiB needs ≥8 GB (5734.4 MiB avail after headroom). At-rest RAM allows ~1.9M tenants; UNDER LOAD the PROVEN figure is 10,000 concurrent tenants in ~30 MiB data plane (multitenant-10000.json, server_errors=0, REQUIRES SHARE_POOLS). We cap at the proven 10,000 (m46 headline), NOT the theoretical millions.',
		},
		infraCostUsdMonth: { Hetzner: 7.0, 'Fly.io': 48.0, AWS: 60.74 },
		suggestedPriceUsdMonth: 46.67,
		marginPct: 0.85,
		explainer:
			'Max is the multi-tenant platform — every engine, analytics (Trino + Iceberg), AI, functions, observability — on an 8 GB node at a 3634 MiB floor. As a private dedicated stack its cost floor is $7/mo on Hetzner → $46.67 (85% tiered margin). But its real story is density: split across the PROVEN 10,000 tenants the compute floor is ~$0.0007/tenant on Hetzner. On AWS that compute is still ~$0.006, yet storage ($1.60) + egress ($4.50) DOMINATE at $6.11/tenant — at moat density it is bandwidth, not RAM, that sets the floor. Per-tenant retail is the published tier rate; margin is enormous at density.',
		source: 'packages.json packages.max + footprint-max.json + artifacts/bench/multitenant-10000.json (m46)',
	},
];

export const tierById = new Map(TIERS.map((t) => [t.id, t]));

// ── Honesty banners the simulator must surface (cost-model.json simulator_contract). ──
export const HONESTY_BANNERS: string[] = [
	'The per-tenant density moat requires DATA_PLANE_SHARE_POOLS=1 (a scale overlay, not the base-compose default). Without it, a 10K-zipf load thrashes the pool LRU → ~12% 5xx (multitenant-10000-nosharepools-today.json).',
	'The Pro "< $1/tenant" claim holds on Hetzner ($0.23) but FLIPS on Fly ($2.15) and AWS ($7.05) — the hoster choice decides the unit economics.',
	'At Max density on AWS, egress + storage (not RAM) dominate the per-tenant floor ($6.11/tenant vs $0.006 compute).',
	`Every price is a dated snapshot read ${AS_OF}. Cloud prices drift (Hetzner raised 2026-04-01; Fly killed its free tier; AWS revises egress) — re-fetch before relying on them.`,
	'Nano is a deliberate $0 free tier (the acquisition loss-leader), so its margin is 0 by design, not a model error.',
	'concurrency_peak_fraction (10%, ESTIMATED) is the single biggest tunable: it sets how many single-tenant apps pack onto one node. At 5% peak, tenants-per-node halves and amortized cost doubles.',
];

// ── Pure cost-math (no DOM, dependency-free) — the simulator + the m145 gate
// both call these, so the numbers shown == the numbers gated. ─────────────────

/**
 * node_monthly — the monthly cost of the NODE that holds a tier's edition.
 *
 * The authoritative per-(tier × hoster) node cost is the canonical constant
 * `tier.infraCostUsdMonth[hoster]` (mirrored byte-for-byte from
 * cost-model.json's `infra_cost_usd_month`, which the m145 gate guards). Those
 * are sized to the tier's `node_ram_gb`:
 *   • Fly.io  = ram_gb×$5 + vcpu×$2 (RAM is a true per-GB add-on)
 *   • AWS     = ram_gb×$7.59 (whole-instance allocation, derived-linear)
 *   • Hetzner = ram_gb×$1.16 for nano..pro; max ($7.0) is a published
 *     cost-optimized estimate above CX22 (flagged estimated in the JSON).
 * Returning the constant guarantees the simulator == the gate. (Node RAM is not
 * a user-tunable input in this widget, so there is no override path to diverge.)
 */
export function nodeMonthly(tier: Tier, hoster: Hoster): number {
	return tier.infraCostUsdMonth[hoster.id];
}

/** AT-REST node RAM: component floor + N × per-tenant marginal. */
export function nodeRamNeededAtRest(componentSumMib: number, tenants: number, f: Factors = FACTORS): number {
	void f;
	return componentSumMib + tenants * DENSITY.perTenantMarginalMib;
}

/** UNDER-LOAD node RAM: floor + (N × peak-fraction) × per-tenant working set. */
export function nodeRamNeededUnderLoad(componentSumMib: number, tenants: number, f: Factors = FACTORS): number {
	return componentSumMib + tenants * f.concurrencyPeakFraction * DENSITY.perTenantUnderloadMib;
}

/** Realistic rps-bound packing: (ceiling/tier_rps) / peak-fraction. */
export function tenantsPerNodeRps(tier: Tier, f: Factors = FACTORS): number {
	return Math.floor(tier.rps > 0 ? f.rpsSinglePoolCeiling / tier.rps / f.concurrencyPeakFraction : 0);
}

/** AT-REST RAM-bound packing ceiling (astronomically large — the moat). */
export function tenantsPerNodeRam(tier: Tier, hoster: Hoster, nodeRamGb: number, f: Factors = FACTORS): number {
	const availMib = nodeRamGb * 1024 * (1 - f.headroomPct) - tier.editionRamIdleMib;
	if (availMib <= 0) return 0;
	void hoster;
	return Math.floor(availMib / DENSITY.perTenantMarginalMib);
}

/**
 * Realistic tenants-per-node.
 *
 * For the single-tenant tiers (nano/basic/essential/pro) the binding constraint
 * is rps fair-share (the measured 400-rps single-pool ceiling ÷ the tier rps ÷
 * the peak fraction), bounded by the at-rest RAM ceiling: min(rps, RAM).
 *
 * For `max` — the ONLY multi-tenant tier — rps does NOT bind (max assumes the
 * per-tier DATA_PLANE_MAX_POOLS policy + supavisor multiplexing), so the cap is
 * the PROVEN 10,000-tenant validation (multitenant-10000.json / m46), bounded by
 * the (astronomically larger) at-rest RAM ceiling — NOT the rps figure. This
 * matches cost-model.json's tiers[max].tenants_per_node.value = 10000 and its
 * max worked examples (÷10000).
 */
export function tenantsPerNode(tier: Tier, hoster: Hoster, nodeRamGb: number, f: Factors = FACTORS): number {
	const byRam = tenantsPerNodeRam(tier, hoster, nodeRamGb, f);
	if (tier.id === 'max') return Math.min(10000, byRam);
	return Math.min(tenantsPerNodeRps(tier, f), byRam);
}

export interface CostBreakdown {
	nodeMonthly: number;
	storageMonthly: number;
	egressMonthly: number;
	/** dedicated = whole node; amortized = node ÷ tenants. */
	nodeShare: number;
	infraCost: number;
	suggestedPrice: number;
	marginPct: number;
	tenantsPerNode: number;
}

export interface CostInputs {
	tier: Tier;
	hoster: Hoster;
	model: CostModel;
	nodeRamGb: number;
	vcpu: number;
	storageGbPerTenant: number;
	egressGbPerTenant: number;
	factors?: Factors;
}

/** The single cost function the UI and the gate both use. */
export function computeCost(inp: CostInputs): CostBreakdown {
	const f = inp.factors ?? FACTORS;
	const node = nodeMonthly(inp.tier, inp.hoster);
	const storage = inp.storageGbPerTenant * inp.hoster.usdPerGbStorageMonth;
	const egress = inp.egressGbPerTenant * inp.hoster.usdPerGbEgress;
	const tpn = tenantsPerNode(inp.tier, inp.hoster, inp.nodeRamGb, f);
	const nodeShare = inp.model === 'amortized' && tpn > 0 ? node / tpn : node;
	const infraCost = nodeShare + storage + egress;
	// Nano is the deliberate $0 free tier: price stays 0, margin 0, regardless.
	const suggestedPrice = inp.tier.id === 'nano' ? 0 : infraCost / (1 - f.defaultMarginPct);
	const marginPct = suggestedPrice > 0 ? (suggestedPrice - infraCost) / suggestedPrice : 0;
	return {
		nodeMonthly: node,
		storageMonthly: storage,
		egressMonthly: egress,
		nodeShare,
		infraCost,
		suggestedPrice,
		marginPct,
		tenantsPerNode: tpn,
	};
}
