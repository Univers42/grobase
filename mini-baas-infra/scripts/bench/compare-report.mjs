#!/usr/bin/env node
// compare-report.mjs — zero-dependency competitive-benchmark graph generator.
//
// Reads scripts/bench/compare-data.json and emits hand-rolled SVG charts (no
// charting lib, only Node built-ins) + an index.html + a report.md under
// artifacts/bench/compare/. Bars/lines are styled BY SOURCE so a reader can see
// at a glance which numbers we measured vs. which the vendor published vs. which
// we modeled. 'na' series are omitted but listed in a footnote.
//
// Honesty contract (kernel rule #4 / scripts/bench/METHOD.md): a number's
// `source` ∈ {measured, published, modeled, na}. measured → artifact path;
// published → origin note; modeled → method/formula; na → no honest number.
//
// Usage:
//   node compare-report.mjs [--data <path>] [--out <dir>]
// Defaults to the canonical paths relative to this file.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
// scripts/bench/ -> repo: mini-baas-infra/
const INFRA = resolve(__dirname, "..", "..");
const DEFAULT_DATA = join(__dirname, "compare-data.json");
const DEFAULT_OUT = join(INFRA, "artifacts", "bench", "compare");

// ── arg parse ───────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const out = { data: DEFAULT_DATA, out: DEFAULT_OUT };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--data") out.data = argv[++i];
    else if (a === "--out") out.out = argv[++i];
    else if (a === "-h" || a === "--help") {
      console.log("usage: compare-report.mjs [--data <path>] [--out <dir>]");
      process.exit(0);
    }
  }
  return out;
}

// ── style constants (no inline deps; all SVG hand-rolled) ────────────────────
const SOURCE_STYLE = {
  measured: { tag: "", fillOpacity: 1, dash: "", desc: "solid + filled" },
  published: { tag: " (pub)", fillOpacity: 0.55, dash: "6 4", desc: "hatched / dashed" },
  modeled: { tag: " (model)", fillOpacity: 0.35, dash: "2 3", desc: "dotted" },
  na: { tag: " (n/a)", fillOpacity: 0, dash: "", desc: "omitted" },
};
// stable, colour-blind-friendly palette keyed by contender
const CONTENDER_COLOR = {
  "grobase-nano": "#0d9488",
  "grobase-basic": "#0ea5e9",
  "grobase-essential": "#2563eb",
  "grobase-pro": "#7c3aed",
  "grobase-max": "#9333ea",
  pocketbase: "#f59e0b",
  "supabase-selfhost": "#16a34a",
  "supabase-cloud": "#65a30d",
  firebase: "#ef4444",
};
const FALLBACK_COLORS = ["#475569", "#be123c", "#0891b2", "#ca8a04", "#4338ca"];
function colorFor(key, idx) {
  return CONTENDER_COLOR[key] || FALLBACK_COLORS[idx % FALLBACK_COLORS.length];
}

// ── small SVG helpers ────────────────────────────────────────────────────────
const esc = (s) =>
  String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

function fmtNum(v) {
  if (v == null || !Number.isFinite(Number(v))) return "n/a";
  const n = Number(v);
  if (n === 0) return "0";
  if (Math.abs(n) >= 1000) return n.toLocaleString("en-US", { maximumFractionDigits: 0 });
  if (Math.abs(n) >= 10) return String(Math.round(n * 10) / 10);
  if (Math.abs(n) >= 1) return String(Math.round(n * 100) / 100);
  return String(Math.round(n * 1000) / 1000);
}

function niceLabel(key) {
  return esc(key);
}

