// Pre-rendered 3-face "cubix" sprites, stamped per node with drawImage. Each
// cube is drawn ONCE per (color, lightBucket) and cached — at most 8 engine
// colours × 5 buckets = 40 sprites ever built. The hot render loop only
// drawImage()s them (zero per-frame gradients/shadowBlur) — the same
// LH-safe budget class as the old glowSprite path.
const SPRITE = 64;
const cache = new Map<string, HTMLCanvasElement>();

function clampByte(n: number): number {
	return n < 0 ? 0 : n > 255 ? 255 : Math.round(n);
}

/** Scale a #rrggbb colour's luminance by `factor`, returning an rgb() string. */
function shade(hex: string, factor: number): string {
	const v = hex.replace('#', '');
	const r = parseInt(v.slice(0, 2), 16);
	const g = parseInt(v.slice(2, 4), 16);
	const b = parseInt(v.slice(4, 6), 16);
	return `rgb(${clampByte(r * factor)}, ${clampByte(g * factor)}, ${clampByte(b * factor)})`;
}

/** lightBucket 0..4 → how lit the tumbling cube is this frame (5 cached variants). */
export function cubeSprite(color: string, lightBucket: number): HTMLCanvasElement {
	const key = `${color}|${lightBucket}`;
	const cached = cache.get(key);
	if (cached) return cached;

	const sprite = document.createElement('canvas');
	sprite.width = SPRITE;
	sprite.height = SPRITE;
	const ctx = sprite.getContext('2d')!;
	const lit = 0.7 + (lightBucket / 4) * 0.6; // 0.70 .. 1.30
	const cx = SPRITE / 2;
	const cy = SPRITE / 2;

	// Soft glow behind the cube so it still reads at small size / far depth.
	const glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, cx);
	glow.addColorStop(0, shade(color, lit));
	glow.addColorStop(0.4, `${color}44`);
	glow.addColorStop(1, `${color}00`);
	ctx.fillStyle = glow;
	ctx.fillRect(0, 0, SPRITE, SPRITE);

	// Isometric cube: top (brightest), left (mid), right (darkest).
	const s = 15; // half-edge in sprite px
	const top = shade(color, lit * 1.18);
	const left = shade(color, lit * 0.82);
	const right = shade(color, lit * 0.6);

	ctx.beginPath(); // top diamond
	ctx.moveTo(cx, cy - s);
	ctx.lineTo(cx + s, cy - s / 2);
	ctx.lineTo(cx, cy);
	ctx.lineTo(cx - s, cy - s / 2);
	ctx.closePath();
	ctx.fillStyle = top;
	ctx.fill();

	ctx.beginPath(); // left face
	ctx.moveTo(cx - s, cy - s / 2);
	ctx.lineTo(cx, cy);
	ctx.lineTo(cx, cy + s);
	ctx.lineTo(cx - s, cy + s / 2);
	ctx.closePath();
	ctx.fillStyle = left;
	ctx.fill();

	ctx.beginPath(); // right face
	ctx.moveTo(cx + s, cy - s / 2);
	ctx.lineTo(cx, cy);
	ctx.lineTo(cx, cy + s);
	ctx.lineTo(cx + s, cy + s / 2);
	ctx.closePath();
	ctx.fillStyle = right;
	ctx.fill();

	// 1px top-edge highlight.
	ctx.strokeStyle = shade(color, Math.min(1.6, lit * 1.4));
	ctx.lineWidth = 1;
	ctx.beginPath();
	ctx.moveTo(cx - s, cy - s / 2);
	ctx.lineTo(cx, cy - s);
	ctx.lineTo(cx + s, cy - s / 2);
	ctx.stroke();

	cache.set(key, sprite);
	return sprite;
}
