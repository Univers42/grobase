#!/usr/bin/env node
// portal.mjs — zero-dependency reports-portal generator for the Grobase offer
// comparison. Reads scripts/bench/offers-compare-data.json and emits ONE
// self-contained HTML file (embedded CSS, no external assets, no npm deps —
// only node: builtins).
//
// The portal is the human entry point to the reports bundle: it links the
// benchmark HTMLs + the Postman test report + the two markdown offer docs, then
// renders the offer table and, per rival, a verdict + a pure-CSS price-ladder
// chart + a colour-badged feature table.
//
// Honesty contract (kernel rule #4): Grobase numbers are measured (packages.json
// + artifacts/…); rival numbers are PUBLISHED as of June 2026 with source URLs.
//
// Usage:
//   node portal.mjs --data <offers.json> --out <index.html>
//                   [--bench3 benchmark-3way.html]
//                   [--bench9 benchmark-9way.html]
//                   [--postman postman-offers-report.html]
// Defaults: --data scripts/bench/offers-compare-data.json,
//           --out  artifacts/report/index.html, report filenames as documented.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
// scripts/report/ -> mini-baas-infra/
const INFRA = resolve(__dirname, "..", "..");
const DEFAULT_DATA = join(INFRA, "scripts", "bench", "offers-compare-data.json");
const DEFAULT_OUT = join(INFRA, "artifacts", "report", "index.html");

// ── arg parse ───────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const out = {
    data: DEFAULT_DATA,
    out: DEFAULT_OUT,
    bench3: "benchmark-3way.html",
    bench9: "benchmark-9way.html",
    postman: "postman-offers-report.html",
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--data") out.data = argv[++i];
    else if (a === "--out") out.out = argv[++i];
    else if (a === "--bench3") out.bench3 = argv[++i];
    else if (a === "--bench9") out.bench9 = argv[++i];
    else if (a === "--postman") out.postman = argv[++i];
    else if (a === "-h" || a === "--help") {
      console.log(
        "usage: portal.mjs --data <offers.json> --out <index.html> " +
          "[--bench3 file] [--bench9 file] [--postman file]"
      );
      process.exit(0);
    }
  }
  return out;
}

// ── HTML escaping (every interpolated value passes through this) ──────────────
const esc = (s) =>
  String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");

// level → badge background colour (white text)
const LEVEL_COLOR = {
  win: "#16a34a",
  ok: "#0891b2",
  partial: "#a16207",
  gap: "#dc2626",
};
const LEVEL_LABEL = { win: "win", ok: "ok", partial: "partial", gap: "gap" };

function badge(level) {
  const lv = String(level || "").toLowerCase();
  const color = LEVEL_COLOR[lv] || "#64748b";
  const label = LEVEL_LABEL[lv] || lv || "?";
  return `<span class="badge" style="background:${color}">${esc(label)}</span>`;
}