// trim a descriptive series/contender label so it fits the legend column
function legendText(s, max = 26) {
  s = String(s ?? "");
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

// hatch pattern + dot pattern defs reused across charts
function svgDefs() {
  return `  <defs>
    <pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
      <line x1="0" y1="0" x2="0" y2="6" stroke="#ffffff" stroke-width="2" stroke-opacity="0.6"/>
    </pattern>
    <pattern id="dots" width="5" height="5" patternUnits="userSpaceOnUse">
      <circle cx="1.5" cy="1.5" r="1" fill="#ffffff" fill-opacity="0.7"/>
    </pattern>
  </defs>`;
}

// ── grouped bar chart (one bar per contender for a single metric) ────────────
function barChart(metric, contenders) {
  const W = 880;
  const H = 460;
  const ML = 70, MR = 200, MT = 64, MB = 86;
  const plotW = W - ML - MR;
  const plotH = H - MT - MB;

  // series with real numeric data (skip na / null)
  const series = [];
  const naSeries = [];
  for (const key of contenders) {
    const dp = metric.data[key];
    if (!dp || dp.source === "na" || dp.value == null || !Number.isFinite(Number(dp.value))) {
      if (dp) naSeries.push({ key, dp });
      continue;
    }
    series.push({ key, value: Number(dp.value), dp });
  }

  const lowerIsBetter = metric.lowerIsBetter !== false;
  const unit = metric.unit || "";

  if (series.length === 0) {
    return wrapSvg(W, H, `${title(W, metric.label || metric.key, metric.context, unit)}
  <text x="${W / 2}" y="${H / 2}" text-anchor="middle" font-family="sans-serif" font-size="16" fill="#64748b">No measured/published/modeled data for this metric</text>`, naSeries, metric);
  }

  const maxV = Math.max(...series.map((s) => s.value));
  const yMax = maxV <= 0 ? 1 : maxV * 1.18;
  const winnerVal = lowerIsBetter
    ? Math.min(...series.map((s) => s.value))
    : Math.max(...series.map((s) => s.value));

  // bars
  const n = series.length;
  const slot = plotW / n;
  const bw = Math.min(72, slot * 0.62);
  const x0 = (i) => ML + slot * i + (slot - bw) / 2;
  const y = (v) => MT + plotH - (v / yMax) * plotH;

  let parts = "";
  // gridlines + y axis ticks
  const ticks = 5;
  for (let t = 0; t <= ticks; t++) {
    const v = (yMax / ticks) * t;
    const yy = y(v);
    parts += `  <line x1="${ML}" y1="${yy.toFixed(1)}" x2="${ML + plotW}" y2="${yy.toFixed(1)}" stroke="#e2e8f0" stroke-width="1"/>\n`;
    parts += `  <text x="${ML - 8}" y="${(yy + 4).toFixed(1)}" text-anchor="end" font-family="sans-serif" font-size="11" fill="#64748b">${esc(fmtNum(v))}</text>\n`;
  }
  // axes
  parts += `  <line x1="${ML}" y1="${MT}" x2="${ML}" y2="${MT + plotH}" stroke="#94a3b8" stroke-width="1.5"/>\n`;
  parts += `  <line x1="${ML}" y1="${MT + plotH}" x2="${ML + plotW}" y2="${MT + plotH}" stroke="#94a3b8" stroke-width="1.5"/>\n`;
  parts += `  <text x="${ML - 52}" y="${MT + plotH / 2}" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#475569" transform="rotate(-90 ${ML - 52} ${MT + plotH / 2})">${esc(unit)}</text>\n`;

  series.forEach((s, i) => {
    const st = SOURCE_STYLE[s.dp.source] || SOURCE_STYLE.measured;
    const col = colorFor(s.key, i);
    const bx = x0(i);
    const by = y(s.value);
    const bh = MT + plotH - by;
    const isWinner = s.value === winnerVal;
    // base fill
    parts += `  <rect x="${bx.toFixed(1)}" y="${by.toFixed(1)}" width="${bw.toFixed(1)}" height="${Math.max(0, bh).toFixed(1)}" fill="${col}" fill-opacity="${st.fillOpacity}" stroke="${col}" stroke-width="1.5" ${st.dash ? `stroke-dasharray="${st.dash}"` : ""} rx="2"/>\n`;
    // overlay pattern to disambiguate non-measured sources in print/greyscale
    if (s.dp.source === "published") parts += `  <rect x="${bx.toFixed(1)}" y="${by.toFixed(1)}" width="${bw.toFixed(1)}" height="${Math.max(0, bh).toFixed(1)}" fill="url(#hatch)" rx="2"/>\n`;
    if (s.dp.source === "modeled") parts += `  <rect x="${bx.toFixed(1)}" y="${by.toFixed(1)}" width="${bw.toFixed(1)}" height="${Math.max(0, bh).toFixed(1)}" fill="url(#dots)" rx="2"/>\n`;
    // winner crown
    if (isWinner) parts += `  <text x="${(bx + bw / 2).toFixed(1)}" y="${(by - 22).toFixed(1)}" text-anchor="middle" font-family="sans-serif" font-size="14" fill="#16a34a">&#9733;</text>\n`;
    // value label
    parts += `  <text x="${(bx + bw / 2).toFixed(1)}" y="${(by - 6).toFixed(1)}" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="${isWinner ? "bold" : "normal"}" fill="#1e293b">${esc(fmtNum(s.value))}${st.tag}</text>\n`;
    // x label (contender) — angled to fit
    const lx = bx + bw / 2;
    const ly = MT + plotH + 16;
    parts += `  <text x="${lx.toFixed(1)}" y="${ly}" text-anchor="end" font-family="sans-serif" font-size="11" fill="#334155" transform="rotate(-28 ${lx.toFixed(1)} ${ly})">${niceLabel(s.key)}</text>\n`;
  });

  // legend (sources)
  parts += sourceLegend(ML + plotW + 18, MT);
  // winner annotation line
  const wKey = series.find((s) => s.value === winnerVal)?.key;
  parts += `  <text x="${ML + plotW + 18}" y="${MT + 150}" font-family="sans-serif" font-size="11" fill="#16a34a">&#9733; best: ${esc(wKey)}</text>\n`;
  parts += `  <text x="${ML + plotW + 18}" y="${MT + 168}" font-family="sans-serif" font-size="10" fill="#64748b">(${lowerIsBetter ? "lower" : "higher"} is better)</text>\n`;

  return wrapSvg(W, H, `${title(W, metric.label || metric.key, metric.context, unit)}\n${parts}`, naSeries, metric);
}

// ── line chart (y vs tenant count, one line per contender) ───────────────────
function lineChart(curve, contenders) {
  const W = 880;
  const H = 480;
  const ML = 74, MR = 210, MT = 64, MB = 70;
  const plotW = W - ML - MR;
  const plotH = H - MT - MB;
  const unit = curve.unit || "";
  const xs = (curve.x || []).map(Number).filter((v) => Number.isFinite(v) && v > 0);

  // collect lines (skip na). A curve declares its OWN series keys, which may be
  // descriptive (e.g. grobase-shared_rls, supabase-selfhost-modeled) rather than
  // the canonical contender list — iterate the series, not `contenders`.
  const lines = [];
  const naSeries = [];
  const seriesKeys = Object.keys(curve.series || {});
  for (const key of seriesKeys) {
    const ser = curve.series && curve.series[key];
    if (!ser || ser.source === "na" || !Array.isArray(ser.y)) {
      if (ser) naSeries.push({ key, dp: ser });
      continue;
    }
    const pts = [];
    ser.y.forEach((yv, i) => {
      const xv = Number((curve.x || [])[i]);
      if (yv == null || !Number.isFinite(Number(yv)) || !Number.isFinite(xv) || xv <= 0) return;
      pts.push({ x: xv, y: Number(yv), source: (ser.pointSources && ser.pointSources[i]) || ser.source });
    });
    if (pts.length) lines.push({ key, label: ser.label || key, source: ser.source, pts, note: ser.note, artifact: ser.artifact });
    else if (ser) naSeries.push({ key, dp: ser });
  }

  if (lines.length === 0 || xs.length === 0) {
    return wrapSvg(W, H, `${title(W, curve.label || curve.key, curve.context, unit)}
  <text x="${W / 2}" y="${H / 2}" text-anchor="middle" font-family="sans-serif" font-size="16" fill="#64748b">No plottable data for this curve</text>`, naSeries, curve);
  }

  const xMin = Math.min(...lines.flatMap((l) => l.pts.map((p) => p.x)));
  const xMax = Math.max(...lines.flatMap((l) => l.pts.map((p) => p.x)));
  const yMaxRaw = Math.max(...lines.flatMap((l) => l.pts.map((p) => p.y)));
  const yMax = yMaxRaw <= 0 ? 1 : yMaxRaw * 1.15;
  // Opt-in log-y (curve.yLog) for curves whose series span many orders of magnitude
  // (e.g. RAM-to-host-N-tenants: ~3 MiB vs ~1.3 TiB). Default OFF = linear (unchanged).
  const yLog = curve.yLog === true;
  const yPos = lines.flatMap((l) => l.pts.map((p) => p.y)).filter((v) => v > 0);
  const yMinPos = yPos.length ? Math.min(...yPos) : 1;
  const lyMin = yLog ? Math.floor(Math.log10(yMinPos)) : 0;
  const lyMax = yLog ? Math.max(lyMin + 1, Math.ceil(Math.log10(yMaxRaw > 0 ? yMaxRaw : 1))) : 0;
  // log-x scale (counts span 200..100000)
  const lxMin = Math.log10(xMin);
  const lxMax = Math.log10(xMax === xMin ? xMin * 10 : xMax);
  const px = (x) => ML + ((Math.log10(x) - lxMin) / (lxMax - lxMin || 1)) * plotW;
  const py = (y) => yLog
    ? MT + plotH - ((Math.log10(Math.max(y, yMinPos)) - lyMin) / ((lyMax - lyMin) || 1)) * plotH
    : MT + plotH - (y / yMax) * plotH;

  let parts = "";
  // y gridlines (decade ticks when log-y, else 5 linear ticks)
  if (yLog) {
    for (let d = lyMin; d <= lyMax; d++) {
      const v = Math.pow(10, d);
      const yy = py(v);
      parts += `  <line x1="${ML}" y1="${yy.toFixed(1)}" x2="${ML + plotW}" y2="${yy.toFixed(1)}" stroke="#e2e8f0" stroke-width="1"/>\n`;
      parts += `  <text x="${ML - 8}" y="${(yy + 4).toFixed(1)}" text-anchor="end" font-family="sans-serif" font-size="11" fill="#64748b">${esc(fmtNum(v))}</text>\n`;
    }
  } else {
    const ticks = 5;
    for (let t = 0; t <= ticks; t++) {
      const v = (yMax / ticks) * t;
      const yy = py(v);
      parts += `  <line x1="${ML}" y1="${yy.toFixed(1)}" x2="${ML + plotW}" y2="${yy.toFixed(1)}" stroke="#e2e8f0" stroke-width="1"/>\n`;
      parts += `  <text x="${ML - 8}" y="${(yy + 4).toFixed(1)}" text-anchor="end" font-family="sans-serif" font-size="11" fill="#64748b">${esc(fmtNum(v))}</text>\n`;
    }
  }
  // x gridlines + labels (use the declared x points)
  const xticks = (curve.x || []).map(Number).filter((v) => Number.isFinite(v) && v > 0);
  for (const xv of xticks) {
    if (xv < xMin || xv > xMax) continue;
    const xx = px(xv);
    parts += `  <line x1="${xx.toFixed(1)}" y1="${MT}" x2="${xx.toFixed(1)}" y2="${MT + plotH}" stroke="#f1f5f9" stroke-width="1"/>\n`;
    parts += `  <text x="${xx.toFixed(1)}" y="${MT + plotH + 18}" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#475569">${esc(fmtNum(xv))}</text>\n`;
  }
  // axes
  parts += `  <line x1="${ML}" y1="${MT}" x2="${ML}" y2="${MT + plotH}" stroke="#94a3b8" stroke-width="1.5"/>\n`;
  parts += `  <line x1="${ML}" y1="${MT + plotH}" x2="${ML + plotW}" y2="${MT + plotH}" stroke="#94a3b8" stroke-width="1.5"/>\n`;
  const xLabel = (curve.xUnit && curve.xUnit !== "tenants") ? curve.xUnit : "tenant count";
  parts += `  <text x="${ML + plotW / 2}" y="${MT + plotH + 44}" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#475569">${esc(xLabel)} (log scale)</text>\n`;
  parts += `  <text x="${ML - 56}" y="${MT + plotH / 2}" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#475569" transform="rotate(-90 ${ML - 56} ${MT + plotH / 2})">${esc(unit)}${yLog ? " (log)" : ""}</text>\n`;

  lines.forEach((l, i) => {
    const st = SOURCE_STYLE[l.source] || SOURCE_STYLE.measured;
    const col = colorFor(l.key, i);
    const ptsStr = l.pts.map((p) => `${px(p.x).toFixed(1)},${py(p.y).toFixed(1)}`).join(" ");
    parts += `  <polyline points="${ptsStr}" fill="none" stroke="${col}" stroke-width="2.5" ${st.dash ? `stroke-dasharray="${st.dash}"` : ""} stroke-linejoin="round"/>\n`;
    l.pts.forEach((p) => {
      const cx = px(p.x), cy = py(p.y);
      parts += `  <circle cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" r="3.5" fill="${col}" fill-opacity="${Math.max(0.4, st.fillOpacity)}" stroke="#fff" stroke-width="1"/>\n`;
    });
    // end-of-line value label
    const last = l.pts[l.pts.length - 1];
    parts += `  <text x="${(px(last.x) + 6).toFixed(1)}" y="${(py(last.y) + 3).toFixed(1)}" font-family="sans-serif" font-size="10" fill="${col}">${esc(fmtNum(last.y))}</text>\n`;
  });

  // legend (contenders + their source tag)
  let ly = MT + 6;
  lines.forEach((l, i) => {
    const st = SOURCE_STYLE[l.source] || SOURCE_STYLE.measured;
    const col = colorFor(l.key, i);
    parts += `  <line x1="${ML + plotW + 18}" y1="${ly}" x2="${ML + plotW + 44}" y2="${ly}" stroke="${col}" stroke-width="2.5" ${st.dash ? `stroke-dasharray="${st.dash}"` : ""}/>\n`;
    parts += `  <text x="${ML + plotW + 50}" y="${ly + 4}" font-family="sans-serif" font-size="11" fill="#334155">${niceLabel(legendText(l.label || l.key))}${st.tag}</text>\n`;
    ly += 20;
  });

  return wrapSvg(W, H, `${title(W, curve.label || curve.key, curve.context, unit)}\n${parts}`, naSeries, curve);
}

// ── shared SVG chrome ────────────────────────────────────────────────────────
function title(W, label, context, unit) {
  let s = `  <text x="${W / 2}" y="28" text-anchor="middle" font-family="sans-serif" font-size="18" font-weight="bold" fill="#0f172a">${esc(label)}</text>\n`;
  const sub = [context, unit ? `(${unit})` : ""].filter(Boolean).join("  ·  ");
  if (sub) s += `  <text x="${W / 2}" y="48" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#64748b">${esc(sub)}</text>\n`;
  return s;
}

function sourceLegend(x, y) {
  let s = `  <text x="${x}" y="${y + 4}" font-family="sans-serif" font-size="12" font-weight="bold" fill="#0f172a">source</text>\n`;
  let yy = y + 24;
  for (const [name, st] of Object.entries(SOURCE_STYLE)) {
    if (name === "na") continue;
    const fillRef = name === "published" ? "url(#hatch)" : name === "modeled" ? "url(#dots)" : "#475569";
    s += `  <rect x="${x}" y="${yy - 11}" width="22" height="13" fill="${name === "measured" ? "#475569" : "#cbd5e1"}" stroke="#475569" stroke-width="1" ${st.dash ? `stroke-dasharray="${st.dash}"` : ""}/>\n`;
    if (name !== "measured") s += `  <rect x="${x}" y="${yy - 11}" width="22" height="13" fill="${fillRef}"/>\n`;
    s += `  <text x="${x + 28}" y="${yy}" font-family="sans-serif" font-size="11" fill="#334155">${name}${st.tag.trim() ? " " + st.tag.trim() : ""}</text>\n`;
    yy += 20;
  }
  return s;
}

function wrapSvg(W, H, inner, naSeries, spec) {
  let footnote = "";
  if (naSeries && naSeries.length) {
    const names = naSeries.map((s) => `${s.key}${s.dp && s.dp.note ? ` (${s.dp.note})` : ""}`);
    footnote = `  <text x="12" y="${H - 10}" font-family="sans-serif" font-size="10" fill="#94a3b8">n/a (omitted): ${esc(names.join("; "))}</text>\n`;
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(spec.label || spec.key)}">
  <rect x="0" y="0" width="${W}" height="${H}" fill="#ffffff"/>
${svgDefs()}
${inner}
${footnote}</svg>`;
}

// ── source table rows (shared by html + md) ──────────────────────────────────
function sourceRows(contenders, lookup) {
  // lookup(key) -> {source, value/y, artifact, note}
  const rows = [];
  for (const key of contenders) {
    const dp = lookup(key);
    if (!dp) continue;
    rows.push({
      contender: key,
      source: dp.source || "?",
      value: dp.value != null ? fmtNum(dp.value) : Array.isArray(dp.y) ? dp.y.map(fmtNum).join(", ") : "—",
      origin: dp.artifact ? dp.artifact : dp.note ? dp.note : dp.source === "na" ? "no honest number" : "—",
    });
  }
  return rows;
}

// ── winner computation + summary (per-index + overall scoreboard) ────────────
// "in each index" the report declares a winner: the best value on that axis
// (lower- or higher-is-better as the metric/curve labels it), among contenders
// that have an honest number. The winner's source tag is surfaced so a published
// competitor figure can never masquerade as a measured win.
function labelFor(key, data) {
  return (data && data.meta && data.meta.labels && data.meta.labels[key]) || key;
}
const isOurs = (key) => /grobase|binocle/i.test(String(key || ""));

function metricWinner(metric, contenders) {
  const lowerIsBetter = metric.lowerIsBetter !== false;
  const pts = [];
  for (const key of contenders) {
    const dp = (metric.data || {})[key];
    if (!dp || dp.source === "na" || dp.value == null || !Number.isFinite(Number(dp.value))) continue;
    pts.push({ key, value: Number(dp.value), source: dp.source || "measured" });
  }
  if (!pts.length) return null;
  pts.sort((a, b) => (lowerIsBetter ? a.value - b.value : b.value - a.value));
  const winner = pts[0];
  const runner = pts[1] || null;
  let ratio = null, marginPct = null;
  if (runner && winner.value > 0 && runner.value > 0) {
    ratio = lowerIsBetter ? runner.value / winner.value : winner.value / runner.value;
    marginPct = lowerIsBetter
      ? ((runner.value - winner.value) / runner.value) * 100
      : ((winner.value - runner.value) / runner.value) * 100;
  }
  const tie = !!(runner && winner.value === runner.value);
  return { lowerIsBetter, winner, runner, ratio, marginPct, tie, unit: metric.unit || "" };
}

function curveWinner(curve) {
  const yLowerIsBetter = curve.yLowerIsBetter !== false;
  const xs = (curve.x || []).map(Number);
  const xMax = Math.max(...xs.filter(Number.isFinite));
  const i = xs.indexOf(xMax);
  if (i < 0) return null;
  const pts = [];
  for (const [key, ser] of Object.entries(curve.series || {})) {
    if (!ser || ser.source === "na" || !Array.isArray(ser.y)) continue;
    const v = ser.y[i];
    if (v == null || !Number.isFinite(Number(v))) continue;
    pts.push({ key, value: Number(v), source: (ser.pointSources && ser.pointSources[i]) || ser.source || "measured" });
  }
  if (!pts.length) return null;
  pts.sort((a, b) => (yLowerIsBetter ? a.value - b.value : b.value - a.value));
  const winner = pts[0];
  const runner = pts[1] || null;
  let ratio = null;
  if (runner && winner.value > 0 && runner.value > 0) ratio = yLowerIsBetter ? runner.value / winner.value : winner.value / runner.value;
  return { lowerIsBetter: yLowerIsBetter, winner, runner, ratio, marginPct: null, tie: false, unit: curve.unit || "", atX: xMax };
}

function ratioText(w) {
  if (!w) return "";
  if (!w.runner) return "only contender with an honest number on this axis";
  if (w.tie) return "tie";
  const cmp = w.lowerIsBetter ? "lower" : "higher";
  if (w.ratio && w.ratio >= 1.15) return `${fmtNum(w.ratio)}× ${cmp} than runner-up`;
  if (w.marginPct != null) return `${fmtNum(Math.abs(w.marginPct))}% ${cmp} than runner-up`;
  return `${cmp} than runner-up`;
}

function winnerBannerHtml(w, data) {
  if (!w) return "";
  const wl = labelFor(w.winner.key, data);
  const rl = w.runner ? labelFor(w.runner.key, data) : null;
  const cls = isOurs(w.winner.key) ? "winner" : "winner rival";
  const srcTag = w.winner.source && w.winner.source !== "measured" ? ` <span class="wtag">(${esc(w.winner.source)})</span>` : "";
  const vs = rl ? ` — ${esc(ratioText(w))} <span class="wtag">vs ${esc(rl)}</span>` : "";
  return `<div class="${cls}">&#127942; <b>Winner: ${esc(wl)}</b> — ${esc(fmtNum(w.winner.value))} ${esc(w.unit)}${srcTag}${vs}</div>`;
}

function scoreboard(metricCharts, curveCharts, data) {
  const tally = {};
  let contests = 0;
  const record = (w) => {
    if (!w || !w.winner) return;
    contests++;
    const k = w.winner.key;
    tally[k] = (tally[k] || 0) + 1;
  };
  for (const mc of metricCharts) record(mc.winner);
  for (const cc of curveCharts) record(cc.winner);
  const rows = Object.entries(tally)
    .map(([key, wins]) => ({ key, wins, label: labelFor(key, data), ours: isOurs(key) }))
    .sort((a, b) => b.wins - a.wins);
  return { rows, contests, top: rows[0] || null };
}

function scoreboardHtml(sb) {
  if (!sb || !sb.rows.length) return "";
  const maxWins = sb.top.wins || 1;
  const bars = sb.rows
    .map((r) => {
      const pct = Math.round((r.wins / maxWins) * 100);
      const col = r.ours ? "#16a34a" : "#f59e0b";
      return `      <div class="sb-row"><span class="sb-name">${esc(r.label)}</span><span class="sb-bar"><span class="sb-fill" style="width:${pct}%;background:${col}"></span></span><span class="sb-val">${r.wins} / ${sb.contests}</span></div>`;
    })
    .join("\n");
  const headline = sb.top.ours
    ? `<b>${esc(sb.top.label)}</b> wins <b>${sb.top.wins} of ${sb.contests}</b> indexes — the overall winner.`
    : `<b>${esc(sb.top.label)}</b> leads with ${sb.top.wins} of ${sb.contests} indexes.`;
  return `  <section id="scoreboard" style="border-left:4px solid #16a34a">
    <h2>&#127942; Scoreboard — who wins each index</h2>
    <p class="ctx">${headline} One point per metric / scale-curve; the winner is the best value on that axis (lower- or higher-is-better as labelled). Bars scaled to the leader.</p>
    <div class="scoreboard">
${bars}
    </div>
  </section>`;
}

// ── HTML / MD assembly ───────────────────────────────────────────────────────
function buildHtml(data, metricCharts, curveCharts) {
  const css = `body{font-family:system-ui,sans-serif;margin:0;background:#f8fafc;color:#0f172a;line-height:1.5}
header{background:#0f172a;color:#fff;padding:28px 40px}
header h1{margin:0 0 6px;font-size:24px}header p{margin:0;color:#cbd5e1;font-size:14px}
main{max-width:1000px;margin:0 auto;padding:24px 16px 64px}
section{background:#fff;border:1px solid #e2e8f0;border-radius:10px;padding:20px;margin:18px 0;box-shadow:0 1px 2px rgba(0,0,0,.04)}
h2{font-size:20px;margin:6px 0 4px}h3{font-size:16px;margin:24px 0 6px}
.ctx{color:#64748b;font-size:13px;margin:0 0 12px}
svg{max-width:100%;height:auto;display:block;margin:0 auto}
table{border-collapse:collapse;width:100%;font-size:13px;margin-top:12px}
th,td{border:1px solid #e2e8f0;padding:6px 10px;text-align:left}
th{background:#f1f5f9}
.src-measured{color:#16a34a;font-weight:600}.src-published{color:#0891b2}.src-modeled{color:#a16207}.src-na{color:#94a3b8}
.legend{display:flex;gap:18px;flex-wrap:wrap;font-size:13px;color:#475569;margin:8px 0 0}
.legend b{color:#0f172a}
code{background:#f1f5f9;padding:1px 5px;border-radius:4px;font-size:12px}
.note{font-size:12px;color:#64748b;margin-top:8px}
.winner{background:#f0fdf4;border:1px solid #bbf7d0;border-left:4px solid #16a34a;border-radius:8px;padding:9px 13px;margin:10px 0 2px;font-size:14px;color:#14532d}
.winner.rival{background:#fff7ed;border-color:#fed7aa;border-left-color:#d97706;color:#7c2d12}
.wtag{color:#64748b;font-weight:400;font-size:12px}
.scoreboard{display:flex;flex-direction:column;gap:6px;margin-top:10px}
.sb-row{display:flex;align-items:center;gap:10px;font-size:13px}
.sb-name{width:170px;flex:none;text-align:right;color:#334155;font-weight:600}
.sb-bar{flex:1;background:#f1f5f9;border-radius:5px;height:16px;overflow:hidden}
.sb-fill{display:block;height:100%}
.sb-val{width:64px;flex:none;color:#475569;font-variant-numeric:tabular-nums}`;

  const legendHtml = `<div class="legend">
    <span><b>measured</b> — solid/filled, cites an artifact under <code>artifacts/</code></span>
    <span><b>published (pub)</b> — hatched/dashed, vendor docs/pricing — never our measurement</span>
    <span><b>modeled (model)</b> — dotted, states the formula</span>
    <span><b>n/a</b> — no honest number; omitted + footnoted</span>
  </div>`;

  const sectionsM = metricCharts
    .map(
      (mc) => `  <section id="${esc(mc.key)}">
    <h2>${esc(mc.label)}</h2>
    <p class="ctx">${esc(mc.context || "")}${mc.unit ? `  ·  ${esc(mc.unit)}` : ""} — ${mc.lowerIsBetter ? "lower is better" : "higher is better"}</p>
    ${mc.svg}
    ${winnerBannerHtml(mc.winner, data)}
    ${tableHtml(mc.rows)}
  </section>`
    )
    .join("\n");

  const sectionsC = curveCharts
    .map(
      (cc) => `  <section id="${esc(cc.key)}">
    <h2>${esc(cc.label)}</h2>
    <p class="ctx">${esc(cc.context || "")}${cc.unit ? `  ·  ${esc(cc.unit)}` : ""} — x = tenant count (log scale)</p>
    ${cc.svg}
    ${winnerBannerHtml(cc.winner, data)}
    ${tableHtml(cc.rows)}
  </section>`
    )
    .join("\n");

  const m = data.meta || {};
  const sb = scoreboard(metricCharts, curveCharts, data);
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(m.title || "Grobase — Competitive Benchmark")}</title>
<style>${css}</style></head>
<body>
<header>
  <h1>${esc(m.title || "Grobase — Competitive Benchmark")}</h1>
  <p>${esc(m.subtitle || "")}</p>
  <p>Generated ${esc(new Date().toISOString())}${m.generatedFrom ? `  ·  data: <code style="color:#cbd5e1">${esc(m.generatedFrom)}</code>` : ""}</p>
</header>
<main>
${scoreboardHtml(sb)}
  <section>
    <h2>How to read these charts</h2>
    ${legendHtml}
    <p class="note">${esc(m.honestyNote || "Every datapoint carries a source. measured numbers cite an artifact; published numbers cite their origin and are the vendor's claim, not ours; modeled numbers state their formula; n/a means we have no honest number (e.g. Firebase is fully managed — no self-host footprint).")}</p>
  </section>
  <h3>Single-metric comparisons</h3>
${sectionsM || '  <section><p class="ctx">No metrics.</p></section>'}
  <h3>Scale curves — y vs. tenant count</h3>
${sectionsC || '  <section><p class="ctx">No scale curves.</p></section>'}
</main>
</body></html>`;
}

function tableHtml(rows) {
  if (!rows || !rows.length) return "";
  const body = rows
    .map(
      (r) =>
        `      <tr><td>${esc(r.contender)}</td><td class="src-${esc(r.source)}">${esc(r.source)}</td><td>${esc(r.value)}</td><td><code>${esc(r.origin)}</code></td></tr>`
    )
    .join("\n");
  return `<table>
      <thead><tr><th>contender</th><th>source</th><th>value</th><th>artifact / origin</th></tr></thead>
      <tbody>
${body}
      </tbody>
    </table>`;
}

function winnerLineMd(w, data) {
  if (!w) return "";
  const wl = labelFor(w.winner.key, data);
  const tag = w.winner.source && w.winner.source !== "measured" ? ` _(${w.winner.source})_` : "";
  const vs = w.runner ? ` — ${ratioText(w)} vs ${labelFor(w.runner.key, data)}` : "";
  return `**🏆 Winner: ${wl}** — ${fmtNum(w.winner.value)} ${w.unit}${tag}${vs}\n\n`;
}

function scoreboardMd(sb) {
  if (!sb || !sb.rows.length) return "";
  let s = `## 🏆 Scoreboard — who wins each index\n\n`;
  s += sb.top.ours
    ? `**${sb.top.label}** wins **${sb.top.wins} of ${sb.contests}** indexes — the overall winner.\n\n`
    : `**${sb.top.label}** leads with ${sb.top.wins} of ${sb.contests} indexes.\n\n`;
  s += `| contender | indexes won |\n|---|---|\n`;
  for (const r of sb.rows) s += `| ${r.label} | ${r.wins} / ${sb.contests} |\n`;
  return s + `\n`;
}

