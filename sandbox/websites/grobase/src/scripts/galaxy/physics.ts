// physics-lite: no force simulation — a critically-damped pull toward layout
// targets plus a gentle sinusoidal drift so the settled galaxy "breathes".
// Now also eases depth (z → tz) and advances each cube's tumble (spin).
import type { TenantNode } from './types.ts';

const PULL = 4.3; // spring stiffness — softer so a state morph reads as a flowing transition
const DAMP = 0.86; // velocity damping per frame-ish
const DRIFT = 3.6; // breathing amplitude (px) — visible "living" drift even when settled

export function applyLayoutTargets(nodes: TenantNode[], targets: Float64Array, rScales: Float64Array, tzs: Float64Array, now: number): void {
	nodes.forEach((node, i) => {
		node.tx = targets[2 * i]!;
		node.ty = targets[2 * i + 1]!;
		node.rScale = rScales[i]!;
		node.tz = tzs[i]!;
		// Staggered morph: an organic wave instead of a synchronized snap.
		node.delay = now + (i % 64) * 9;
	});
}

/** Place nodes directly on target (first paint + reduced-motion path). */
export function snapToTargets(nodes: TenantNode[], time: number): void {
	for (const node of nodes) {
		node.x = node.tx + Math.sin(time * 0.0004 + node.phase) * DRIFT;
		node.y = node.ty + Math.cos(time * 0.0005 + node.phase * 1.3) * DRIFT;
		node.z = node.tz;
		node.vx = 0;
		node.vy = 0;
	}
}

export function step(nodes: TenantNode[], dtMs: number, now: number): void {
	const dt = Math.min(dtMs, 48) / 1000;
	for (const node of nodes) {
		// Cubes keep tumbling even while staggered in — drives face shading.
		node.spin += node.spinSpeed * dt;
		if (now < node.delay) continue;
		const driftX = Math.sin(now * 0.0004 + node.phase) * DRIFT;
		const driftY = Math.cos(now * 0.0005 + node.phase * 1.3) * DRIFT;
		node.vx = (node.vx + (node.tx + driftX - node.x) * PULL * dt) * DAMP;
		node.vy = (node.vy + (node.ty + driftY - node.y) * PULL * dt) * DAMP;
		node.x += node.vx;
		node.y += node.vy;
		// Depth eases without overshoot (no fog jitter).
		node.z += (node.tz - node.z) * PULL * dt;
	}
}
