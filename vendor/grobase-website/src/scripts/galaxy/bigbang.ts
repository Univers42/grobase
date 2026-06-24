// The one-shot Big Bang: a self-contained, time-boxed burst FSM. It OWNS node
// motion while active (index.ts calls stepBigBang instead of step), drives the
// camera dolly per phase, and manages a typed-array shard pool that is allocated
// at the expand boundary and freed on done — so the steady-state trace is never
// heavier than the calm galaxy. It is NOT a LayoutState: keeping the explosion
// imperative is what lets layouts.test.ts keep its in-band + links>0 contract.
//
// Choreography reads as "an atom collapses into a singularity, then detonates":
//   arm (spring) → collapse (accelerating inward SPIRAL to a point) → flash
//   (singularity) → expand (radial detonation, camera dolly-OUT) → condense
//   (matter flows into the CTA constellation).
//
// `intensity` (1 default, ~0.45 under reduced-motion) scales the in-fall swirl,
// ejection speed and camera zoom so the moment still happens for everyone but
// stays gentle — and the harsh white strobe is skipped entirely (see index.ts).
import type { BigBangPhase, BigBangState, Camera, TenantNode } from './types.ts';
import { setCameraDolly } from './camera.ts';
import { mulberry32 } from './seed.ts';

export const PARTICLE_STRIDE = 5; // x, y, vx, vy, alpha

const COLLAPSE_MS = 600; // long enough to read the spiral in-fall
const FLASH_MS = 170;
const EXPAND_MS = 1120;
const CONDENSE_MS = 950;
const FLASH_END = COLLAPSE_MS + FLASH_MS; // 770
const EXPAND_END = FLASH_END + EXPAND_MS; // 1890
const TOTAL_MS = EXPAND_END + CONDENSE_MS; // 2840

export function createBigBang(): BigBangState {
	return { active: false, phase: 'idle', t0: 0, seed: 1337, particles: null, count: 0, intensity: 1 };
}

function particleCount(w: number, h: number, deviceMemory: number): number {
	const base = Math.round(Math.min(600, Math.max(160, (w * h) / 2600)));
	return deviceMemory && deviceMemory <= 4 ? Math.min(base, 200) : base;
}

export function startBigBang(state: BigBangState, now: number, w: number, h: number, deviceMemory: number, intensity = 1): void {
	state.active = true;
	state.phase = 'collapse';
	state.t0 = now;
	state.intensity = intensity;
	state.seed = (0x9e3779b1 ^ (Math.floor(w) * 73856093) ^ (Math.floor(h) * 19349663)) >>> 0;
	state.count = particleCount(w, h, deviceMemory);
	state.particles = null; // lazily allocated at the expand boundary
}

// One-time at the flash→expand boundary: give every cube a deterministic radial
// ejection velocity (scaled by intensity) and fill the shard pool.
function ignite(state: BigBangState, nodes: TenantNode[], cx: number, cy: number): void {
	const rand = mulberry32(state.seed);
	const k = state.intensity;
	for (const node of nodes) {
		const a = rand() * Math.PI * 2;
		const sp = (6 + rand() * 14) * k;
		node.x = cx;
		node.y = cy;
		node.z = 0;
		node.vx = Math.cos(a) * sp;
		node.vy = Math.sin(a) * sp;
	}
	const arr = new Float32Array(state.count * PARTICLE_STRIDE);
	for (let i = 0; i < state.count; i += 1) {
		const a = rand() * Math.PI * 2;
		const sp = (3 + rand() * 18) * k;
		const o = i * PARTICLE_STRIDE;
		arr[o] = cx;
		arr[o + 1] = cy;
		arr[o + 2] = Math.cos(a) * sp;
		arr[o + 3] = Math.sin(a) * sp;
		arr[o + 4] = 0.6 + rand() * 0.4; // alpha
	}
	state.particles = arr;
}