function buildMarkdown(data, metricCharts, curveCharts, relCharts) {
  const m = data.meta || {};
  let md = `# ${m.title || "Grobase — Competitive Benchmark"}\n\n`;
  if (m.subtitle) md += `${m.subtitle}\n\n`;
  md += `_Generated ${new Date().toISOString()}${m.generatedFrom ? `  ·  data: \`${m.generatedFrom}\`` : ""}_\n\n`;
  md += `## How to read\n\n`;
  md += `| source | style | meaning |\n|---|---|---|\n`;
  md += `| measured | solid/filled | cites an artifact under \`artifacts/\` (our measurement) |\n`;
  md += `| published (pub) | hatched/dashed | vendor docs/pricing — the vendor's claim, **not** ours |\n`;
  md += `| modeled (model) | dotted | derived; states its formula |\n`;
  md += `| n/a | omitted | no honest number (e.g. Firebase has no self-host footprint) |\n\n`;
  if (m.honestyNote) md += `> ${m.honestyNote}\n\n`;

  md += scoreboardMd(scoreboard(metricCharts, curveCharts, data));

  md += `## Single-metric comparisons\n\n`;
  for (const mc of metricCharts) {
    md += `### ${mc.label}\n\n`;
    md += `${mc.context || ""}${mc.unit ? ` · ${mc.unit}` : ""} — ${mc.lowerIsBetter ? "lower is better" : "higher is better"}\n\n`;
    md += `![${mc.label}](${relCharts}/${mc.key}.svg)\n\n`;
    md += winnerLineMd(mc.winner, data);
    md += mdTable(mc.rows);
    md += `\n`;
  }
  md += `## Scale curves — y vs. tenant count\n\n`;
  for (const cc of curveCharts) {
    md += `### ${cc.label}\n\n`;
    md += `${cc.context || ""}${cc.unit ? ` · ${cc.unit}` : ""} — x = tenant count (log scale)\n\n`;
    md += `![${cc.label}](${relCharts}/${cc.key}.svg)\n\n`;
    md += winnerLineMd(cc.winner, data);
    md += mdTable(cc.rows);
    md += `\n`;
  }
  return md;
}

