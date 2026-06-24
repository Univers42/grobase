// Unit tests for the pure layout functions.
// Run: npm test  (node --experimental-strip-types --test, inside Docker)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { seedTenants } from './seed.ts';
import { ALL_STATES, computeLayout } from './layouts.ts';

const W = 1280;
const H = 800;

test('seed is deterministic', () => {
	const a = seedTenants();
	const b = seedTenants();
	assert.equal(a.length, b.length);
	assert.equal(a.length, 120);
	for (let i = 0; i < a.length; i += 1) {
		assert.equal(a[i]!.name, b[i]!.name);
		assert.equal(a[i]!.tier, b[i]!.tier);
		assert.deepEqual(a[i]!.engines, b[i]!.engines);
		// Pin the full visual fingerprint: r/phase are drawn in the population loop,
		// spin after it — all must stay byte-identical across calls.
		assert.equal(a[i]!.r, b[i]!.r);
		assert.equal(a[i]!.phase, b[i]!.phase);
		assert.equal(a[i]!.spin, b[i]!.spin);
	}
});

test('every layout produces finite, in-bounds targets for every node', () => {
	const nodes = seedTenants();
	for (const state of ALL_STATES) {
		const layout = computeLayout(state, nodes, W, H);
		assert.equal(layout.targets.length, nodes.length * 2, `${state}: target count`);
		for (let i = 0; i < layout.targets.length; i += 1) {
			const v = layout.targets[i]!;
			assert.ok(Number.isFinite(v), `${state}: target ${i} is finite`);
		}
		for (let i = 0; i < nodes.length; i += 1) {
			const x = layout.targets[2 * i]!;
			const y = layout.targets[2 * i + 1]!;
			assert.ok(x > -W * 0.2 && x < W * 1.2, `${state}: node ${i} x in viewport band (${x})`);
			assert.ok(y > -H * 0.2 && y < H * 1.2, `${state}: node ${i} y in viewport band (${y})`);
		}
	}
});

test('layouts are deterministic', () => {
	const nodes = seedTenants();
	for (const state of ALL_STATES) {
		const a = computeLayout(state, nodes, W, H);
		const b = computeLayout(state, nodes, W, H);
		assert.deepEqual(Array.from(a.targets), Array.from(b.targets), `${state}: stable targets`);
	}
});

test('links reference valid node indices and are deduplicated', () => {
	const nodes = seedTenants();
	for (const state of ALL_STATES) {
		const { links } = computeLayout(state, nodes, W, H);
		assert.ok(links.length > 0, `${state}: has links`);
		const seen = new Set<string>();
		for (const [a, b] of links) {
			assert.ok(a >= 0 && a < nodes.length && b >= 0 && b < nodes.length, `${state}: link in range`);
			assert.notEqual(a, b, `${state}: no self-links`);
			const key = a < b ? `${a}-${b}` : `${b}-${a}`;
			assert.ok(!seen.has(key), `${state}: no duplicate links`);
			seen.add(key);
		}
	}
});

test('rScales: planes layout shrinks the rust band and grows the ts band', () => {
	const nodes = seedTenants();
	const { rScales } = computeLayout('planes', nodes, W, H);
	const values = new Set(Array.from(rScales));
	assert.ok(values.has(1.75) && values.has(0.5), 'both heavy and featherweight bands present');
});

test('cta layout pulls the constellation tight (scale 0.5)', () => {
	const nodes = seedTenants();
	const layout = computeLayout('cta', nodes, W, H);
	assert.equal(layout.scale, 0.5);
	// All targets inside the middle half of the viewport.
	for (let i = 0; i < nodes.length; i += 1) {
		const x = layout.targets[2 * i]!;
		const y = layout.targets[2 * i + 1]!;
		assert.ok(Math.abs(x - W / 2) < W * 0.3, 'x converges');
		assert.ok(Math.abs(y - H / 2) < H * 0.36, 'y converges');
	}
});

test('every layout produces finite per-node depth (tzs)', () => {
	const nodes = seedTenants();
	for (const state of ALL_STATES) {
		const { tzs } = computeLayout(state, nodes, W, H);
		assert.equal(tzs.length, nodes.length, `${state}: tz count`);
		for (let i = 0; i < tzs.length; i += 1) {
			assert.ok(Number.isFinite(tzs[i]!), `${state}: tz ${i} is finite`);
		}
	}
});

test('genesis collapses ≥90% of nodes into a tight central cluster', () => {
	const nodes = seedTenants();
	const { targets } = computeLayout('genesis', nodes, W, H);
	let inside = 0;
	for (let i = 0; i < nodes.length; i += 1) {
		const dx = targets[2 * i]! - W / 2;
		const dy = targets[2 * i + 1]! - H / 2;
		if (Math.hypot(dx, dy) < W * 0.22) inside += 1;
	}
	assert.ok(inside >= nodes.length * 0.9, `≥90% within central radius (${inside}/${nodes.length})`);
});

test('growth spreads cubes across ≥2 distinct depth planes', () => {
	const nodes = seedTenants();
	const { tzs } = computeLayout('growth', nodes, W, H);
	const planes = new Set(Array.from(tzs));
	assert.ok(planes.size >= 2, `≥2 distinct tz planes (got ${planes.size})`);
});

test('bigbang-armed converges into a tight core like cta', () => {
	const nodes = seedTenants();
	const { targets } = computeLayout('bigbang-armed', nodes, W, H);
	for (let i = 0; i < nodes.length; i += 1) {
		assert.ok(Math.abs(targets[2 * i]! - W / 2) < W * 0.25, 'x converges tight');
	}
});
