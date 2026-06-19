// Deterministic tenant population (fixed PRNG seed → stable visual, testable).
import { GALAXY_COLORS } from '../../data/galaxy-palette.ts';
import type { EngineId, IsolationId, TenantNode, TierId } from './types.ts';

export function mulberry32(seed: number): () => number {
	let a = seed >>> 0;
	return () => {
		a |= 0;
		a = (a + 0x6d2b79f5) | 0;
		let t = Math.imul(a ^ (a >>> 15), 1 | a);
		t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

// Node colours come from the single galaxy palette (src/data/galaxy-palette.ts),
// which mirrors the MAXIMALISM accents — so the drifting nodes match the site.
const ENGINE_COLORS: Record<EngineId, string> = GALAXY_COLORS.engines;
const TIER_COLORS: Record<TierId, string> = GALAXY_COLORS.tiers;

const TIER_RADIUS: Record<TierId, number> = {
	nano: 2.1,
	basic: 2.7,
	essential: 3.3,
	pro: 4.1,
	max: 5.2,
};

// Realistic population: most tenants are tiny.
const TIER_COUNTS: Array<[TierId, number]> = [
	['nano', 44],
	['basic', 30],
	['essential', 22],
	['pro', 16],
	['max', 8],
];

const PRO_ENGINES: EngineId[] = ['postgres', 'mysql', 'mongodb', 'redis', 'sqlite', 'cockroach'];
const MAX_ENGINES: EngineId[] = [...PRO_ENGINES, 'mssql', 'http'];

const NAME_A = ['lumen', 'atlas', 'ferro', 'quill', 'vega', 'sable', 'koral', 'nimbus', 'tessa', 'orbit', 'pico', 'helix', 'mirek', 'cobalt', 'fable', 'astra', 'ronde', 'mosaic', 'pluma', 'verde'];
const NAME_B = ['labs', 'shop', 'kit', 'works', 'app', 'cloud', 'desk', 'flow', 'base', 'forms', 'crm', 'notes', 'pay', 'track', 'mail', 'docs', 'feed', 'cast', 'board', 'api'];

function pickEngines(tier: TierId, rand: () => number): EngineId[] {
	if (tier === 'nano') return rand() < 0.25 ? ['sqlite', 'postgres'] : ['sqlite'];
	if (tier === 'basic') return rand() < 0.5 ? ['sqlite', 'postgres'] : ['postgres'];
	if (tier === 'essential') return rand() < 0.4 ? ['postgres', 'sqlite'] : ['postgres'];
	const pool = tier === 'pro' ? PRO_ENGINES : MAX_ENGINES;
	const n = tier === 'pro' ? 2 + Math.floor(rand() * 2) : 3 + Math.floor(rand() * 2);
	const picked: EngineId[] = [];
	while (picked.length < n) {
		const e = pool[Math.floor(rand() * pool.length)] as EngineId;
		if (!picked.includes(e)) picked.push(e);
	}
	return picked;
}

function pickIsolation(rand: () => number): IsolationId {
	const v = rand();
	if (v < 0.5) return 'shared_rls';
	if (v < 0.7) return 'schema_per_tenant';
	if (v < 0.85) return 'db_per_tenant';
	return 'tenant_owned';
}

export function seedTenants(seed = 42): TenantNode[] {
	const rand = mulberry32(seed);
	const nodes: TenantNode[] = [];
	let id = 0;
	for (const [tier, count] of TIER_COUNTS) {
		for (let i = 0; i < count; i += 1) {
			const engines = pickEngines(tier, rand);
			const name = `${NAME_A[Math.floor(rand() * NAME_A.length)]}-${NAME_B[Math.floor(rand() * NAME_B.length)]}`;
			nodes.push({
				id,
				name,
				tier,
				engines,
				isolation: pickIsolation(rand),
				x: 0,
				y: 0,
				vx: 0,
				vy: 0,
				tx: 0,
				ty: 0,
				r: TIER_RADIUS[tier] * (0.88 + rand() * 0.3),
				rScale: 1,
				color: ENGINE_COLORS[engines[0] as EngineId],
				tierColor: TIER_COLORS[tier],
				phase: rand() * Math.PI * 2,
				delay: 0,
				z: 0,
				tz: 0,
				spin: 0,
				spinSpeed: 0,
				origin: false,
			});
			id += 1;
		}
	}
	// Pseudo-3D cube attributes are drawn from the PRNG *after* the whole
	// population loop, so the existing 120-node fingerprint (name / tier / engines
	// / r / phase) stays byte-identical and the seed-determinism test holds.
	for (const node of nodes) {
		node.spin = rand() * Math.PI * 2;
		node.spinSpeed = 0.15 + rand() * 0.25;
	}
	// The first max-tier tenant is the bright "origin" cube the genesis state
	// collapses toward — the "it started with one backend" beat.
	const originNode = nodes.find((node) => node.tier === 'max');
	if (originNode) originNode.origin = true;
	return nodes;
}
