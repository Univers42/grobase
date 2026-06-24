#!/usr/bin/env node
// gen-media.mjs — zero-dependency procedural SVG surf/ocean art generator.
//
// For every surfind beach it writes three layered ocean scenes into
// public/media/beaches/:  <slug>-cover.svg (1600x900 hero) + <slug>-1.svg
// and <slug>-2.svg (1200x800 gallery). Each scene is deterministic in the
// slug: an inline string hash picks an ocean palette, the sun x-position and
// the wave amplitude/phase, so the same beach always renders the same art and
// different beaches look distinct. Pure string templates, no npm deps, no
// external assets. Idempotent — re-running overwrites.
//
//   node gen-media.mjs

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "public", "media", "beaches");

// 16 seeded beaches + 14 deep-expansion beaches. { slug, name, region }.
const BEACHES = [
  { slug: "playa-de-somo", name: "Playa de Somo", region: "Cantabria" },
  { slug: "playa-de-liencres", name: "Playa de Liencres", region: "Cantabria" },
  { slug: "playa-de-rodiles", name: "Playa de Rodiles", region: "Asturias" },
  { slug: "playa-de-zarautz", name: "Playa de Zarautz", region: "Gipuzkoa" },
  { slug: "playa-de-la-zurriola", name: "Playa de La Zurriola", region: "Gipuzkoa" },
  { slug: "playa-de-mundaka", name: "Playa de Mundaka", region: "Bizkaia" },
  { slug: "playa-de-sopelana", name: "Playa de Sopelana", region: "Bizkaia" },
  { slug: "playa-de-razo", name: "Playa de Razo", region: "A Coruna" },
  { slug: "playa-de-pantin", name: "Playa de Pantin", region: "A Coruna" },
  { slug: "playa-de-doninos", name: "Playa de Doninos", region: "A Coruna" },
  { slug: "playa-de-el-palmar", name: "Playa de El Palmar", region: "Cadiz" },
  { slug: "playa-de-los-lances", name: "Playa de Los Lances", region: "Cadiz" },
  { slug: "playa-de-famara", name: "Playa de Famara", region: "Las Palmas" },
  { slug: "playa-de-las-americas", name: "Playa de Las Americas", region: "Santa Cruz de Tenerife" },
  { slug: "playa-de-el-medano", name: "Playa de El Medano", region: "Santa Cruz de Tenerife" },
  { slug: "playa-de-mazagon", name: "Playa de Mazagon", region: "Huelva" },
  // deep-expansion (~14 new)
  { slug: "playa-de-meron", name: "Playa de Meron", region: "Cantabria" },
  { slug: "playa-de-xago", name: "Playa de Xago", region: "Asturias" },
  { slug: "playa-de-tapia", name: "Playa de Tapia", region: "Asturias" },
  { slug: "playa-de-deba", name: "Playa de Deba", region: "Gipuzkoa" },
  { slug: "playa-de-bakio", name: "Playa de Bakio", region: "Bizkaia" },
  { slug: "playa-de-laga", name: "Playa de Laga", region: "Bizkaia" },
  { slug: "playa-de-nemina", name: "Playa de Nemina", region: "A Coruna" },
  { slug: "playa-de-patos", name: "Playa de Patos", region: "Pontevedra" },
  { slug: "playa-de-bolonia", name: "Playa de Bolonia", region: "Cadiz" },
  { slug: "playa-de-valdevaqueros", name: "Playa de Valdevaqueros", region: "Cadiz" },
  { slug: "playa-de-las-cucharas", name: "Playa de Las Cucharas", region: "Las Palmas" },
  { slug: "playa-de-la-cicer", name: "Playa de La Cicer", region: "Las Palmas" },
  { slug: "playa-de-cabezo", name: "Playa de Cabezo", region: "Santa Cruz de Tenerife" },
  { slug: "playa-de-la-barca", name: "Playa de La Barca", region: "Las Palmas" },
];

