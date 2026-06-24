// lib-report.mjs — shared design-system for Grobase BaaS reports.
// Zero-dep ESM. No external packages, no network, no Date.now()/Math.random().
// Single source of truth for palette, theme CSS, and all chart/visual helpers.

export const PALETTE = {
  win: '#1f9d57', parity: '#d99a16', gap: '#c64242', brand: '#5b6cff',
  ink: '#0e1726', muted: '#5b6781', bg: '#f6f8fc', card: '#ffffff', line: '#e3e8f2',
  supabase: '#3ecf8e', firebase: '#ffa000', grobase: '#5b6cff', pocketbase: '#8a8a8a'
};

// ---- internals -------------------------------------------------------------

const esc = (s) => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

const toneColor = (tone) => ({
  win: PALETTE.win, parity: PALETTE.parity, gap: PALETTE.gap,
  brand: PALETTE.brand, neutral: PALETTE.muted
}[tone] || PALETTE.muted);

// tone for value bars; lowerIsBetter flips win/gap meaning when a tone isn't given
const resolveBarTone = (d, lowerIsBetter) => {
  if (d.tone) return toneColor(d.tone);
  return lowerIsBetter ? PALETTE.win : PALETTE.brand;
};

// format a number with thin grouping, leave strings alone
const fmt = (v) => {
  if (typeof v !== 'number' || !isFinite(v)) return esc(v);
  const neg = v < 0; const a = Math.abs(v);
  const s = a % 1 === 0 ? String(a) : String(Math.round(a * 1000) / 1000);
  const [intp, dec] = s.split('.');
  const grouped = intp.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return (neg ? '-' : '') + grouped + (dec ? '.' + dec : '');
};

const niceMax = (max) => {
  if (max <= 0) return 1;
  const exp = Math.floor(Math.log10(max));
  const base = Math.pow(10, exp);
  for (const m of [1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 7.5, 10]) {
    if (base * m >= max) return base * m;
  }
  return base * 10;
};

// ---- page shell ------------------------------------------------------------

