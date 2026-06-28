#!/usr/bin/env node
// security-wins-report.mjs — visual report of FOUR just-landed gate-backed wins.
//
// Each win is proven by a numbered milestone gate; every number/proof line on this
// page is quoted from the gate scripts or the wiki docs (measured, not claimed):
//   m101 first-class ranked multi-column full-text search
//   m102 typed pgvector k-NN (capability-gated)
//   m140 network controls (OWASP-CRS WAF + per-plane segmentation)
//   m141 compliance posture (tamper-evident hash-chained audit + GDPR rights)
//
// Sources:
//   wiki/competitive-matrix.md   (rows 6/7 GAP→WIN, 75/76 PARTIAL→WIN)
//   wiki/supabase-vs-grobase.md  (FTS/vector framing)
//   wiki/network-controls.md     (WAF CRS rule-IDs, segmentation, Cloudflare front-door)
//   wiki/compliance-posture.md   (ASVS×SOC2 TSC×GDPR control matrix; 42 GDPR refs)
//   scripts/verify/{m101,m102,m140,m141}-*.sh  (the actual gate proof lines)
//
// Zero-dep ESM. No external packages. No network. No Date.now()/Math.random().
// Run (Docker, no host node):
//   docker run --rm -u "$(id -u):$(id -g)" \
//     -v "$PWD":/b -w /b \
//     public.ecr.aws/docker/library/node:22-bookworm \
//     node /b/scripts/report/security-wins-report.mjs

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  PALETTE, renderPage, section, kpiGrid, scoreboard, badge,
  barChart, donut, matrixTable, calloutGrid, layers, evidenceCard,
} from '../lib/lib-report.mjs';

// INFRA = grobase repo root ; WIKI = <repo>/wiki/
const INFRA = fileURLToPath(new URL('../..', import.meta.url));
const OUT = fileURLToPath(new URL('../../wiki/reports/security-data-wins.html', import.meta.url));

// ── 0. constants pulled from the docs (the static "last updated" — deterministic) ──
const UPDATED = '2026-06-15';

// ── 1. top KPI grid — the four wins, all tone=win, each carrying its gate badge ──
const kpis = kpiGrid([
  { label: 'Full-text search', value: 'WIN', tone: 'win', sub: 'gate m101 · ranked multi-column FTS' },
  { label: 'Vector k-NN', value: 'WIN', tone: 'win', sub: 'gate m102 · typed pgvector, capability-gated' },
  { label: 'Network controls', value: 'WIN', tone: 'win', sub: 'gate m140 · OWASP-CRS WAF + segmentation' },
  { label: 'Compliance posture', value: 'WIN', tone: 'win', sub: 'gate m141 · tamper-evident audit + GDPR' },
]);

const sec1 = section({
  id: 'wins',
  title: '1 · Four wins, four gates',
  intro: `Four capabilities just landed, each <strong>gate-backed</strong> and live-proven. Two
    were <strong>GAP→WIN</strong> on the competitive matrix (data ops); two were
    <strong>PARTIAL→WIN</strong> (security perimeter + verifiable compliance). Every figure on this
    page is quoted from the gate scripts or the source docs — ${badge('measured, not claimed', 'brand')}.`,
  body: kpis + '\n' +
    scoreboard({
      title: 'Gate tally',
      items: [
        { label: 'wins', value: 4, tone: 'win' },
        { label: 'gates PASS', value: '4 / 4', tone: 'win' },
        { label: 'GAP→WIN', value: 2, tone: 'win' },
        { label: 'PARTIAL→WIN', value: 2, tone: 'win' },
        { label: 'GDPR article refs', value: 42, tone: 'win' },
      ],
    }) + '\n' +
    calloutGrid([
      { title: 'm101 · Full-text search', tone: 'win', badge: 'GAP→WIN',
        body: 'Ranked, multi-column to_tsvector @@ websearch_to_tsquery as a typed first-class op — beats Supabase’s single-column fts filter.' },
      { title: 'm102 · Vector k-NN', tone: 'win', badge: 'GAP→WIN',
        body: 'Typed pgvector k-NN (cosine/l2/ip), capability-gated (non-PG → 422) — vs Supabase’s hand-written SQL RPC.' },
      { title: 'm140 · Network controls', tone: 'win', badge: 'PARTIAL→WIN',
        body: 'In-stack OWASP-CRS WAF as the sole public listener + per-plane segmentation. Supabase OSS ships neither.' },
      { title: 'm141 · Compliance posture', tone: 'win', badge: 'PARTIAL→WIN',
        body: 'Cryptographically tamper-evident hash-chained audit + GDPR erase/export, mapped ASVS×SOC2×GDPR.' },
    ]),
});

