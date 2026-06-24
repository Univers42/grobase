// Shared galaxy types. Keep this file (and everything layouts.test.ts pulls
// in) erasable-TS only — the unit tests run via `node --experimental-strip-types`.
export type TierId = 'nano' | 'basic' | 'essential' | 'pro' | 'max';
export type EngineId =
	| 'postgres'
	| 'mysql'
	| 'mongodb'
	| 'sqlite'
	| 'redis'
	| 'cockroach'
	| 'mssql'
	| 'http';
export type IsolationId = 'shared_rls' | 'schema_per_tenant' | 'db_per_tenant' | 'tenant_owned';
// Narrative morph states, in scroll order. NOTE: 'bigbang' is intentionally NOT
// in this union (nor in ALL_STATES): the explosion is an imperative, time-boxed
// burst (bigbang.ts), not a layout — keeping it out is what lets layouts.test.ts
// keep asserting in-band targets + links>0 for every state.
export type LayoutState =
	| 'nebula'
	| 'genesis'
	| 'engines'
	| 'growth'
	| 'planes'
	| 'tiers'
	| 'isolation'
	| 'bigbang-armed'
	| 'cta';

export interface TenantNode {
	id: number;
	name: string;
	tier: TierId;
	engines: EngineId[];
	isolation: IsolationId;
	/** current position (CSS px) */
	x: number;
	y: number;
	vx: number;
	vy: number;
	/** morph target */
	tx: number;
	ty: number;
	/** base radius (CSS px); layouts may scale it via rScale */
	r: number;
	rScale: number;
	color: string;
	tierColor: string;
	/** per-node drift phase */
	phase: number;
	/** morph stagger delay (ms after state change) */
	delay: number;
	/** pseudo-3D depth (CSS px): physics springs z → tz. Default 0 (flat). */
	z: number;
	tz: number;
	/** cube tumble: current angle (rad) + speed (rad/s) — drives face shading */
	spin: number;
	spinSpeed: number;
	/** the single bright "origin" cube the genesis state collapses toward */
	origin: boolean;
}

export interface LayoutResult {
	/** packed targets: [x0, y0, x1, y1, …] */
	targets: Float64Array;
	/** per-node radius scale (the "expand/shrink by context") */
	rScales: Float64Array;
	/** per-node target depth (pseudo-3D); physics springs node.z → tz */
	tzs: Float64Array;
	/** node-index pairs to draw as links */
	links: Array<[number, number]>;
	/** overall constellation scale, for reference/tests */
	scale: number;
}

// ── pseudo-3D camera (camera.ts) ────────────────────────────────────────────
export interface Camera {
	yaw: number;
	pitch: number;
	dolly: number;
	targetYaw: number;
	targetPitch: number;
	targetDolly: number;
	/** perpetual ambient-drift phase so the scene never freezes when settled */
	ambient: number;
}

// ── one-shot Big Bang burst (bigbang.ts) ────────────────────────────────────
// Phases run on elapsed = now - t0. 'idle' = not running. 'bigbang' is NEVER a
// LayoutState — the burst is imperative, owned by index.ts, time-boxed (~2.6s).
export type BigBangPhase = 'idle' | 'collapse' | 'flash' | 'expand' | 'condense';

export interface BigBangState {
	active: boolean;
	phase: BigBangPhase;
	/** performance.now() when startBigBang fired */
	t0: number;
	/** deterministic burst seed (mulberry32) */
	seed: number;
	/** particle pool [x, y, vx, vy, life] × count — alloc on expand, null on done */
	particles: Float32Array | null;
	count: number;
	/** 1 = full detonation; ~0.45 under reduced-motion (gentler swirl/eject/zoom) */
	intensity: number;
}
