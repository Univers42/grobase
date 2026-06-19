// Unit tests for the pure pseudo-3D camera (no DOM, no browser).
// Run: npm test  (node --experimental-strip-types --test, inside Docker)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { seedTenants } from './seed.ts';
import { ALL_STATES, computeLayout } from './layouts.ts';
import { cameraTrig, createCamera, project, setCameraForState, stepCamera } from './camera.ts';

const W = 1280;
const H = 800;

function settled(state: (typeof ALL_STATES)[number]) {
	const cam = createCamera();
	setCameraForState(cam, state);
	for (let i = 0; i < 120; i += 1) stepCamera(cam, 16);
	return cam;
}

test('project is finite + on-scale + depth-bounded for every node in every state', () => {
	const nodes = seedTenants();
	for (const state of ALL_STATES) {
		const layout = computeLayout(state, nodes, W, H);
		const cam = settled(state);
		const trig = cameraTrig(cam);
		for (let i = 0; i < nodes.length; i += 1) {
			const p = project(layout.targets[2 * i]!, layout.targets[2 * i + 1]!, layout.tzs[i]!, cam, W, H, trig);
			assert.ok(Number.isFinite(p.sx) && Number.isFinite(p.sy), `${state} node ${i}: sx/sy finite`);
			assert.ok(Number.isFinite(p.scale) && p.scale > 0, `${state} node ${i}: scale > 0`);
			assert.ok(p.depth >= 0 && p.depth <= 1, `${state} node ${i}: depth in [0,1]`);
		}
	}
});

test('scale is strictly decreasing in z at a neutral camera (farther = smaller)', () => {
	const cam = createCamera(); // yaw = pitch = dolly = 0
	const trig = cameraTrig(cam);
	let prev = Infinity;
	for (let z = -200; z <= 400; z += 50) {
		const p = project(W / 2 + 100, H / 2, z, cam, W, H, trig);
		assert.ok(p.scale < prev, `scale decreases as z grows (z=${z}, scale=${p.scale})`);
		prev = p.scale;
	}
});

test('projection is symmetric about the centre at a neutral camera', () => {
	const cam = createCamera();
	const trig = cameraTrig(cam);
	const a = project(W / 2 + 120, H / 2, 0, cam, W, H, trig);
	const b = project(W / 2 - 120, H / 2, 0, cam, W, H, trig);
	assert.ok(Math.abs(a.sx - W / 2 + (b.sx - W / 2)) < 1e-6, 'x mirrors about centre');
	assert.ok(Math.abs(a.sy - b.sy) < 1e-6, 'y is equal for mirrored x');
});

test('depth sort of projected nodes is a valid permutation of 0..n-1', () => {
	const nodes = seedTenants();
	const layout = computeLayout('growth', nodes, W, H);
	const cam = settled('growth');
	const trig = cameraTrig(cam);
	const depth = nodes.map((_, i) => project(layout.targets[2 * i]!, layout.targets[2 * i + 1]!, layout.tzs[i]!, cam, W, H, trig).depth);
	const order = nodes.map((_, i) => i).sort((p, q) => depth[p]! - depth[q]!);
	const seen = new Set(order);
	assert.equal(seen.size, nodes.length, 'no index dropped or duplicated');
	for (let i = 0; i < nodes.length; i += 1) assert.ok(seen.has(i), `index ${i} present`);
});