function advanceParticles(state: BigBangState, drag: number): void {
	const p = state.particles;
	if (!p) return;
	for (let o = 0; o < p.length; o += PARTICLE_STRIDE) {
		p[o] += p[o + 2]!;
		p[o + 1] += p[o + 3]!;
		p[o + 2] *= drag;
		p[o + 3] *= drag;
	}
}

function fadeParticles(state: BigBangState, localT: number): void {
	const p = state.particles;
	if (!p) return;
	const fade = Math.max(0, 1 - localT);
	for (let o = 0; o < p.length; o += PARTICLE_STRIDE) {
		p[o] += p[o + 2]! * 0.4;
		p[o + 1] += p[o + 3]! * 0.4;
		p[o + 4] *= fade;
	}
}

function phaseFor(t: number): BigBangPhase {
	if (t < COLLAPSE_MS) return 'collapse';
	if (t < FLASH_END) return 'flash';
	if (t < EXPAND_END) return 'expand';
	if (t < TOTAL_MS) return 'condense';
	return 'idle';
}

/** Advance the burst one frame. Moves nodes + particles + camera; ends itself. */
export function stepBigBang(state: BigBangState, nodes: TenantNode[], cam: Camera, now: number, w: number, h: number): void {
	if (!state.active) return;
	const t = now - state.t0;
	const cx = w / 2;
	const cy = h / 2;
	const intensity = state.intensity;
	const phase = phaseFor(t);
	if (phase === 'expand' && state.phase !== 'expand') ignite(state, nodes, cx, cy);
	state.phase = phase;

	if (phase === 'collapse') {
		// Accelerating inward SPIRAL — matter falling into a singularity. The pull
		// (k) and the spin both ramp up as it tightens; a tangential swirl term
		// (dy,-dx) makes the in-fall orbit rather than fall straight.
		setCameraDolly(cam, 360 * intensity);
		const localT = t / COLLAPSE_MS;
		const k = 0.1 + localT * 0.32;
		const swirl = (0.16 + localT * 0.12) * intensity;
		for (const node of nodes) {
			const dx = cx - node.x;
			const dy = cy - node.y;
			node.x += dx * k + dy * swirl;
			node.y += dy * k - dx * swirl;
			node.z += (0 - node.z) * k;
			node.rScale += (0.05 - node.rScale) * (0.12 + localT * 0.25);
			node.spin += node.spinSpeed * (0.3 + localT * 1.4);
		}
		return;
	}
	if (phase === 'flash') {
		// The singularity: everything pinned to a near-point. The bright flashpoint
		// is drawn on the canvas (render.ts) so even reduced-motion sees it.
		setCameraDolly(cam, 380 * intensity);
		for (const node of nodes) {
			node.x += (cx - node.x) * 0.35;
			node.y += (cy - node.y) * 0.35;
			node.rScale += (0.02 - node.rScale) * 0.35;
		}
		return;
	}
	if (phase === 'expand') {
		// Detonation: radial ejection + camera dolly-OUT (expanding-universe feel).
		setCameraDolly(cam, -240 * intensity);
		const drag = 0.984;
		for (const node of nodes) {
			node.x += node.vx;
			node.y += node.vy;
			node.vx *= drag;
			node.vy *= drag;
			node.rScale += (1.25 - node.rScale) * 0.06;
			node.spin += node.spinSpeed * 0.6;
		}
		advanceParticles(state, drag);
		return;
	}
	if (phase === 'condense') {
		// Matter flows into the CTA constellation.
		setCameraDolly(cam, 0);
		const localT = (t - EXPAND_END) / CONDENSE_MS; // 0..1
		const k = 0.06 + localT * 0.12;
		for (const node of nodes) {
			node.x += (node.tx - node.x) * k;
			node.y += (node.ty - node.y) * k;
			node.z += (node.tz - node.z) * k;
			node.rScale += (1 - node.rScale) * k;
			node.spin += node.spinSpeed * 0.1;
		}
		fadeParticles(state, localT);
		return;
	}

	// done — return to the cheap settled loop.
	state.active = false;
	state.phase = 'idle';
	state.particles = null;
}