// ── 2. evidence cards x4 — ACTUAL gate proof lines (quoted from the m*.sh scripts) ──
const ev101 = evidenceCard({
  title: 'm101 — First-class ranked, multi-column full-text search',
  status: 'PASS',
  gate: 'scripts/verify/m101-fulltext-search.sh',
  lines: [
    'op=list + search:{query,columns,language}',
    '  → ranked to_tsvector(lang, concat_ws(\' \', cols)) @@ websearch_to_tsquery',
    '  ORDER BY ts_rank, owner-scoped, language-allowlisted',
    '',
    'FTS: search "search" over [title, body] → expect d1 + d3, not d2',
    '  IDS == "d1,d3"                              [ok]  owner-stamped, ranked',
    '',
    'negative: hostile language "bad\'); DROP--"   → 400 (not 5xx)',
    '  injection-safe; clean reject               [ok]',
    '',
    'PASS — multi-column ranked FTS as a TYPED op (vs Supabase single-column filter)',
  ],
});

const ev102 = evidenceCard({
  title: 'm102 — Typed pgvector k-NN (capability-gated)',
  status: 'PASS',
  gate: 'scripts/verify/m102-vector-search.sh',
  lines: [
    'op=list + vector:{column,query,k,metric}',
    '  → ORDER BY col <=>|<->|<#> $vec LIMIT k   (cosine / l2 / inner-product)',
    '',
    'vector_search: nearest to [1,0,0], cosine, k=3 → expect a,b,c',
    '  IDS == "a,b,c"                              [ok]  k-NN order correct',
    '',
    'negative: vector op on a non-PG engine (redis mount) → 422 (not 5xx)',
    '  capability-gated; engine declares it can\'t  [ok]',
    '',
    'PASS — typed first-class pgvector k-NN (vs Supabase hand-written SQL RPC)',
  ],
});

const ev140 = evidenceCard({
  title: 'm140 — Network controls: OWASP-CRS WAF + per-plane segmentation',
  status: 'PASS',
  gate: 'scripts/verify/m140-network-controls.sh',
  lines: [
    'WAF — ModSecurity v3 + OWASP CRS v4, sole public listener (blocking):',
    '  ?id=1\' OR \'1\'=\'1 -- UNION SELECT  (SQLi)      → 403   rule 942100',
    '  ?q=<script>alert(1)</script>      (XSS)       → 403   rule 941100',
    '  ?file=../../../../etc/passwd      (traversal) → 403   rule 930100',
    '  anomaly score ≥ 5                             → 403   rule 949110',
    '  GET /data/v1/health               (benign)    → passes WAF (Kong 401)',
    '',
    'negative control: same SQLi sent DIRECT to Kong (WAF-bypassed) → 404 (not 403)',
    '  proves the 403 originates at the WAF/CRS layer, not Kong',
    '',
    'segmentation (docker-compose.netseg.yml, throwaway scratch, no escape bridge):',
    '  kong (net-edge)        → postgres:5432   REFUSED   (edge ↛ data)',
    '  query-router (front)   → postgres:5432   CONNECTS  (legal front-door)',
    '',
    'PASS — in-stack perimeter Supabase OSS ships neither',
  ],
});

const ev141 = evidenceCard({
  title: 'm141 — Compliance posture: tamper-evident audit + GDPR rights',
  status: 'PASS',
  gate: 'scripts/verify/m141-compliance-posture.sh',
  lines: [
    'hash-chained audit:  hash = sha256(prev_hash ‖ canonical(row))   (Go, engine-agnostic)',
    '  append 3 entries → recompute chain        intact:true     (3 links INTACT)',
    '  DB-tamper one row → recompute chain        intact:false',
    '    broken_seq: 2   reason: hash_mismatch    (detected at exact link)',
    '',
    'standards map present + non-empty:  ASVS 4.0 + SOC 2 TSC (CC6) + GDPR',
    '  GDPR article citations: 42  (Art.17, Art.20, Art.28, Art.30, Art.32, …)',
    '',
    'GDPR rights reachable + authorized:',
    '  erase  (Art.17)  route mounted (not 404), unauth → 401',
    '  export (Art.20)  route mounted (not 404), unauth → 401',
    '',
    'PASS — controls a buyer can independently RE-VERIFY in their own infra',
  ],
});

const sec2 = section({
  id: 'evidence',
  title: '2 · Gate evidence (real outputs)',
  intro: `Each card quotes the load-bearing assertions from the gate script itself. A gate that passes
    vacuously is not a gate — these exercise the behavior (right rows returned, right rule-IDs fired,
    edge↔data refused, the chain broken at the exact link).`,
  body: ev101 + '\n' + ev102 + '\n' + ev140 + '\n' + ev141,
});