// 6 ocean palettes: [skyTop, skyBottom, sun, wave-back..wave-front, foam, horizon].
const PALETTES = [
  { skyTop: "#0a2540", skyBot: "#ff9e6d", sun: "#ffd27f", waves: ["#0d3b66", "#1b5f8c", "#2e86ab", "#5bb8d4"], foam: "#eaf6fb", horizon: "#f6c79b" },
  { skyTop: "#1b2a4a", skyBot: "#f7b267", sun: "#ffe2a0", waves: ["#16324f", "#1f6e8c", "#2e9aa6", "#84d2c5"], foam: "#f2fbf8", horizon: "#f7c28c" },
  { skyTop: "#15324d", skyBot: "#b7e2f0", sun: "#fff4cc", waves: ["#11476b", "#2079a6", "#3aa0c4", "#7fcfe0"], foam: "#ffffff", horizon: "#cfeaf5" },
  { skyTop: "#2b1b3a", skyBot: "#ff6f91", sun: "#ffd9a0", waves: ["#241b46", "#4b3b73", "#6f5b9c", "#a48fc7"], foam: "#f6eefb", horizon: "#ffb3c1" },
  { skyTop: "#06303a", skyBot: "#5fc9b0", sun: "#d9ffe9", waves: ["#063b40", "#0f6e63", "#1f9e87", "#67c9a8"], foam: "#effff6", horizon: "#bdf0dc" },
  { skyTop: "#102a43", skyBot: "#f0c987", sun: "#ffe7ad", waves: ["#0f3a5f", "#27628a", "#4090b0", "#86c5d8"], foam: "#f4fbff", horizon: "#f3d6a3" },
];

// hash32 folds a string into an unsigned 32-bit int (djb2 variant) so every
// derived choice (palette, sun x, wave phase) is stable per slug.
function hash32(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  return h >>> 0;
}

// pick deterministically selects an array element from a hash slice.
function pick(arr, h) {
  return arr[h % arr.length];
}

// wavePath builds a smooth cubic-bezier wave band that fills to the bottom of
// the canvas, with `amp` peak height, `phase` horizontal offset and `baseY`
// resting line. The control points alternate above/below to read as swell.
function wavePath(w, h, baseY, amp, phase, segments) {
  const step = w / segments;
  let d = `M0 ${(baseY + Math.sin(phase) * amp).toFixed(1)}`;
  for (let i = 0; i < segments; i++) {
    const x0 = i * step;
    const x1 = (i + 1) * step;
    const y1 = baseY + Math.sin(phase + (i + 1) * 0.9) * amp;
    const cx1 = x0 + step * 0.4;
    const cx2 = x0 + step * 0.6;
    const cy = baseY + Math.sin(phase + i * 0.9 + 0.45) * amp;
    d += ` C${cx1.toFixed(1)} ${cy.toFixed(1)} ${cx2.toFixed(1)} ${cy.toFixed(1)} ${x1.toFixed(1)} ${y1.toFixed(1)}`;
  }
  return `${d} L${w} ${h} L0 ${h} Z`;
}

// esc XML-escapes label text so beach names with & or quotes stay valid SVG.
function esc(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" }[c]));
}