// ── CSS (palette matched to compare-report.mjs) ──────────────────────────────
function css() {
  return `
:root{--ink:#0f172a;--bg:#f8fafc;--line:#e2e8f0;--muted:#64748b;--head:#f1f5f9}
*{box-sizing:border-box}
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;margin:0;background:var(--bg);color:var(--ink);line-height:1.55}
header{background:#0f172a;color:#fff;padding:32px 40px}
header h1{margin:0 0 8px;font-size:25px;letter-spacing:-.01em}
header .gen{margin:0;color:#94a3b8;font-size:13px}
header .intro{margin:12px 0 0;color:#cbd5e1;font-size:14px;max-width:880px}
main{max-width:1040px;margin:0 auto;padding:24px 16px 72px}
section{background:#fff;border:1px solid var(--line);border-radius:10px;padding:22px;margin:20px 0;box-shadow:0 1px 2px rgba(0,0,0,.04)}
h2{font-size:21px;margin:4px 0 2px;letter-spacing:-.01em}
h2 .tag{font-size:14px;font-weight:400;color:var(--muted)}
h3{font-size:15px;margin:22px 0 8px;color:#334155;text-transform:uppercase;letter-spacing:.04em}
.kicker{font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:0 0 10px}
.verdict{font-size:14px;color:#1e293b;background:#f8fafc;border-left:4px solid #0f172a;padding:12px 16px;border-radius:0 6px 6px 0;margin:0 0 18px}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:14px}
.card{display:block;text-decoration:none;color:inherit;border:1px solid var(--line);border-radius:9px;padding:16px;background:#fff;transition:border-color .15s,box-shadow .15s}
.card:hover{border-color:#94a3b8;box-shadow:0 2px 8px rgba(15,23,42,.08)}
.card .ct{font-weight:600;font-size:15px;color:#0f172a;margin:0 0 4px}
.card .cd{font-size:12.5px;color:var(--muted);margin:0}
.card .arrow{color:#2563eb;font-size:12.5px;margin-top:8px;display:block}
table{border-collapse:collapse;width:100%;font-size:13px;margin-top:10px}
th,td{border:1px solid var(--line);padding:7px 10px;text-align:left;vertical-align:top}
th{background:var(--head);font-weight:600}
tbody tr:nth-child(even){background:#fafcff}
.badge{display:inline-block;color:#fff;font-size:11px;font-weight:700;padding:2px 9px;border-radius:999px;text-transform:uppercase;letter-spacing:.03em}
.ladder{margin:6px 0 20px}
.rung{margin:0 0 16px;padding:0 0 14px;border-bottom:1px dashed var(--line)}
.rung:last-child{border-bottom:none}
.rung .rl{font-size:13px;font-weight:600;color:#0f172a;margin:0 0 8px}
.bar-row{display:flex;align-items:center;gap:10px;margin:5px 0}
.bar-who{flex:0 0 88px;font-size:12px;font-weight:600;text-align:right;color:#475569}
.bar-track{flex:1 1 auto;background:#f1f5f9;border-radius:5px;height:26px;position:relative;overflow:hidden}
.bar-fill{height:100%;border-radius:5px;display:flex;align-items:center;padding:0 9px;color:#fff;font-size:12px;font-weight:600;white-space:nowrap;min-width:max-content}
.bar-g{background:#2563eb}
.bar-r{background:#16a34a}
.rung .rn{font-size:12px;color:var(--muted);margin:8px 0 0}
footer{max-width:1040px;margin:0 auto;padding:8px 16px 48px;font-size:12px;color:var(--muted)}
footer .sources{margin-top:8px}
footer code{background:#eef2f7;padding:1px 6px;border-radius:4px;font-size:11px}
footer ul{margin:6px 0 0;padding-left:18px}
footer li{margin:2px 0}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12.5px;color:#475569;margin:0 0 4px}
.legend .badge{margin-right:5px}
.muted{color:var(--muted);font-size:12.5px}
`;
}

// ── Reports nav cards ────────────────────────────────────────────────────────
function reportsNav(args) {
  const items = [
    {
      href: "comparison-report.html",
      title: "★ Full comparison report",
      desc: "The detailed all-in-one: performance benchmarks + offers + the 91-row matrix + edge reliability + verdicts, with every chart.",
    },
    {
      href: args.bench3,
      title: "3-way deep benchmark",
      desc: "Grobase nano / one vs PocketBase — fresh images, latency by concurrency, multi-tenant scaling.",
    },
    {
      href: args.bench9,
      title: "9-way benchmark",
      desc: "Grobase tiers vs the field across footprint, latency, and 10K / 100K scale curves.",
    },
    {
      href: args.postman,
      title: "Postman API-test report",
      desc: "Newman run of the offer-surface collection — auth, CRUD, aggregate, realtime, self-serve.",
    },
    {
      href: "supabase-vs-grobase.html",
      title: "★ Supabase vs Grobase — strong enough? (visual)",
      desc: "Graphics-rich decision report: verdict gauge, win/parity/gap donut, measured head-to-head bars (read p95, footprint, density, insert p99), the new FTS m101 + vector m102 wins, and where Supabase still honestly leads.",
    },
    {
      href: "security-data-wins.html",
      title: "★ Security & data wins (visual)",
      desc: "The four just-landed, gate-backed wins — full-text (m101), vector k-NN (m102), network/WAF (m140), compliance (m141) — as evidence cards + GAP→WIN tone shifts + control-coverage donut + perimeter diagram.",
    },
    {
      href: "edge-reliability.html",
      title: "★ Edge-case reliability (visual)",
      desc: "1,381 distinct edge vectors (9 families) under an invariant model: assertion pass-rate gauge, failure-category donut, and the 2 real 5xx bugs the suite found + we fixed (oversize→413, malformed-op→400) with the honest load-tail split (gate m142).",
    },
    {
      href: "benchmark-resources.html",
      title: "★ Benchmark + resources (visual)",
      desc: "Measured same-box Grobase vs Supabase: read latency p50+p95, total RSS 822 vs 2,884 MiB (3.5× lighter) + Supabase's 13-container breakdown + the Grobase tier ladder, and a functional-parity matrix proving it's apples-to-apples.",
    },
    {
      href: "grobase-vs-supabase-allmetrics.html",
      title: "★ All-metrics scorecard (visual)",
      desc: "The honest verdict: Grobase wins 10 of 11 measured metrics vs Supabase (footprint, read p95, density, engines, FTS m101, vector m102, WAF m140, audit m141) — one near-tie (read p50, Supabase +0.12 ms), zero measured Supabase wins.",
    },
    {
      href: "network-controls.html",
      title: "Network controls + Cloudflare (visual)",
      desc: "Perimeter-layers diagram (Cloudflare → in-stack OWASP-CRS WAF → Kong → segmented planes), WAF block matrix (CRS rule-IDs, gate m140), segmentation matrix, and the copy-paste Cloudflare recipe.",
    },
    {
      href: "compliance-posture.html",
      title: "Compliance posture — control matrix (visual)",
      desc: "Audit-ready gauge, ASVS/SOC2/GDPR coverage donut, the full evidence-backed control matrix (gate m141), and the tamper-evident hash-chain demo — with the honest formal-cert caveat.",
    },
    {
      href: "../offer-vs-supabase.md",
      title: "Offer vs Supabase (doc)",
      desc: "Markdown deep-dive: tier-by-tier and feature-by-feature against Supabase.",
    },
    {
      href: "../offer-vs-mongodb-atlas.md",
      title: "Offer vs MongoDB Atlas (doc)",
      desc: "Markdown deep-dive vs Atlas — and why the App Services BaaS layer is gone (EOL 2025-09-30).",
    },
    {
      href: "../competitive-matrix.md",
      title: "Competitive matrix — 91 rows (doc)",
      desc: "The full capability matrix vs Supabase + Firebase, with the win/parity/gap status and a backing gate per row.",
    },
  ];
  const cards = items
    .map(
      (it) => `      <a class="card" href="${esc(it.href)}">
        <p class="ct">${esc(it.title)}</p>
        <p class="cd">${esc(it.desc)}</p>
        <span class="arrow">open &rarr;</span>
      </a>`
    )
    .join("\n");
  return `  <section>
    <p class="kicker">Reports</p>
    <div class="cards">
${cards}
    </div>
  </section>`;
}