export function renderPage({ title, subtitle, accent, updated, sections }) {
  const ac = accent || PALETTE.brand;
  const body = (sections || []).join('\n');
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<style>
:root{
  --win:${PALETTE.win};--parity:${PALETTE.parity};--gap:${PALETTE.gap};--brand:${PALETTE.brand};
  --ink:${PALETTE.ink};--muted:${PALETTE.muted};--bg:${PALETTE.bg};--card:${PALETTE.card};
  --line:${PALETTE.line};--accent:${ac};
  --shadow:0 1px 2px rgba(16,23,38,.04),0 6px 24px rgba(16,23,38,.07);
  --radius:14px;
}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{
  margin:0;background:var(--bg);color:var(--ink);line-height:1.55;
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,
    "Apple Color Emoji","Segoe UI Emoji",sans-serif;
  font-size:15px;-webkit-font-smoothing:antialiased;
}
.wrap{max-width:960px;margin:0 auto;padding:0 20px 64px}
header.site{
  position:sticky;top:0;z-index:50;
  background:linear-gradient(110deg,var(--accent),color-mix(in srgb,var(--accent) 55%,#1b2447));
  color:#fff;box-shadow:0 4px 18px rgba(16,23,38,.18);
}
@supports not (background:color-mix(in srgb,#000,#fff)){
  header.site{background:linear-gradient(110deg,var(--accent),#2a3566)}
}
.site .inner{max-width:960px;margin:0 auto;padding:22px 20px}
.site h1{margin:0;font-size:24px;font-weight:700;letter-spacing:-.01em}
.site .sub{margin:6px 0 0;opacity:.92;font-size:14.5px;font-weight:400}
.site .upd{margin-top:10px;font-size:12px;opacity:.8;font-variant-numeric:tabular-nums}
section{margin-top:30px}
section>h2{
  font-size:18px;margin:0 0 4px;letter-spacing:-.01em;
  padding-bottom:8px;border-bottom:2px solid var(--line);
}
section .intro{color:var(--muted);margin:8px 0 16px;font-size:14.5px}
.card{
  background:var(--card);border:1px solid var(--line);border-radius:var(--radius);
  box-shadow:var(--shadow);padding:18px;
}
.grid{display:grid;gap:14px}
.kpis{grid-template-columns:repeat(auto-fit,minmax(170px,1fr));margin-top:6px}
.kpi{
  background:var(--card);border:1px solid var(--line);border-left:4px solid var(--muted);
  border-radius:var(--radius);box-shadow:var(--shadow);padding:16px 16px 14px;
}
.kpi.win{border-left-color:var(--win)} .kpi.parity{border-left-color:var(--parity)}
.kpi.gap{border-left-color:var(--gap)} .kpi.neutral{border-left-color:var(--muted)}
.kpi .label{font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
.kpi .value{font-size:27px;font-weight:700;margin:4px 0 2px;font-variant-numeric:tabular-nums;letter-spacing:-.02em}
.kpi .sub{font-size:12.5px;color:var(--muted)}
.kpi.win .value{color:var(--win)} .kpi.gap .value{color:var(--gap)} .kpi.parity .value{color:var(--parity)}
.scoreboard{
  display:flex;flex-wrap:wrap;gap:0;background:var(--card);border:1px solid var(--line);
  border-radius:var(--radius);box-shadow:var(--shadow);overflow:hidden;margin-top:6px;
}
.scoreboard .sb-title{padding:14px 16px;font-weight:600;font-size:13px;color:var(--muted);
  align-self:center;border-right:1px solid var(--line)}
.scoreboard .stat{padding:12px 18px;border-right:1px solid var(--line);min-width:96px}
.scoreboard .stat:last-child{border-right:none}
.scoreboard .stat .v{font-size:20px;font-weight:700;font-variant-numeric:tabular-nums}
.scoreboard .stat .l{font-size:11.5px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
.scoreboard .stat.win .v{color:var(--win)} .scoreboard .stat.gap .v{color:var(--gap)}
.scoreboard .stat.parity .v{color:var(--parity)}
.badge{
  display:inline-block;padding:2px 9px;border-radius:999px;font-size:11.5px;font-weight:600;
  line-height:1.5;border:1px solid transparent;vertical-align:middle;
}
.badge.win{background:rgba(31,157,87,.12);color:var(--win);border-color:rgba(31,157,87,.25)}
.badge.parity{background:rgba(217,154,22,.13);color:#9a6b07;border-color:rgba(217,154,22,.3)}
.badge.gap{background:rgba(198,66,66,.12);color:var(--gap);border-color:rgba(198,66,66,.25)}
.badge.brand{background:rgba(91,108,255,.12);color:var(--brand);border-color:rgba(91,108,255,.25)}
.badge.neutral{background:rgba(91,103,129,.1);color:var(--muted);border-color:rgba(91,103,129,.22)}
figure.chart{margin:0;background:var(--card);border:1px solid var(--line);border-radius:var(--radius);
  box-shadow:var(--shadow);padding:16px 16px 12px}
figure.chart .chart-title{font-weight:600;font-size:14.5px;margin:0 0 10px}
figure.chart figcaption{color:var(--muted);font-size:12px;margin-top:8px}
figure.chart svg{display:block;width:100%;height:auto}
.legend{display:flex;flex-wrap:wrap;gap:14px;margin-top:10px;font-size:12.5px;color:var(--muted)}
.legend .li{display:inline-flex;align-items:center;gap:6px}
.legend .sw{width:11px;height:11px;border-radius:3px;display:inline-block}
table.matrix{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);
  border-radius:var(--radius);overflow:hidden;box-shadow:var(--shadow);font-size:13.5px}
table.matrix th,table.matrix td{padding:9px 12px;text-align:left;border-bottom:1px solid var(--line);
  vertical-align:top}
table.matrix thead th{background:#eef2fb;font-size:12px;text-transform:uppercase;letter-spacing:.04em;
  color:var(--muted);font-weight:600}
table.matrix tbody tr:nth-child(even){background:#fbfcfe}
table.matrix tbody tr:last-child td{border-bottom:none}
td.t-win{background:rgba(31,157,87,.1)} td.t-parity{background:rgba(217,154,22,.12)}
td.t-gap{background:rgba(198,66,66,.1)} td.t-brand{background:rgba(91,108,255,.1)}
.callouts{grid-template-columns:repeat(auto-fit,minmax(230px,1fr))}
.callout{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--muted);
  border-radius:var(--radius);box-shadow:var(--shadow);padding:14px 16px}
.callout.win{border-left-color:var(--win)} .callout.parity{border-left-color:var(--parity)}
.callout.gap{border-left-color:var(--gap)} .callout.brand{border-left-color:var(--brand)}
.callout .c-head{display:flex;align-items:center;justify-content:space-between;gap:8px}
.callout .c-title{font-weight:650;font-size:14.5px}
.callout .c-body{color:var(--muted);font-size:13px;margin-top:6px}
.layers{display:flex;flex-direction:column;gap:8px}
.layer{border:1px solid var(--line);border-radius:10px;padding:12px 16px;background:var(--card);
  box-shadow:var(--shadow);position:relative}
.layer .ln{font-weight:650;font-size:14px} .layer .ld{color:var(--muted);font-size:12.5px;margin-top:2px}
.layer.win{border-left:4px solid var(--win)} .layer.parity{border-left:4px solid var(--parity)}
.layer.gap{border-left:4px solid var(--gap)} .layer.brand{border-left:4px solid var(--brand)}
.evidence{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);
  box-shadow:var(--shadow);padding:16px}
.evidence .e-head{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:10px}
.evidence .e-title{font-weight:650;font-size:14.5px}
.evidence pre{margin:0;background:#0e1726;color:#d7e2f7;border-radius:10px;padding:12px 14px;
  font-size:12.5px;line-height:1.55;overflow:auto;
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}
.evidence .e-gate{margin-top:10px;font-size:12px;color:var(--muted)}
.evidence .e-gate code{background:#eef2fb;padding:2px 6px;border-radius:5px;
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
footer.site{margin-top:48px;border-top:1px solid var(--line);padding:22px 20px;color:var(--muted);
  font-size:12.5px;text-align:center}
footer.site .wrap{padding-bottom:0}
@media (max-width:560px){
  .scoreboard{flex-direction:column}
  .scoreboard .sb-title,.scoreboard .stat{border-right:none;border-bottom:1px solid var(--line)}
  .scoreboard .stat:last-child{border-bottom:none}
  .site h1{font-size:21px}
}
@media print{
  body{background:#fff}
  header.site{position:static;box-shadow:none;color:#0e1726;background:#fff;border-bottom:2px solid var(--accent)}
  .card,.kpi,figure.chart,.evidence,table.matrix,.scoreboard,.callout,.layer{box-shadow:none}
  section{break-inside:avoid}
}
</style>
</head>
<body>
<header class="site"><div class="inner">
  <h1>${esc(title)}</h1>
  ${subtitle ? `<p class="sub">${esc(subtitle)}</p>` : ''}
  ${updated ? `<div class="upd">Updated ${esc(updated)}</div>` : ''}
</div></header>
<main class="wrap">
${body}
</main>
<footer class="site"><div class="wrap">Grobase BaaS — measured, not claimed. Every figure traces to an artifact or doc.</div></footer>
</body>
</html>`;
}

// ---- section ---------------------------------------------------------------

export function section({ id, title, intro, body }) {
  return `<section${id ? ` id="${esc(id)}"` : ''}>
  <h2>${esc(title)}</h2>
  ${intro ? `<p class="intro">${intro}</p>` : ''}
  ${body || ''}
</section>`;
}

// ---- KPI grid --------------------------------------------------------------

export function kpiGrid(cards) {
  const items = (cards || []).map((c) => {
    const tone = ['win', 'parity', 'gap', 'neutral'].includes(c.tone) ? c.tone : 'neutral';
    return `<div class="kpi ${tone}">
    <div class="label">${esc(c.label)}</div>
    <div class="value">${typeof c.value === 'number' ? fmt(c.value) : esc(c.value)}</div>
    ${c.sub ? `<div class="sub">${esc(c.sub)}</div>` : ''}
  </div>`;
  }).join('\n');
  return `<div class="grid kpis">${items}</div>`;
}

// ---- scoreboard ------------------------------------------------------------

export function scoreboard({ title, items }) {
  const stats = (items || []).map((it) => {
    const tone = ['win', 'parity', 'gap', 'neutral'].includes(it.tone) ? it.tone : 'neutral';
    return `<div class="stat ${tone}">
    <div class="v">${typeof it.value === 'number' ? fmt(it.value) : esc(it.value)}</div>
    <div class="l">${esc(it.label)}</div>
  </div>`;
  }).join('\n');
  return `<div class="scoreboard">
  ${title ? `<div class="sb-title">${esc(title)}</div>` : ''}
  ${stats}
</div>`;
}

// ---- badge -----------------------------------------------------------------

export function badge(text, tone) {
  const t = ['win', 'parity', 'gap', 'brand', 'neutral'].includes(tone) ? tone : 'neutral';
  return `<span class="badge ${t}">${esc(text)}</span>`;
}

// ---- bar chart (horizontal) ------------------------------------------------

export function barChart({ title, unit, data, lowerIsBetter, height }) {
  const rows = data || [];
  const W = 720, padL = 150, padR = 70, padT = 8, padB = 8;
  const rowH = 30, gap = 10;
  const H = height || (padT + padB + rows.length * rowH + Math.max(0, rows.length - 1) * gap);
  const max = niceMax(Math.max(1, ...rows.map((d) => (typeof d.value === 'number' ? d.value : 0))));
  const plotW = W - padL - padR;
  const x = (v) => padL + (Math.max(0, v) / max) * plotW;

  // vertical gridlines
  const ticks = 4; let grid = '';
  for (let i = 0; i <= ticks; i++) {
    const gx = padL + (i / ticks) * plotW;
    const gv = (max * i) / ticks;
    grid += `<line x1="${gx.toFixed(1)}" y1="${padT}" x2="${gx.toFixed(1)}" y2="${H - padB}" stroke="${PALETTE.line}" stroke-width="1"/>`;
    grid += `<text x="${gx.toFixed(1)}" y="${H - padB + 12}" font-size="10" fill="${PALETTE.muted}" text-anchor="middle">${fmt(gv)}</text>`;
  }

  let bars = '';
  rows.forEach((d, i) => {
    const y = padT + i * (rowH + gap);
    const val = typeof d.value === 'number' ? d.value : 0;
    const w = Math.max(1, x(val) - padL);
    const color = resolveBarTone(d, lowerIsBetter);
    bars += `<text x="${padL - 10}" y="${(y + rowH / 2 + 4).toFixed(1)}" font-size="12" fill="${PALETTE.ink}" text-anchor="end">${esc(d.label)}</text>`;
    bars += `<rect x="${padL}" y="${y.toFixed(1)}" width="${w.toFixed(1)}" height="${rowH}" rx="5" fill="${color}"/>`;
    const vlabel = `${fmt(val)}${unit ? ' ' + unit : ''}`;
    bars += `<text x="${(padL + w + 8).toFixed(1)}" y="${(y + rowH / 2 + 4).toFixed(1)}" font-size="11.5" fill="${PALETTE.ink}" text-anchor="start">${esc(vlabel)}${d.note ? ` <tspan fill="${PALETTE.muted}">· ${esc(d.note)}</tspan>` : ''}</text>`;
  });

  const caption = `Bars show ${esc(unit || 'value')}${lowerIsBetter ? ' — lower is better' : ' — higher is better'}.`;
  return `<figure class="chart">
  <p class="chart-title">${esc(title)}</p>
  <svg viewBox="0 0 ${W} ${H + 16}" role="img" aria-label="${esc(title)}">
    ${grid}
    ${bars}
  </svg>
  <figcaption>${caption}</figcaption>
</figure>`;
}

// ---- grouped bars (vertical) -----------------------------------------------

export function groupedBars({ title, unit, groups, series, lowerIsBetter }) {
  const gs = groups || [], ss = series || [];
  const W = 720, padL = 56, padR = 16, padT = 14, padB = 46;
  const H = 320;
  const plotW = W - padL - padR, plotH = H - padT - padB;
  let allVals = [];
  ss.forEach((s) => (s.values || []).forEach((v) => allVals.push(typeof v === 'number' ? v : 0)));
  const max = niceMax(Math.max(1, ...allVals));
  const y = (v) => padT + plotH - (Math.max(0, v) / max) * plotH;

  // horizontal gridlines
  const ticks = 4; let grid = '';
  for (let i = 0; i <= ticks; i++) {
    const gy = padT + plotH - (i / ticks) * plotH;
    const gv = (max * i) / ticks;
    grid += `<line x1="${padL}" y1="${gy.toFixed(1)}" x2="${W - padR}" y2="${gy.toFixed(1)}" stroke="${PALETTE.line}" stroke-width="1"/>`;
    grid += `<text x="${padL - 8}" y="${(gy + 3).toFixed(1)}" font-size="10" fill="${PALETTE.muted}" text-anchor="end">${fmt(gv)}</text>`;
  }

  const groupW = plotW / Math.max(1, gs.length);
  const innerPad = groupW * 0.18;
  const barAreaW = groupW - innerPad * 2;
  const nSeries = Math.max(1, ss.length);
  const barW = barAreaW / nSeries;

  let bars = '', labels = '';
  gs.forEach((g, gi) => {
    const gx0 = padL + gi * groupW + innerPad;
    ss.forEach((s, si) => {
      const v = typeof (s.values || [])[gi] === 'number' ? s.values[gi] : 0;
      const bx = gx0 + si * barW;
      const by = y(v);
      const bh = Math.max(1, padT + plotH - by);
      const color = s.color || PALETTE.brand;
      bars += `<rect x="${bx.toFixed(1)}" y="${by.toFixed(1)}" width="${(barW - 2).toFixed(1)}" height="${bh.toFixed(1)}" rx="3" fill="${color}"/>`;
      if (nSeries <= 4) {
        bars += `<text x="${(bx + (barW - 2) / 2).toFixed(1)}" y="${(by - 4).toFixed(1)}" font-size="9.5" fill="${PALETTE.ink}" text-anchor="middle">${fmt(v)}</text>`;
      }
    });
    labels += `<text x="${(padL + gi * groupW + groupW / 2).toFixed(1)}" y="${H - padB + 18}" font-size="11" fill="${PALETTE.ink}" text-anchor="middle">${esc(g)}</text>`;
  });

  const legend = ss.map((s) =>
    `<span class="li"><span class="sw" style="background:${s.color || PALETTE.brand}"></span>${esc(s.name)}</span>`
  ).join('');

  const caption = `${esc(unit || 'value')}${lowerIsBetter ? ' — lower is better' : ' — higher is better'}.`;
  return `<figure class="chart">
  <p class="chart-title">${esc(title)}</p>
  <svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(title)}">
    ${grid}
    <line x1="${padL}" y1="${padT + plotH}" x2="${W - padR}" y2="${padT + plotH}" stroke="${PALETTE.muted}" stroke-width="1"/>
    ${bars}
    ${labels}
  </svg>
  <div class="legend">${legend}</div>
  <figcaption>${caption}</figcaption>
</figure>`;
}

// ---- donut -----------------------------------------------------------------

export function donut({ title, slices, centerLabel }) {
  const sl = (slices || []).filter((s) => (typeof s.value === 'number' ? s.value : 0) > 0);
  const total = sl.reduce((a, s) => a + s.value, 0) || 1;
  const cx = 110, cy = 110, r = 92, rin = 56;
  let acc = -Math.PI / 2; // start at top
  let paths = '';
  sl.forEach((s) => {
    const frac = s.value / total;
    const a0 = acc, a1 = acc + frac * 2 * Math.PI;
    acc = a1;
    const large = (a1 - a0) > Math.PI ? 1 : 0;
    const x0 = cx + r * Math.cos(a0), y0 = cy + r * Math.sin(a0);
    const x1 = cx + r * Math.cos(a1), y1 = cy + r * Math.sin(a1);
    const xi1 = cx + rin * Math.cos(a1), yi1 = cy + rin * Math.sin(a1);
    const xi0 = cx + rin * Math.cos(a0), yi0 = cy + rin * Math.sin(a0);
    paths += `<path d="M ${x0.toFixed(2)} ${y0.toFixed(2)} A ${r} ${r} 0 ${large} 1 ${x1.toFixed(2)} ${y1.toFixed(2)} L ${xi1.toFixed(2)} ${yi1.toFixed(2)} A ${rin} ${rin} 0 ${large} 0 ${xi0.toFixed(2)} ${yi0.toFixed(2)} Z" fill="${s.color || PALETTE.brand}"/>`;
  });

  const legend = sl.map((s) => {
    const pct = ((s.value / total) * 100);
    const pctTxt = (pct % 1 === 0 ? pct.toFixed(0) : pct.toFixed(1));
    return `<span class="li"><span class="sw" style="background:${s.color || PALETTE.brand}"></span>${esc(s.label)} — <strong style="color:${PALETTE.ink}">${fmt(s.value)}</strong> (${pctTxt}%)</span>`;
  }).join('');

  const center = centerLabel
    ? `<text x="${cx}" y="${cy - 4}" font-size="20" font-weight="700" fill="${PALETTE.ink}" text-anchor="middle">${esc(centerLabel)}</text>
       <text x="${cx}" y="${cy + 16}" font-size="11" fill="${PALETTE.muted}" text-anchor="middle">total ${fmt(total)}</text>`
    : `<text x="${cx}" y="${cy + 5}" font-size="18" font-weight="700" fill="${PALETTE.ink}" text-anchor="middle">${fmt(total)}</text>`;

  return `<figure class="chart">
  <p class="chart-title">${esc(title)}</p>
  <svg viewBox="0 0 220 220" role="img" aria-label="${esc(title)}" style="max-width:260px;margin:0 auto">
    ${paths}
    ${center}
  </svg>
  <div class="legend">${legend}</div>
</figure>`;
}

// ---- gauge -----------------------------------------------------------------

export function gauge({ title, value, max, label, tone }) {
  const mx = max || 100;
  const v = Math.max(0, Math.min(mx, typeof value === 'number' ? value : 0));
  const frac = v / mx;
  const cx = 120, cy = 122, r = 92;
  const a0 = Math.PI, a1 = 0; // left to right semicircle
  const ang = a0 + frac * (a1 - a0);
  const arcPt = (a, rr) => `${(cx + rr * Math.cos(a)).toFixed(2)} ${(cy + rr * Math.sin(a)).toFixed(2)}`;
  const track = `<path d="M ${arcPt(a0, r)} A ${r} ${r} 0 0 1 ${arcPt(a1, r)}" fill="none" stroke="${PALETTE.line}" stroke-width="16" stroke-linecap="round"/>`;
  const col = toneColor(tone || 'brand');
  const fill = `<path d="M ${arcPt(a0, r)} A ${r} ${r} 0 0 1 ${arcPt(ang, r)}" fill="none" stroke="${col}" stroke-width="16" stroke-linecap="round"/>`;
  const nx = cx + (r - 6) * Math.cos(ang), ny = cy + (r - 6) * Math.sin(ang);
  const needle = `<line x1="${cx}" y1="${cy}" x2="${nx.toFixed(2)}" y2="${ny.toFixed(2)}" stroke="${PALETTE.ink}" stroke-width="3" stroke-linecap="round"/>
    <circle cx="${cx}" cy="${cy}" r="6" fill="${PALETTE.ink}"/>`;
  const valTxt = `<text x="${cx}" y="${cy - 18}" font-size="28" font-weight="700" fill="${col}" text-anchor="middle">${fmt(v)}</text>`;
  const minMax = `<text x="${cx - r}" y="${cy + 20}" font-size="10" fill="${PALETTE.muted}" text-anchor="middle">0</text>
    <text x="${cx + r}" y="${cy + 20}" font-size="10" fill="${PALETTE.muted}" text-anchor="middle">${fmt(mx)}</text>`;
  const lab = label ? `<text x="${cx}" y="${cy + 30}" font-size="12" fill="${PALETTE.muted}" text-anchor="middle">${esc(label)}</text>` : '';

  return `<figure class="chart">
  <p class="chart-title">${esc(title)}</p>
  <svg viewBox="0 0 240 150" role="img" aria-label="${esc(title)}" style="max-width:280px;margin:0 auto">
    ${track}${fill}${valTxt}${needle}${minMax}${lab}
  </svg>
</figure>`;
}

// ---- matrix table ----------------------------------------------------------

export function matrixTable({ columns, rows }) {
  const head = `<thead><tr>${(columns || []).map((c) => `<th>${esc(c)}</th>`).join('')}</tr></thead>`;
  const body = `<tbody>${(rows || []).map((r) =>
    `<tr>${(r || []).map((cell) => {
      if (cell && typeof cell === 'object') {
        const tone = ['win', 'parity', 'gap', 'brand'].includes(cell.tone) ? ` t-${cell.tone}` : '';
        return `<td class="td${tone}">${cell.text == null ? '' : esc(cell.text)}</td>`;
      }
      return `<td>${esc(cell)}</td>`;
    }).join('')}</tr>`
  ).join('')}</tbody>`;
  return `<table class="matrix">${head}${body}</table>`;
}

// ---- callout grid ----------------------------------------------------------

export function calloutGrid(items) {
  const cards = (items || []).map((it) => {
    const tone = ['win', 'parity', 'gap', 'brand'].includes(it.tone) ? it.tone : 'brand';
    return `<div class="callout ${tone}">
    <div class="c-head">
      <span class="c-title">${esc(it.title)}</span>
      ${it.badge ? badge(it.badge, tone) : ''}
    </div>
    ${it.body ? `<div class="c-body">${esc(it.body)}</div>` : ''}
  </div>`;
  }).join('\n');
  return `<div class="grid callouts">${cards}</div>`;
}

// ---- layers (perimeter stack, outer -> inner) ------------------------------

export function layers(items) {
  const rows = (items || []).map((it) => {
    const tone = ['win', 'parity', 'gap', 'brand'].includes(it.tone) ? it.tone : 'brand';
    return `<div class="layer ${tone}">
    <div class="ln">${esc(it.name)}</div>
    ${it.desc ? `<div class="ld">${esc(it.desc)}</div>` : ''}
  </div>`;
  }).join('\n');
  return `<div class="layers">${rows}</div>`;
}

// ---- evidence card ---------------------------------------------------------

export function evidenceCard({ title, status, lines, gate }) {
  const ok = String(status).toUpperCase() === 'PASS';
  const b = badge(ok ? 'PASS' : 'FAIL', ok ? 'win' : 'gap');
  const pre = (lines || []).map((l) => esc(l)).join('\n');
  return `<div class="evidence">
  <div class="e-head"><span class="e-title">${esc(title)}</span>${b}</div>
  <pre>${pre}</pre>
  ${gate ? `<div class="e-gate">Gate: <code>${esc(gate)}</code></div>` : ''}
</div>`;
}