// scene renders one full SVG document for a beach at the given dimensions. It
// layers sky gradient → sun glow → horizon → 4 translucent wave bands with foam
// crests → a soft vignette → the beach/region label.
function scene(beach, w, h, variant) {
  const base = hash32(beach.slug);
  const hv = hash32(beach.slug + ":" + variant);
  const pal = pick(PALETTES, base);
  const sunX = 0.18 + ((base >>> 7) % 64) / 100; // 0.18..0.82
  const sunCx = (sunX * w).toFixed(0);
  const horizonY = h * 0.46;
  const ampBase = h * (0.018 + ((base >>> 3) % 5) / 200);
  const phase = ((hv % 360) * Math.PI) / 180;
  const sunR = Math.round(h * 0.11);
  const uid = `${beach.slug}-${variant}`;

  const bands = pal.waves
    .map((col, i) => {
      const baseY = horizonY + (i + 1) * h * 0.085;
      const amp = ampBase * (1 + i * 0.5);
      const ph = phase + i * 1.3;
      const op = (0.55 + i * 0.12).toFixed(2);
      const foamY = baseY - amp * 0.4;
      return (
        `<path d="${wavePath(w, h, baseY, amp, ph, 6)}" fill="${col}" fill-opacity="${op}"/>` +
        `<path d="${wavePath(w, h, foamY, amp * 0.5, ph + 0.6, 6).replace(/ L.*Z$/, "")}" fill="none" stroke="${pal.foam}" stroke-opacity="${(0.18 + i * 0.07).toFixed(2)}" stroke-width="${(2 + i).toFixed(0)}"/>`
      );
    })
    .join("");

  const labelSize = Math.round(h * 0.052);
  const regionSize = Math.round(h * 0.03);
  const lx = Math.round(w * 0.06);
  const ly = Math.round(h * 0.88);

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" role="img" aria-label="${esc(beach.name)} — ${esc(beach.region)}">
  <defs>
    <linearGradient id="sky-${uid}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${pal.skyTop}"/>
      <stop offset="0.7" stop-color="${pal.skyBot}"/>
    </linearGradient>
    <radialGradient id="sun-${uid}" cx="${sunCx}" cy="${horizonY.toFixed(0)}" r="${sunR * 3}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${pal.sun}" stop-opacity="0.95"/>
      <stop offset="0.4" stop-color="${pal.sun}" stop-opacity="0.35"/>
      <stop offset="1" stop-color="${pal.sun}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="vig-${uid}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0.55" stop-color="#000000" stop-opacity="0"/>
      <stop offset="1" stop-color="#000000" stop-opacity="0.35"/>
    </linearGradient>
  </defs>
  <rect width="${w}" height="${h}" fill="url(#sky-${uid})"/>
  <rect width="${w}" height="${h}" fill="url(#sun-${uid})"/>
  <circle cx="${sunCx}" cy="${horizonY.toFixed(0)}" r="${sunR}" fill="${pal.sun}" fill-opacity="0.9"/>
  <rect y="${horizonY.toFixed(0)}" width="${w}" height="2" fill="${pal.horizon}" fill-opacity="0.6"/>
  ${bands}
  <rect width="${w}" height="${h}" fill="url(#vig-${uid})"/>
  <text x="${lx}" y="${ly}" font-family="'Segoe UI',Helvetica,Arial,sans-serif" font-size="${labelSize}" font-weight="700" fill="#ffffff" fill-opacity="0.96" letter-spacing="0.5">${esc(beach.name)}</text>
  <text x="${lx}" y="${ly + regionSize + 8}" font-family="'Segoe UI',Helvetica,Arial,sans-serif" font-size="${regionSize}" font-weight="500" fill="${pal.foam}" fill-opacity="0.85" letter-spacing="2">${esc(beach.region.toUpperCase())}</text>
</svg>
`;
}

// main generates the three SVG variants for every beach and reports the count.
function main() {
  mkdirSync(OUT_DIR, { recursive: true });
  let count = 0;
  for (const b of BEACHES) {
    writeFileSync(join(OUT_DIR, `${b.slug}-cover.svg`), scene(b, 1600, 900, "cover"));
    writeFileSync(join(OUT_DIR, `${b.slug}-1.svg`), scene(b, 1200, 800, "1"));
    writeFileSync(join(OUT_DIR, `${b.slug}-2.svg`), scene(b, 1200, 800, "2"));
    count += 3;
  }
  process.stdout.write(`gen-media: wrote ${count} SVG files for ${BEACHES.length} beaches → ${OUT_DIR}\n`);
}

main();
