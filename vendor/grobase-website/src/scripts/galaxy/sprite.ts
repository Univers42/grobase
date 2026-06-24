// Pre-rendered radial-gradient glow sprites, stamped per node with drawImage.
// (Per-frame shadowBlur is far too slow; gradient sprites are one-time cost.)
const SPRITE_SIZE = 64;
const cache = new Map<string, HTMLCanvasElement>();

export function glowSprite(color: string): HTMLCanvasElement {
	let sprite = cache.get(color);
	if (sprite) return sprite;
	sprite = document.createElement('canvas');
	sprite.width = SPRITE_SIZE;
	sprite.height = SPRITE_SIZE;
	const ctx = sprite.getContext('2d')!;
	const half = SPRITE_SIZE / 2;
	const gradient = ctx.createRadialGradient(half, half, 0, half, half, half);
	gradient.addColorStop(0, color);
	gradient.addColorStop(0.22, color);
	gradient.addColorStop(0.5, `${color}55`);
	gradient.addColorStop(1, `${color}00`);
	ctx.fillStyle = gradient;
	ctx.fillRect(0, 0, SPRITE_SIZE, SPRITE_SIZE);
	cache.set(color, sprite);
	return sprite;
}