function mdTable(rows) {
  if (!rows || !rows.length) return "_(no data)_\n";
  let t = `| contender | source | value | artifact / origin |\n|---|---|---|---|\n`;
  for (const r of rows) t += `| ${r.contender} | ${r.source} | ${r.value} | \`${r.origin}\` |\n`;
  return t;
}

// ── normalization — accept BOTH documented shapes ───────────────────────────
// The SPEC describes: metrics/scaleCurves as arrays; metric.data; curve
// series[key].y aligned to x; meta.contenders = string[]. The dataset agent
// shipped an equivalent keyed-object shape: metrics/scaleCurves as objects keyed
// by key; metric.values; curve series[key].points = [{x,y,source,…}]; a top-level
// contenders object map; curve unit as yUnit. normalize() folds either form into
// the canonical SPEC shape so the renderers stay simple and the two parallel
// pieces compose regardless of which shape lands.
function asArray(coll) {
  if (Array.isArray(coll)) return coll.filter(Boolean);
  if (coll && typeof coll === "object")
    return Object.entries(coll).map(([key, v]) => ({ key, ...(v || {}) }));
  return [];
}

function normalize(data) {
  const out = { meta: { ...(data.meta || {}) }, metrics: [], scaleCurves: [] };
  // title/subtitle/generated may live at top level (dataset agent) or in meta
  out.meta.title = out.meta.title || data.title;
  out.meta.subtitle = out.meta.subtitle || data.subtitle || (data.meta && data.meta.method);
  out.meta.generatedFrom = out.meta.generatedFrom || data.generatedFrom;
  out.meta.honestyNote =
    out.meta.honestyNote ||
    (data.meta && (data.meta.honestyNote || (Array.isArray(data.meta.caveats) ? data.meta.caveats.join("  ·  ") : data.meta.caveats)));

  // contenders: string[] (SPEC) | object map (dataset) → ordered string[] + label map
  const labels = {};
  let contenders = [];
  const csrc = data.meta?.contenders || data.contenders;
  if (Array.isArray(csrc)) contenders = csrc.slice();
  else if (csrc && typeof csrc === "object") {
    contenders = Object.keys(csrc);
    for (const [k, v] of Object.entries(csrc)) if (v && v.label) labels[k] = v.label;
  }
  out.meta.contenders = contenders;
  out.meta.labels = labels;

  // metrics
  for (const m of asArray(data.metrics)) {
    const datapoints = m.data || m.values || {};
    out.metrics.push({
      key: m.key,
      label: m.label || m.key,
      unit: m.unit || "",
      context: m.context || m.description || "",
      lowerIsBetter: m.lowerIsBetter !== false,
      data: datapoints,
    });
  }

  // scale curves
  for (const c of asArray(data.scaleCurves)) {
    const x = (c.x || []).map(Number);
    const series = {};
    for (const [sk, sv] of Object.entries(c.series || {})) {
      if (!sv) continue;
      // points[] form → align to x, derive a series-level source
      if (Array.isArray(sv.points)) {
        const yByX = new Map(sv.points.map((p) => [Number(p.x), p]));
        const y = x.map((xv) => {
          const p = yByX.get(xv);
          return p && p.y != null && p.source !== "na" ? Number(p.y) : null;
        });
        const pointSources = x.map((xv) => {
          const p = yByX.get(xv);
          return p ? p.source || "measured" : "na";
        });
        const real = sv.points.filter((p) => p.y != null && p.source !== "na");
        const seriesSource =
          sv.source ||
          (real.length ? real[0].source : "na") ||
          "measured";
        series[sk] = {
          label: sv.label || sk,
          source: seriesSource,
          y,
          pointSources,
          note: sv.note || (real[0] && real[0].note),
          artifact: sv.artifact || (real[0] && real[0].artifact),
        };
      } else {
        // y[] form (SPEC) — already aligned
        series[sk] = {
          label: sv.label || sk,
          source: sv.source || "measured",
          y: Array.isArray(sv.y) ? sv.y : null,
          note: sv.note,
          artifact: sv.artifact,
        };
      }
    }
    out.scaleCurves.push({
      key: c.key,
      label: c.label || c.key,
      unit: c.unit || c.yUnit || "",
      xUnit: c.xUnit || "",
      yLog: c.yLog === true,
      yLowerIsBetter: c.yLowerIsBetter !== false,
      context: c.context || c.description || "",
      x,
      series,
    });
  }
  return out;
}

