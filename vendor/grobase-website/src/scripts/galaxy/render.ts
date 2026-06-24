// Canvas2D frame renderer. DPR-aware (capped at 2). Projects every node through
// the shared pseudo-3D camera, depth-sorts (painter's algorithm), draws fogged
// links, then cube (or cheap glow) sprites back-to-front, the burst shards, and
// the highlight ring. All scratch buffers are module-level and reused — zero
// per-frame allocation; zero per-frame gradients/shadowBlur (sprites are cached).
import type { BigBangState, Camera, TenantNode } from './types.ts';
import { glowSprite } from './sprite.ts';
import { cubeSprite } from './cube-sprite.ts';
import { cameraTrig, project, type Projected, type Trig } from './camera.ts';
import { PARTICLE_STRIDE } from './bigbang.ts';

export interface RenderState {
	links: Array<[number, number]>;
	highlight: number; // node index or -1
	/** draw cubes (false → cheap glow path: reduced-motion / first paint) */
	cubes: boolean;
	camera: Camera;
	bigbang: BigBangState | null;
}

const NODE_K = 4.6; // sprite size multiplier (matches the old glow footprint)

// Module-level scratch — allocated once, reused every frame. Zero per-frame alloc:
// trig + projection write into these, never into fresh literals.
const trigScratch: Trig = { sinY: 0, cosY: 0, sinX: 0, cosX: 0 };
const pOut: Projected = { sx: 0, sy: 0, scale: 0, depth: 0 };
let sxBuf = new Float64Array(0);
let syBuf = new Float64Array(0);
let scBuf = new Float64Array(0);
let dpBuf = new Float64Array(0);
let order = new Int32Array(0);

// Pre-baked link-fog strings (12 alpha buckets). The fog is a smooth continuum
// of depth — bucketing kills ~120 per-frame toFixed()/template-string allocs for
// a gradient nobody can distinguish from continuous.
const LINK_FOG: string[] = (() => {
	const arr: string[] = [];
	for (let i = 0; i < 12; i += 1) arr.push(`rgba(148, 163, 198, ${(0.06 + 0.16 * (i / 11)).toFixed(3)})`);
	return arr;
})();

function ensure(n: number): void {
	if (sxBuf.length >= n) return;
	sxBuf = new Float64Array(n);
	syBuf = new Float64Array(n);
	scBuf = new Float64Array(n);
	dpBuf = new Float64Array(n);
	order = new Int32Array(n);
}

/** Last projected screen position of node i — used by the hover hit-test. */
export function projectedScreen(i: number): { x: number; y: number } {
	return { x: sxBuf[i] ?? 0, y: syBuf[i] ?? 0 };
}

export function resizeCanvas(canvas: HTMLCanvasElement): { w: number; h: number } {
	const dpr = Math.min(window.devicePixelRatio || 1, 2);
	const w = window.innerWidth;
	const h = window.innerHeight;
	if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
		canvas.width = Math.round(w * dpr);
		canvas.height = Math.round(h * dpr);
	}
	const ctx = canvas.getContext('2d')!;
	ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
	return { w, h };
}

