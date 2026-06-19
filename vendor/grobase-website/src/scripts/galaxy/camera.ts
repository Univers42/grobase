// Pure pseudo-3D camera — no DOM, no libraries, no matrices. node:test-able
// (camera.test.ts strips types). One shared Camera holds yaw/pitch/dolly,
// critically-damped toward per-state targets; project() turns a world (x,y,z)
// into screen (sx,sy) + scale + depth. sin/cos are computed ONCE per frame by
// the caller (cameraTrig) and passed in, so the per-node inner loop is trig-free
// (~6 mults + 1 divide). This is the whole "3D" budget — no Three.js, no WebGL.
import type { Camera, LayoutState } from './types.ts';

const STIFF = 3.0; // camera spring stiffness (gentle ease toward the target pose)
const FOCAL = 900; // base focal length (px); cam.dolly shifts it for dolly in/out

export function createCamera(): Camera {
	return { yaw: 0, pitch: 0, dolly: 0, targetYaw: 0, targetPitch: 0, targetDolly: 0, ambient: 0 };
}

// Per-state camera pose [yaw, pitch, dolly] (radians + px). Small angles — this
// is perspective seasoning, not a flight sim. dolly > 0 dollies IN (longer
// focal), dolly < 0 pulls back. Must cover every LayoutState (Record is total).
const POSE: Record<LayoutState, readonly [number, number, number]> = {
	nebula: [0.1, 0.05, 0],
	genesis: [0.0, 0.02, 200],
	engines: [0.24, 0.1, 40],
	growth: [0.16, 0.34, 90],
	planes: [0.05, 0.46, 60],
	tiers: [0.05, 0.05, -20],
	isolation: [0.42, 0.16, 20],
	'bigbang-armed': [0.06, 0.1, 240],
	cta: [0.16, 0.07, 0],
};

export function setCameraForState(cam: Camera, state: LayoutState, intensity = 1): void {
	const pose = POSE[state] ?? POSE.nebula;
	// intensity < 1 (reduced-motion) keeps the per-state yaw/pitch/dolly gentle.
	cam.targetYaw = pose[0] * intensity;
	cam.targetPitch = pose[1] * intensity;
	cam.targetDolly = pose[2] * intensity;
}

/** The burst drives dolly directly: dolly-IN on collapse, dolly-OUT on expand. */
export function setCameraDolly(cam: Camera, dolly: number): void {
	cam.targetDolly = dolly;
}

export function stepCamera(cam: Camera, dtMs: number): void {
	const dt = Math.min(dtMs, 48) / 1000;
	const k = dt * STIFF;
	cam.yaw += (cam.targetYaw - cam.yaw) * k;
	cam.pitch += (cam.targetPitch - cam.pitch) * k;
	cam.dolly += (cam.targetDolly - cam.dolly) * k;
	cam.ambient += dt * 0.25; // perpetual gentle parallax — the scene never freezes
}

export interface Trig {
	sinY: number;
	cosY: number;
	sinX: number;
	cosX: number;
}

/**
 * Compute the frame's sin/cos ONCE, then reuse for every node. Pass a caller-
 * owned `out` to keep the hot path allocation-free (render.ts hoists one Trig).
 */
export function cameraTrig(cam: Camera, out?: Trig): Trig {
	const o = out ?? { sinY: 0, cosY: 0, sinX: 0, cosX: 0 };
	// Ambient drift layered on the settled pose keeps the galaxy alive at rest.
	const yaw = cam.yaw + Math.sin(cam.ambient) * 0.05;
	const pitch = cam.pitch + Math.cos(cam.ambient * 0.8) * 0.035;
	o.sinY = Math.sin(yaw);
	o.cosY = Math.cos(yaw);
	o.sinX = Math.sin(pitch);
	o.cosX = Math.cos(pitch);
	return o;
}

export interface Projected {
	sx: number;
	sy: number;
	scale: number;
	depth: number; // 1 = nearest, 0 = farthest (drives link fog + draw order)
}

/**
 * Project world (x, y in CSS px; z depth) to the screen. +z is farther → smaller
 * scale, lower depth. denom is clamped ≥1 so the result is always finite and the
 * scale stays positive (no node ever divides by zero or flips behind the camera).
 * Pass a caller-owned `out` so the per-node/per-particle hot loop never allocates
 * (render.ts reuses one Projected); without it a fresh object is returned (tests).
 */
export function project(x: number, y: number, z: number, cam: Camera, w: number, h: number, trig: Trig, out?: Projected): Projected {
	const o = out ?? { sx: 0, sy: 0, scale: 0, depth: 0 };
	const px = x - w / 2;
	const py = y - h / 2;
	// rotate around Y (yaw) in the x/z plane
	const rx = px * trig.cosY + z * trig.sinY;
	const rz0 = z * trig.cosY - px * trig.sinY;
	// rotate around X (pitch) in the y/z plane
	const ry = py * trig.cosX - rz0 * trig.sinX;
	const rz = py * trig.sinX + rz0 * trig.cosX;
	const focal = FOCAL + cam.dolly;
	const denom = focal + rz;
	const persp = focal / (denom < 1 ? 1 : denom);
	o.sx = w / 2 + rx * persp;
	o.sy = h / 2 + ry * persp;
	o.scale = persp;
	o.depth = Math.max(0, Math.min(1, (focal - rz) / (2 * focal)));
	return o;
}