// ── Our-offer tier table ─────────────────────────────────────────────────────
function offerTable(tiers) {
  const rows = (tiers || [])
    .map(
      (t) => `        <tr>
          <td><b>${esc(t.label || t.id)}</b></td>
          <td>${esc(t.priceRetail)}</td>
          <td>${esc(t.engines)} <span class="muted">(${esc(t.engineList)})</span></td>
          <td>${esc(t.rpsBurst)}</td>
          <td>${esc(t.maxMounts)}</td>
          <td>${esc(t.ramMiB)}</td>
          <td>${esc(t.capabilities)}</td>
        </tr>`
    )
    .join("\n");
  return `  <section>
    <p class="kicker">Our offer</p>
    <h2>Five tiers, one codebase</h2>
    <p class="muted">Measured against <code>config/packages/packages.json</code> + <code>artifacts/footprint-*.json</code>. No invented numbers.</p>
    <table>
      <thead><tr><th>Tier</th><th>Price</th><th>Engines</th><th>rps / burst</th><th>Mounts</th><th>RAM MiB</th><th>Capabilities</th></tr></thead>
      <tbody>
${rows}
      </tbody>
    </table>
  </section>`;
}

// ── pure-CSS price ladder ────────────────────────────────────────────────────
function priceLadder(ladder, rivalName) {
  const rungs = ladder || [];
  // max usd across this ladder (both sides), floor at 1 to avoid /0
  const maxUsd = Math.max(
    1,
    ...rungs.flatMap((r) => [Number(r.grobaseUsd) || 0, Number(r.rivalUsd) || 0])
  );
  const MIN_PCT = 6; // so a $0 "Free" bar still shows
  const pct = (usd) => {
    const v = Number(usd) || 0;
    const raw = (v / maxUsd) * 100;
    return Math.max(MIN_PCT, raw).toFixed(1);
  };
  const money = (usd) => {
    const v = Number(usd) || 0;
    return v === 0 ? "Free" : "$" + v;
  };
  const body = rungs
    .map((r) => {
      const gPct = pct(r.grobaseUsd);
      const rPct = pct(r.rivalUsd);
      const gLabel = `${money(r.grobaseUsd)} · ${esc(r.grobaseTier || "Grobase")}`;
      const rLabel = `${money(r.rivalUsd)} · ${esc(r.rivalPlan || rivalName)}`;
      return `      <div class="rung">
        <p class="rl">${esc(r.label)}</p>
        <div class="bar-row">
          <span class="bar-who">Grobase</span>
          <div class="bar-track"><div class="bar-fill bar-g" style="width:${gPct}%">${gLabel}</div></div>
        </div>
        <div class="bar-row">
          <span class="bar-who">${esc(rivalName)}</span>
          <div class="bar-track"><div class="bar-fill bar-r" style="width:${rPct}%">${rLabel}</div></div>
        </div>
        ${r.note ? `<p class="rn">${esc(r.note)}</p>` : ""}
      </div>`;
    })
    .join("\n");
  return `    <h3>Price ladder</h3>
    <div class="ladder">
${body}
    </div>`;
}