export function renderFrame(ctx: CanvasRenderingContext2D, nodes: TenantNode[], state: RenderState, w: number, h: number): void {
	ctx.clearRect(0, 0, w, h);
	const n = nodes.length;
	ensure(n);

	const trig = cameraTrig(state.camera, trigScratch);
	for (let i = 0; i < n; i += 1) {
		const node = nodes[i]!;
		project(node.x, node.y, node.z, state.camera, w, h, trig, pOut);
		sxBuf[i] = pOut.sx;
		syBuf[i] = pOut.sy;
		scBuf[i] = pOut.scale;
		dpBuf[i] = pOut.depth;
		order[i] = i;
	}

	// Painter's algorithm: far (low depth) first. Insertion sort — N≈120 and the
	// order is near-sorted frame-to-frame, so this is sub-millisecond.
	for (let i = 1; i < n; i += 1) {
		const v = order[i]!;
		const dv = dpBuf[v]!;
		let j = i - 1;
		while (j >= 0 && dpBuf[order[j]!]! > dv) {
			order[j + 1] = order[j]!;
			j -= 1;
		}
		order[j + 1] = v;
	}

	// Links first, fogged by the nearer endpoint's depth.
	if (state.links.length) {
		ctx.lineWidth = 1;
		for (const [a, b] of state.links) {
			const md = dpBuf[a]! < dpBuf[b]! ? dpBuf[a]! : dpBuf[b]!;
			ctx.strokeStyle = LINK_FOG[(md * 11) | 0]!;
			ctx.beginPath();
			ctx.moveTo(sxBuf[a]!, syBuf[a]!);
			ctx.lineTo(sxBuf[b]!, syBuf[b]!);
			ctx.stroke();
		}
	}

	// Cubes (or cheap glow), back to front, depth-fogged via globalAlpha.
	for (let k = 0; k < n; k += 1) {
		const i = order[k]!;
		const node = nodes[i]!;
		const size = node.r * node.rScale * scBuf[i]! * NODE_K;
		if (size <= 0) continue;
		ctx.globalAlpha = 0.4 + 0.6 * dpBuf[i]!;
		if (state.cubes) {
			const lit = 0.5 + 0.5 * Math.cos(node.spin + state.camera.yaw);
			const bucket = lit <= 0 ? 0 : lit >= 1 ? 4 : (lit * 5) | 0;
			ctx.drawImage(cubeSprite(node.color, bucket), sxBuf[i]! - size / 2, syBuf[i]! - size / 2, size, size);
		} else {
			ctx.drawImage(glowSprite(node.color), sxBuf[i]! - size / 2, syBuf[i]! - size / 2, size, size);
		}
	}
	ctx.globalAlpha = 1;

	// Singularity flashpoint: a bright core at the collapse→detonation transition,
	// drawn on the canvas so even reduced-motion (which skips the CSS strobe) sees
	// the flash. Grows from the late collapse into the flash phase.
	const bb = state.bigbang;
	if (bb && (bb.phase === 'collapse' || bb.phase === 'flash')) {
		const core = glowSprite('#ffffff');
		const grow = bb.phase === 'flash' ? 1 : 0.5;
		const cs = 280 * grow;
		ctx.globalCompositeOperation = 'lighter';
		ctx.globalAlpha = grow;
		ctx.drawImage(core, w / 2 - cs / 2, h / 2 - cs / 2, cs, cs);
		ctx.globalAlpha = 1;
		ctx.globalCompositeOperation = 'source-over';
	}

	// Burst shards: additive glow stamps, projected so the dolly-out spreads them.
	if (bb && bb.particles) {
		const p = bb.particles;
		const spr = glowSprite('#fde047');
		ctx.globalCompositeOperation = 'lighter';
		for (let o = 0; o < p.length; o += PARTICLE_STRIDE) {
			const life = p[o + 4]!;
			if (life <= 0.01) continue;
			project(p[o]!, p[o + 1]!, 0, state.camera, w, h, trig, pOut);
			const s = 10 * pOut.scale * (0.4 + life);
			ctx.globalAlpha = life;
			ctx.drawImage(spr, pOut.sx - s / 2, pOut.sy - s / 2, s, s);
		}
		ctx.globalAlpha = 1;
		ctx.globalCompositeOperation = 'source-over';
	}

	// Highlight ring on the hovered/focused tenant (projected position).
	if (state.highlight >= 0 && state.highlight < n) {
		const i = state.highlight;
		const node = nodes[i]!;
		ctx.strokeStyle = node.tierColor;
		ctx.lineWidth = 1.6;
		ctx.beginPath();
		ctx.arc(sxBuf[i]!, syBuf[i]!, node.r * node.rScale * scBuf[i]! * 3 + 5, 0, Math.PI * 2);
		ctx.stroke();
	}
}
