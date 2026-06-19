// gen-media.mjs — zero-dep procedural SVG surf-scene generator for Surfind.
// One <slug>-cover.svg + <slug>-1.svg + <slug>-2.svg per beach, written to
// web/public/media/beaches/. Each scene VARIES by a hash of the slug (palette,
// sun position, wave phase) so no two beaches look identical — and no external
// photo is ever fetched. Run: node infra/gen-media.mjs
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, '..', 'web', 'public', 'media', 'beaches');

// Beaches with their region label (slug → region shown on the art).
const BEACHES = [
  ['playa-de-somo', 'Cantabria'], ['playa-de-liencres', 'Cantabria'],
  ['playa-de-rodiles', 'Asturias'], ['playa-de-zarautz', 'Gipuzkoa'],
  ['playa-de-la-zurriola', 'Gipuzkoa'], ['playa-de-mundaka', 'Bizkaia'],
  ['playa-de-sopelana', 'Bizkaia'], ['playa-de-razo', 'A Coruna'],
  ['playa-de-pantin', 'A Coruna'], ['playa-de-doninos', 'A Coruna'],
  ['playa-de-el-palmar', 'Cadiz'], ['playa-de-los-lances', 'Cadiz'],
  ['playa-de-famara', 'Las Palmas'], ['playa-de-las-americas', 'S.C. Tenerife'],
  ['playa-de-el-medano', 'S.C. Tenerife'], ['playa-de-mazagon', 'Huelva'],
  // ── 14 extra beaches (02b_more_beaches.sql) ──
  ['playa-de-bakio', 'Bizkaia'], ['playa-de-laga', 'Bizkaia'],
  ['playa-de-deba', 'Gipuzkoa'], ['playa-de-meron', 'Cantabria'],
  ['playa-de-xago', 'Asturias'], ['playa-de-tapia', 'Asturias'],
  ['playa-de-nemina', 'A Coruna'], ['playa-de-patos', 'Pontevedra'],
  ['playa-de-bolonia', 'Cadiz'], ['playa-de-valdevaqueros', 'Cadiz'],
  ['playa-de-la-cicer', 'Las Palmas'], ['playa-de-las-cucharas', 'Las Palmas'],
  ['playa-de-cabezo', 'S.C. Tenerife'], ['playa-de-la-barca', 'Las Palmas'],
];

// A handful of curated ocean palettes [sky-top, sky-bottom, sun, sea-far, sea-near, foam].
const PALETTES = [
  ['#0a2a45', '#f6b35c', '#ffd98a', '#1f6f8f', '#2b9bb5', '#eaf7fb'],
  ['#10243b', '#e98a6b', '#ffc07a', '#15506a', '#2f8aa6', '#f0fbff'],
  ['#062436', '#7fb7c9', '#dff3f8', '#0f5a73', '#3aa0bb', '#ffffff'],
  ['#1a2c4a', '#f3a05a', '#ffe1a3', '#234e6e', '#3f97b8', '#eef9fd'],
  ['#0c1e33', '#caa6d6', '#ffd9ec', '#1d4f6c', '#368fad', '#f4fbfe'],
  ['#073043', '#ffd27a', '#fff1c2', '#0d6178', '#28a7c0', '#ffffff'],
];

// Deterministic 32-bit hash of a string (no crypto dep).
function hash(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i += 1) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

const title = (slug) =>
  slug.replace(/^playa-de-/, '').replace(/-/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());

// One translucent wave band as a smooth cubic path across the width.
function wave(y, amp, phase, w, fill, opacity) {
  const segs = 4;
  const step = w / segs;
  let d = `M0 ${y}`;
  for (let i = 0; i < segs; i += 1) {
    const x1 = i * step + step * 0.3;
    const x2 = i * step + step * 0.7;
    const x = (i + 1) * step;
    const dir = (i + phase) % 2 === 0 ? -1 : 1;
    d += ` C ${x1} ${y + dir * amp} ${x2} ${y - dir * amp} ${x} ${y}`;
  }
  d += ` L ${w} 720 L 0 720 Z`;
  return `<path d="${d}" fill="${fill}" opacity="${opacity}"/>`;
}

// Render a full 1280x720 ocean/surf scene for a slug + variant.
function scene(slug, region, variant) {
  const w = 1280;
  const h = 720;
  const seed = hash(`${slug}-${variant}`);
  const p = PALETTES[seed % PALETTES.length];
  const sunX = 180 + (seed % 920);
  const sunY = 150 + ((seed >> 4) % 120);
  const phase = (seed >> 8) % 2;
  const horizon = 300 + ((seed >> 3) % 60);
  const id = `g${seed % 9999}`;
  const bands = [
    wave(horizon + 40, 16, phase, w, p[3], 0.85),
    wave(horizon + 110, 22, phase + 1, w, p[4], 0.8),
    wave(horizon + 200, 30, phase, w, p[4], 0.6),
    wave(horizon + 300, 40, phase + 1, w, p[5], 0.5),
  ].join('');
  const label = variant === 'cover' ? title(slug) : `${title(slug)} · ${variant}`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" role="img" aria-label="${title(slug)}, ${region}">
  <defs>
    <linearGradient id="${id}sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${p[0]}"/><stop offset="1" stop-color="${p[1]}"/>
    </linearGradient>
    <radialGradient id="${id}sun" cx="50%" cy="50%" r="50%">
      <stop offset="0" stop-color="${p[2]}" stop-opacity="0.95"/>
      <stop offset="1" stop-color="${p[2]}" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="${w}" height="${h}" fill="url(#${id}sky)"/>
  <circle cx="${sunX}" cy="${sunY}" r="160" fill="url(#${id}sun)"/>
  <circle cx="${sunX}" cy="${sunY}" r="54" fill="${p[2]}" opacity="0.9"/>
  <rect y="${horizon}" width="${w}" height="${h - horizon}" fill="${p[3]}" opacity="0.55"/>
  ${bands}
  <text x="48" y="${h - 96}" font-family="DM Sans, system-ui, sans-serif" font-size="26" font-weight="700" fill="#ffffff" opacity="0.85" letter-spacing="6">${region.toUpperCase()}</text>
  <text x="46" y="${h - 44}" font-family="DM Sans, system-ui, sans-serif" font-size="58" font-weight="900" fill="#ffffff">${label}</text>
</svg>`;
}

async function main() {
  await mkdir(OUT, { recursive: true });
  let n = 0;
  for (const [slug, region] of BEACHES) {
    await writeFile(join(OUT, `${slug}-cover.svg`), scene(slug, region, 'cover'));
    await writeFile(join(OUT, `${slug}-1.svg`), scene(slug, region, '1'));
    await writeFile(join(OUT, `${slug}-2.svg`), scene(slug, region, '2'));
    n += 3;
  }
  console.log(`[gen-media] wrote ${n} SVGs for ${BEACHES.length} beaches → ${OUT}`);
}

main().catch((e) => {
  console.error('[gen-media]', e.message);
  process.exit(1);
});