// ── main ─────────────────────────────────────────────────────────────────────
function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!existsSync(args.data)) {
    console.error(`error: data file not found: ${args.data}`);
    console.error(`(the dataset is produced by the dataset agent at scripts/bench/compare-data.json)`);
    process.exit(2);
  }
  let raw;
  try {
    raw = JSON.parse(readFileSync(args.data, "utf8"));
  } catch (e) {
    console.error(`error: cannot parse JSON in ${args.data}: ${e.message}`);
    process.exit(2);
  }
  const data = normalize(raw);

  const contenders =
    (data.meta && Array.isArray(data.meta.contenders) && data.meta.contenders.length
      ? data.meta.contenders
      : null) ||
    deriveContenders(data);

  const outDir = resolve(args.out);
  const chartsDir = join(outDir, "charts");
  mkdirSync(chartsDir, { recursive: true });

  const metricCharts = [];
  for (const metric of data.metrics || []) {
    if (!metric || !metric.key) continue;
    const svg = barChart(metric, contenders);
    writeFileSync(join(chartsDir, `${metric.key}.svg`), svg);
    metricCharts.push({
      key: metric.key,
      label: metric.label || metric.key,
      context: metric.context || "",
      unit: metric.unit || "",
      lowerIsBetter: metric.lowerIsBetter !== false,
      svg,
      winner: metricWinner(metric, contenders),
      rows: sourceRows(contenders, (k) => (metric.data || {})[k]),
    });
  }

  const curveCharts = [];
  for (const curve of data.scaleCurves || []) {
    if (!curve || !curve.key) continue;
    const svg = lineChart(curve, contenders);
    writeFileSync(join(chartsDir, `${curve.key}.svg`), svg);
    // a curve's series keys can be descriptive (e.g. grobase-shared_rls), not the
    // canonical contender list — iterate the actual series keys for its table.
    const curveKeys = Object.keys(curve.series || {});
    curveCharts.push({
      key: curve.key,
      label: curve.label || curve.key,
      context: curve.context || "",
      unit: curve.unit || "",
      svg,
      winner: curveWinner(curve),
      rows: sourceRows(curveKeys, (k) => (curve.series || {})[k]),
    });
  }

  const html = buildHtml(data, metricCharts, curveCharts);
  writeFileSync(join(outDir, "index.html"), html);

  const md = buildMarkdown(data, metricCharts, curveCharts, "charts");
  writeFileSync(join(outDir, "report.md"), md);

  console.log(
    `compare-report: wrote ${metricCharts.length + curveCharts.length} charts ` +
      `(${metricCharts.length} metrics, ${curveCharts.length} scale curves) for ${contenders.length} contenders → ${outDir}`
  );
}

function deriveContenders(data) {
  const seen = new Set();
  for (const m of data.metrics || []) for (const k of Object.keys(m.data || {})) seen.add(k);
  for (const c of data.scaleCurves || []) for (const k of Object.keys(c.series || {})) seen.add(k);
  // canonical order if present
  const ORDER = [
    "grobase-nano",
    "grobase-basic",
    "grobase-essential",
    "grobase-pro",
    "grobase-max",
    "pocketbase",
    "supabase-selfhost",
    "supabase-cloud",
    "firebase",
  ];
  const ordered = ORDER.filter((k) => seen.has(k));
  const extra = [...seen].filter((k) => !ORDER.includes(k));
  return [...ordered, ...extra];
}

main();