// ── 3. before → after — each dimension moving (matrix rows from competitive-matrix.md) ──
const sec3 = section({
  id: 'before-after',
  title: '3 · Before → after — dimensions moving to WIN',
  intro: `From the 91-row competitive matrix. Rows 6 & 7 moved <strong>GAP → WIN</strong> on live
    proof (m101 / m102); rows 75 & 76 moved <strong>PARTIAL → WIN</strong> (m140 / m141). The tone
    change is the win: red/amber → green.`,
  body: matrixTable({
    columns: ['Row', 'Dimension', 'Before', 'After', 'Gate'],
    rows: [
      ['6', 'Native full-text search',
        { text: 'GAP', tone: 'gap' }, { text: 'WIN', tone: 'win' }, 'm101'],
      ['7', 'Vector / embeddings (k-NN)',
        { text: 'GAP', tone: 'gap' }, { text: 'WIN', tone: 'win' }, 'm102'],
      ['75', 'Network restrictions / segmentation',
        { text: 'PARTIAL', tone: 'parity' }, { text: 'WIN', tone: 'win' }, 'm140'],
      ['76', 'Audit logs / verifiable compliance',
        { text: 'PARTIAL', tone: 'parity' }, { text: 'WIN', tone: 'win' }, 'm141'],
    ],
  }) + '\n' +
    barChart({
      title: 'Status score before vs after (GAP=0 · PARTIAL=1 · WIN=2)',
      unit: 'status pts',
      data: [
        { label: 'FTS (m101)', value: 2, tone: 'win', note: 'was GAP (0)' },
        { label: 'Vector (m102)', value: 2, tone: 'win', note: 'was GAP (0)' },
        { label: 'Network (m140)', value: 2, tone: 'win', note: 'was PARTIAL (1)' },
        { label: 'Compliance (m141)', value: 2, tone: 'win', note: 'was PARTIAL (1)' },
      ],
    }),
});

// ── 4. donut — compliance control coverage by standard (counts from compliance-posture.md) ──
// ASVS unique V-requirement refs = 32; SOC 2 TSC unique criteria = 16; GDPR article occurrences = 42.
const sec4 = section({
  id: 'coverage',
  title: '4 · Compliance control coverage (m141)',
  intro: `The control matrix in <code>compliance-posture.md</code> maps every shipped control to three
    standards families. Counts: <strong>ASVS 4.0</strong> requirement refs, <strong>SOC 2 TSC</strong>
    criteria, and <strong>GDPR</strong> article references — every row backed by an in-repo artifact.`,
  body: donut({
    title: 'Standards-mapping references across the §2 control matrix',
    centerLabel: '3',
    slices: [
      { label: 'ASVS 4.0 (V-reqs)', value: 32, color: PALETTE.brand },
      { label: 'SOC 2 TSC (criteria)', value: 16, color: PALETTE.win },
      { label: 'GDPR (article refs)', value: 42, color: PALETTE.parity },
    ],
  }) + '\n' +
    scoreboard({
      title: 'GDPR rights shipped',
      items: [
        { label: 'erase · Art.17', value: 'm105', tone: 'win' },
        { label: 'export · Art.20', value: 'm109', tone: 'win' },
        { label: 'records · Art.30', value: 'm104', tone: 'win' },
        { label: 'auth-enforced', value: '401', tone: 'win' },
      ],
    }),
});

// ── 5. layers — the network perimeter (Cloudflare → WAF/CRS → Kong → planes) ──
const sec5 = section({
  id: 'perimeter',
  title: '5 · Network perimeter (m140)',
  intro: `Defense in depth, outer → inner. The <strong>only</strong> container binding a public port is
    the WAF; Kong sits behind it on 127.0.0.1. A compromised edge container cannot open a raw socket to
    an engine — it has no bridge to the data plane.`,
  body: layers([
    { name: 'Cloudflare front-door', tone: 'brand',
      desc: 'ROADMAP recipe (hosted): proxied DNS, managed WAF, rate-limit, Turnstile, full-strict TLS + authenticated origin-pull mTLS — a 2nd perimeter on top of the in-stack WAF.' },
    { name: 'OWASP ModSecurity v3 + CRS v4 (WAF)', tone: 'win',
      desc: 'Sole public listener, blocking. SQLi 942100 · XSS 941100 · traversal 930100 · anomaly 949110 → 403. Benign passes; Kong-direct=404 negative control.' },
    { name: 'Kong API gateway', tone: 'win',
      desc: 'Bound 127.0.0.1 only (dev) — behind the WAF. Edge IP-restrict on /admin/v1/* (private CIDRs). Per-tenant IP allowlist (m106).' },
    { name: 'Application planes — edge', tone: 'parity',
      desc: 'net-edge: waf, kong, gotrue, postgrest, realtime, studio. WAN ingress.' },
    { name: 'Control plane', tone: 'parity',
      desc: 'net-control (internal:true, no WAN egress): tenant-control, orchestrator, permission-engine, schema-service, vault.' },
    { name: 'Data plane — engines', tone: 'gap',
      desc: 'net-data (internal:true): postgres, mysql, mongo, redis, minio … Reachable ONLY via the dual-attached front-door routers, where owner-scope/RLS ABAC is enforced per request. edge ↛ data REFUSED.' },
  ]),
});

// ── assemble + write ─────────────────────────────────────────────────────────
const html = renderPage({
  title: 'Grobase — Security & Data Wins',
  subtitle: 'Four just-landed, gate-backed wins: full-text search · vector k-NN · network controls · compliance posture',
  accent: PALETTE.brand,
  updated: UPDATED,
  sections: [sec1, sec2, sec3, sec4, sec5],
});

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, html, 'utf8');

// quick self-check on the way out (no throw on success)
const ok = html.includes('<svg') && html.includes('</html>');
process.stdout.write(`security-data-wins → ${OUT}\nbytes=${Buffer.byteLength(html, 'utf8')} valid=${ok}\n`);
if (!ok) process.exit(1);