// ── feature table with colour badges ─────────────────────────────────────────
function featureTable(features, rivalName) {
  const rows = (features || [])
    .map(
      (f) => `        <tr>
          <td><b>${esc(f.feature)}</b></td>
          <td>${badge(f.grobaseLevel)} ${esc(f.grobase)}</td>
          <td>${badge(f.rivalLevel)} ${esc(f.rival)}</td>
          <td class="muted">${esc(f.source)}</td>
        </tr>`
    )
    .join("\n");
  return `    <h3>Feature comparison</h3>
    <div class="legend">
      <span>${badge("win")} we lead</span>
      <span>${badge("ok")} on par / supported</span>
      <span>${badge("partial")} partial</span>
      <span>${badge("gap")} honest gap / retired</span>
    </div>
    <table>
      <thead><tr><th>Feature</th><th>Grobase</th><th>${esc(rivalName)}</th><th>Source</th></tr></thead>
      <tbody>
${rows}
      </tbody>
    </table>`;
}

// ── one comparison section ───────────────────────────────────────────────────
function comparisonSection(cmp) {
  return `  <section id="${esc(cmp.id)}">
    <h2>vs ${esc(cmp.rival)} <span class="tag">— ${esc(cmp.rivalTagline)}</span></h2>
    <p class="verdict">${esc(cmp.verdict)}</p>
${priceLadder(cmp.priceLadder, cmp.rival)}
${featureTable(cmp.features, cmp.rival)}
  </section>`;
}

// ── collect source URLs for the footer ───────────────────────────────────────
function collectSources(data) {
  const urls = new Set();
  const seen = (s) => {
    const m = String(s || "").match(/https?:\/\/[^\s)]+/g);
    if (m) m.forEach((u) => urls.add(u.replace(/[.,;]+$/, "")));
  };
  for (const c of data.comparisons || []) {
    for (const f of c.features || []) seen(f.source);
    for (const t of data.grobaseTiers || []) seen(t.source);
  }
  // Known published-rival sources from the ground truth (always cited).
  [
    "https://supabase.com/pricing",
    "https://www.mongodb.com/pricing",
    "https://www.mongodb.com/docs/atlas/app-services/data-api/data-api-deprecation/",
  ].forEach((u) => urls.add(u));
  return [...urls].sort();
}

// ── assemble the page ────────────────────────────────────────────────────────
function buildHtml(data, args) {
  const title = data.title || "Grobase offer comparison";
  const intro = data.intro || "";
  const gen = data.generated || new Date().toISOString().slice(0, 10);

  const comparisons = (data.comparisons || []).map(comparisonSection).join("\n");
  const sources = collectSources(data);
  const sourceList = sources
    .map((u) => `      <li><code>${esc(u)}</code></li>`)
    .join("\n");

  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<style>${css()}</style>
</head>
<body>
<header>
  <h1>${esc(title)}</h1>
  <p class="gen">Generated ${esc(gen)}</p>
  ${intro ? `<p class="intro">${esc(intro)}</p>` : ""}
</header>
<main>
${reportsNav(args)}
${offerTable(data.grobaseTiers)}
${comparisons}
</main>
<footer>
  <p>Grobase numbers are <b>measured</b> (<code>config/packages/packages.json</code> + <code>artifacts/&hellip;</code>). Rival numbers are <b>published</b> as of June 2026 — the vendor's claim, not our measurement.</p>
  <div class="sources">
    <p>Published sources:</p>
    <ul>
${sourceList}
    </ul>
  </div>
</footer>
</body></html>`;
}

// ── main ─────────────────────────────────────────────────────────────────────
function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!existsSync(args.data)) {
    console.error(`error: data file not found: ${args.data}`);
    process.exit(2);
  }
  let data;
  try {
    data = JSON.parse(readFileSync(args.data, "utf8"));
  } catch (e) {
    console.error(`error: cannot parse JSON in ${args.data}: ${e.message}`);
    process.exit(2);
  }
  const html = buildHtml(data, args);
  mkdirSync(dirname(resolve(args.out)), { recursive: true });
  writeFileSync(resolve(args.out), html);
  console.log(
    `portal: wrote ${html.length} bytes → ${resolve(args.out)} ` +
      `(${(data.grobaseTiers || []).length} tiers, ${(data.comparisons || []).length} comparisons)`
  );
}

main();
