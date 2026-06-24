// Avatar.tsx — initials-based avatar (no image dependency). Deterministic accent
// tint derived from the name so the same user is always the same hue.

import clsx from 'clsx';

/** AvatarProps describes the displayed name and size. */
export type AvatarProps = { name: string; size?: number; className?: string };

/** initials returns up to two uppercase initials from a name or email. */
function initials(name: string): string {
  const clean = name.split('@')[0].trim();
  const parts = clean.split(/[\s._-]+/).filter(Boolean);
  if (parts.length === 0) return '?';
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

/** hue maps a string to a stable 0–360 hue for the tint. */
function hue(name: string): number {
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 360;
  return h;
}

/** Avatar renders a circular initials badge tinted by the name. */
export function Avatar({ name, size = 36, className }: AvatarProps) {
  const h = hue(name);
  return (
    <span
      aria-hidden
      style={{ width: size, height: size, background: `hsl(${h} 60% 22%)`, color: `hsl(${h} 90% 80%)`, fontSize: size * 0.4 }}
      className={clsx('inline-flex items-center justify-center rounded-full font-semibold ring-1 ring-white/10', className)}
    >
      {initials(name)}
    </span>
  );
}
