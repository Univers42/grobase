// Galaxy entry point — AMBIENT MODE.
//
// The galaxy is a calm, decorative backdrop: a single gently-drifting field of
// tenant nodes behind the content. It deliberately does NOT react to scroll and
// has no Big Bang climax — the animation must never compete with reading. It
// stays out of the way: deferred to idle time, paused when the tab is hidden,
// and reduced to a single static frame for prefers-reduced-motion.
import type { LayoutState, TenantNode } from './types.ts';
import { seedTenants } from './seed.ts';
import { computeLayout } from './layouts.ts';
import { applyLayoutTargets, snapToTargets, step } from './physics.ts';
import { renderFrame, resizeCanvas, type RenderState } from './render.ts';
import { createCamera, setCameraForState, stepCamera } from './camera.ts';

// The one calm state the ambient backdrop rests in.
const AMBIENT_STATE: LayoutState = 'nebula';

function init(): void {
	const canvas = document.getElementById('galaxy-canvas') as HTMLCanvasElement | null;
	if (!canvas) return;
	const ctx = canvas.getContext('2d');
	if (!ctx) return;

	const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
	const nodes: TenantNode[] = seedTenants();
	const camera = createCamera();
	const renderState: RenderState = {
		links: [],
		highlight: -1,
		cubes: true,
		camera,
		bigbang: null,
	};
	// Test-only telemetry: confirms the backdrop initialised. Harmless decorative global.
	(window as unknown as Record<string, unknown>).__galaxyState = AMBIENT_STATE;

	let { w, h } = resizeCanvas(canvas);
	let running = false;
	let lastTime = 0;

	const drawOnce = () => renderFrame(ctx, nodes, renderState, w, h);

	const settle = (instant: boolean) => {
		// A very gentle camera pose for the ambient state — never a hard swing.
		setCameraForState(camera, AMBIENT_STATE, reducedMotion ? 0.25 : 0.5);
		const layout = computeLayout(AMBIENT_STATE, nodes, w, h);
		applyLayoutTargets(nodes, layout.targets, layout.rScales, layout.tzs, performance.now());
		renderState.links = layout.links;
		if (instant) {
			snapToTargets(nodes, performance.now());
			for (let i = 0; i < 90; i += 1) stepCamera(camera, 16);
			drawOnce();
		}
	};

	const frame = (time: number) => {
		if (!running) return;
		const dt = lastTime === 0 ? 16 : time - lastTime;
		lastTime = time;
		stepCamera(camera, dt);
		step(nodes, dt, time); // the calm spring + drift — the only motion
		drawOnce();
		requestAnimationFrame(frame);
	};

	const start = () => {
		if (running) return;
		running = true;
		lastTime = 0;
		requestAnimationFrame(frame);
	};
	const stop = () => {
		running = false;
	};

	settle(true);
	// Reduced motion: one static frame, no rAF loop at all.
	if (!reducedMotion) start();

	let resizeTimer = 0;
	window.addEventListener('resize', () => {
		window.clearTimeout(resizeTimer);
		resizeTimer = window.setTimeout(() => {
			({ w, h } = resizeCanvas(canvas));
			settle(true);
		}, 160);
	});

	document.addEventListener('visibilitychange', () => {
		if (document.hidden) stop();
		else if (!reducedMotion) start();
	});
}

// Defer init off the critical path (the H1 is the LCP element, not the galaxy).
if (document.getElementById('galaxy-canvas')) {
	if (typeof window.requestIdleCallback === 'function') {
		window.requestIdleCallback(() => init(), { timeout: 1500 });
	} else {
		setTimeout(init, 300);
	}
}
