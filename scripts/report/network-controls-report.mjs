#!/usr/bin/env node
// network-controls-report.mjs — graphics-rich HTML twin of wiki/network-controls.md.
// Zero-dependency ESM (node: builtins only; runs in node:22 in Docker, no host node).
// Imports the shared design-system lib; every figure traces to the .md (measured/gate)
// or is clearly labelled ROADMAP (the Cloudflare front-door recipe). No invented numbers.
//
// Usage (per repo rules, in Docker):
//   node mini-baas-infra/scripts/report/network-controls-report.mjs

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  PALETTE, renderPage, section, kpiGrid, scoreboard, badge,
  matrixTable, calloutGrid, layers, evidenceCard, barChart, donut,
} from '../lib/lib-report.mjs';

// Resolve out path from this module's URL (subtree-relative; no host assumptions).
const SUBTREE = fileURLToPath(new URL('../../..', import.meta.url)); // .../apps/baas
const OUT = fileURLToPath(new URL('../../../wiki/reports/network-controls.html', import.meta.url));

// ── 0. header KPIs (from §5 verdict table) ──────────────────────────────────
const kpis = kpiGrid([
  { label: 'In-stack WAF', value: 'YES', tone: 'win', sub: 'OWASP CRS v4 — Supabase OSS: none' },
  { label: 'Plane isolation', value: 'YES', tone: 'win', sub: '4 isolated bridges, edge↛data refused' },
  { label: 'IP allowlist', value: 'per-tenant', tone: 'parity', sub: 'control-plane, gate m106' },
  { label: 'Cloudflare recipe', value: 'READY', tone: 'parity', sub: 'ROADMAP — hosted front-door' },
]);

const board = scoreboard({
  title: 'perimeter',
  items: [
    { label: 'WAF probes', value: '4/4', tone: 'win' },
    { label: 'public listeners', value: 1, tone: 'win' },
    { label: 'segmented planes', value: 4, tone: 'win' },
    { label: 'in-stack gates', value: 3, tone: 'win' },
    { label: 'CF recipe knobs', value: 6, tone: 'parity' },
  ],
});

const overview = section({
  id: 'overview',
  title: 'Perimeter at a glance',
  intro:
    `Grobase ships, <em>in its own self-hostable stack</em>, an OWASP-CRS WAF as the sole ` +
    `public listener, per-plane network segmentation, and per-tenant IP allow-listing — ` +
    `perimeter controls Supabase does <strong>not</strong> ship in its OSS/self-host stack ` +
    `(its <code>supabase/supabase</code> compose has no WAF and one flat Docker network). ` +
    `${badge('WIN (in-stack)', 'win')} ${badge('1 honest parity note', 'parity')}`,
  body: kpis + '\n' + board,
});

// ── 1. layers() — defense-in-depth perimeter, outer → inner ─────────────────
const perimeter = section({
  id: 'layers',
  title: '1 · Defense-in-depth perimeter (outer → inner)',
  intro:
    `The outermost ring is the optional Cloudflare front-door ` +
    `${badge('ROADMAP — §4 recipe', 'parity')}; everything from the in-stack WAF inward is ` +
    `${badge('measured / gate-proven', 'win')}. A request crosses every ring in order; the ` +
    `in-stack WAF is the <strong>sole public listener</strong> (Kong sits behind it).`,
  body: layers([
    {
      name: 'Cloudflare front-door  (ROADMAP — hosted only)',
      tone: 'parity',
      desc: 'DNS-proxy (orange-cloud) · managed WAF + OWASP ruleset · rate-limit 600/60s · ' +
        'Turnstile bot-challenge · Full-strict TLS + authenticated origin pull (mTLS).',
    },
    {
      name: 'In-stack OWASP-CRS WAF  (sole public listener)',
      tone: 'win',
      desc: 'nginx + ModSecurity v3 + CRS v4 (owasp/modsecurity-crs:4-nginx). SecRuleEngine On, ' +
        'paranoia 2, inbound anomaly threshold 5. Only container binding a public port.',
    },
    {
      name: 'Kong edge gateway  (behind the WAF)',
      tone: 'brand',
      desc: 'Bound to 127.0.0.1 for dev, never 0.0.0.0. ip-restriction on /admin/v1/* + ' +
        'tenant-control + adapter-registry (private CIDRs only).',
    },
    {
      name: 'net-edge plane  (public-facing services)',
      tone: 'brand',
      desc: 'waf, kong, studio, playground, gotrue, postgrest, realtime, grafana — WAN ingress.',
    },
    {
      name: 'net-control plane  (internal: true — no WAN egress)',
      tone: 'win',
      desc: 'tenant-control, orchestrator, permission-engine, schema-service, webhook-dispatcher, ' +
        'function-scheduler, vault. Reachable only via the dual-attached routers.',
    },
    {
      name: 'net-data plane  (internal: true — no WAN egress)',
      tone: 'win',
      desc: 'postgres, mysql, mariadb, cockroach, mssql, mongo, redis, minio. Owner-scope/RLS ABAC ' +
        'enforced per request at the front-door routers — no raw socket from the edge.',
    },
  ]),
});

// ── 2. matrixTable() — WAF block results (§1 gate m140) ─────────────────────
// columns: request, expected, result (403/200), CRS rule-ID. tone win on 403 blocks + benign 200.
const wafTable = matrixTable({
  columns: ['Probe (request)', 'Expected', 'Result', 'CRS rule ID(s)'],
  rows: [
    [
      { text: "?id=1' OR '1'='1 -- UNION SELECT … (SQLi)" },
      'block',
      { text: '403', tone: 'win' },
      { text: '942100 (libinjection SQLi)' },
    ],
    [
      { text: '?q=<script>alert(1)</script> (XSS)' },
      'block',
      { text: '403', tone: 'win' },
      { text: '941100 / 941110 / 941160 / 941390' },
    ],
    [
      { text: '?file=../../../../etc/passwd (path traversal)' },
      'block',
      { text: '403', tone: 'win' },
      { text: '930100 / 930110 / 930120 (LFI) + 932160' },
    ],
    [
      { text: 'GET /waf-health (benign liveness)' },
      'pass',
      { text: '200', tone: 'win' },
      { text: 'bypass (static liveness)' },
    ],
    [
      { text: 'GET /data/v1/health (benign real route)' },
      'pass WAF',
      { text: '200', tone: 'win' },
      { text: '— (Kong 401 auth, not 403)' },
    ],
  ],
});

const negControl = evidenceCard({
  title: 'Negative control — the 403 originates at the WAF, not Kong',
  status: 'PASS',
  lines: [
    '# same SQLi sent DIRECTLY to Kong (bypassing the WAF):',
    'GET kong:8000  ?id=1\' OR \'1\'=\'1 -- …   →  404   (NOT 403)',
    '',
    '# through the WAF:',
    'GET waf:8881   ?id=1\' OR \'1\'=\'1 -- …   →  403   rule 942100',
    '# block exceeds CRS anomaly threshold → 949110 (score ≥ 5)',
    '#   ⇒ the CRS scoring engine does the work, not an ad-hoc rule.',
  ],
  gate: 'bash mini-baas-infra/scripts/verify/m140-network-controls.sh',
});

// barChart — number of distinct CRS rule IDs that fired per attack probe (from §1 table).
// Benign probes intentionally fire 0 rules (they pass) — that is the desired outcome.
const wafRulesChart = barChart({
  title: 'CRS rules fired per probe (m140 — live ModSecurity audit log)',
  unit: 'rules',
  lowerIsBetter: false,
  data: [
    { label: 'XSS', value: 4, tone: 'win', note: '403' },
    { label: 'path traversal', value: 4, tone: 'win', note: '403' },
    { label: 'SQLi', value: 1, tone: 'win', note: '403' },
    { label: 'benign /data/v1/health', value: 0, tone: 'neutral', note: 'passes WAF' },
    { label: 'benign /waf-health', value: 0, tone: 'neutral', note: '200 bypass' },
  ],
});

const wafSection = section({
  id: 'waf',
  title: '2 · In-stack OWASP-CRS WAF — live block results (gate m140)',
  intro:
    `The only container binding a public port is the WAF: nginx + ModSecurity v3 + OWASP CRS v4, ` +
    `<code>SecRuleEngine On</code> (blocking, not detect-only). The gate probes the running WAF and ` +
    `records the <strong>real</strong> HTTP status and the CRS rule IDs that fired (from the ` +
    `ModSecurity JSON audit log). ${badge('Supabase OSS: no WAF container', 'gap')}`,
  body: wafTable + '\n<div style="margin-top:14px"></div>\n' + wafRulesChart +
    '\n<div style="margin-top:14px"></div>\n' + negControl,
});

// ── 3. matrixTable() — segmentation matrix (§2 gate m66/m140) ───────────────
// from {edge(Kong), front-door(query-router)} x to {data:5432, control:3021}
// REFUSED-from-edge = GOOD (tone win); ALLOWED-from-front-door = GOOD (tone win).
const segTable = matrixTable({
  columns: ['From →', 'to postgres:5432 (data)', 'to control plane (e.g. vault:8200)'],
  rows: [
    [
      { text: 'edge — Kong (net-edge only)' },
      { text: 'REFUSED  ✓ (no bridge)', tone: 'win' },
      { text: 'REFUSED  ✓ (no bridge)', tone: 'win' },
    ],
    [
      { text: 'front-door — query-router (edge+control+data)' },
      { text: 'CONNECTS  ✓ (legal path)', tone: 'win' },
      { text: 'CONNECTS  ✓ (legal path)', tone: 'win' },
    ],
  ],
});

const segLegend = calloutGrid([
  {
    title: 'REFUSED from the edge = the goal',
    tone: 'win',
    badge: 'good',
    body: 'A compromised edge container (e.g. a Kong RCE) cannot open a raw socket to ' +
      'postgres:5432, vault:8200 or redis:6379 — it has no bridge to them. Both cells are ' +
      'tone-win because blocking is the desired outcome here.',
  },
  {
    title: 'ALLOWED from the front-door = by design',
    tone: 'win',
    badge: 'good',
    body: 'query-router and data-plane-router-rust are dual/triple-attached (net-edge + ' +
      'net-control + net-data) — the ONLY legal edge→data path, where owner-scope/RLS ABAC ' +
      'is enforced per request. Reaching data here is correct, so it is also tone-win.',
  },
]);

const segSection = section({
  id: 'segmentation',
  title: '3 · Per-plane network segmentation (m66 / m140)',
  intro:
    `The additive overlay <code>docker-compose.netseg.yml</code> splits the stack into four ` +
    `default-deny bridges; two containers reach each other <em>iff</em> they share a bridge. ` +
    `<strong>Legend:</strong> in this matrix the blocked outcome is the <em>desired</em> one, so ` +
    `REFUSED-from-edge and ALLOWED-from-front-door are both ${badge('tone WIN', 'win')} (green = ` +
    `correct posture, not "open"). ${badge('Supabase OSS: one flat network', 'gap')}`,
  body: segTable + '\n<div style="margin-top:14px"></div>\n' + segLegend,
});

// ── 4. kpiGrid — the four headline controls (§5 verdict) ────────────────────
// donut — the §5 verdict-table tally (6 controls): WIN vs parity(-with-caveat).
// WIN rows: in-stack WAF, segmentation, self-host residency. parity rows:
// IP allowlist, edge DDoS, origin mTLS (AOP).
const verdictDonut = donut({
  title: 'vs Supabase — §5 verdict tally (6 perimeter controls)',
  centerLabel: '3 / 6',
  slices: [
    { label: 'WIN (self-host)', value: 3, color: PALETTE.win },
    { label: 'parity / parity-with-caveat', value: 3, color: PALETTE.parity },
  ],
});

const controlsKpi = section({
  id: 'controls',
  title: '4 · Headline controls vs Supabase OSS',
  intro:
    `Four perimeter controls, each measured/gate-proven in-stack — and where the close-path is a ` +
    `recipe, it is labelled ROADMAP. The donut tallies all six §5 verdict rows.`,
  body: kpiGrid([
    { label: 'in-stack WAF', value: 'yes', tone: 'win', sub: 'Supabase OSS: no — they front managed cloud with their own Cloudflare' },
    { label: 'plane isolation', value: 'yes', tone: 'win', sub: '4 bridges, edge↛data refused (m66/m140)' },
    { label: 'IP allowlist', value: 'per-tenant', tone: 'parity', sub: 'control-plane, enforced on every API call (m106)' },
    { label: 'Cloudflare recipe', value: 'ready', tone: 'parity', sub: 'copy-pasteable Terraform/nginx — hosted deploy' },
  ]) + '\n<div style="margin-top:14px"></div>\n' + verdictDonut,
});

// ── 5. Cloudflare recipe (§4) — ordered, styled steps via calloutGrid ───────
const cfRecipe = section({
  id: 'cloudflare',
  title: '5 · Cloudflare front-door recipe (ROADMAP — hosted/managed deploy)',
  intro:
    `For a <strong>hosted</strong> Grobase deploy, put Cloudflare in front of the in-stack WAF as a ` +
    `second, defense-in-depth perimeter (the in-stack WAF stays on — belt and braces). These are a ` +
    `${badge('deployment recipe — ROADMAP', 'parity')}, not a measured in-stack control. The real ` +
    `config knobs from §4 of the doc:`,
  body: calloutGrid([
    {
      title: '1 · DNS — proxied (orange-cloud)',
      tone: 'brand',
      badge: 'step 1',
      body: 'cloudflare_record: type=A, value=origin_ip (host running the in-stack WAF :443), ' +
        'proxied=true (ORANGE cloud), ttl=1. Origin :443 firewalled to Cloudflare IP ranges only.',
    },
    {
      title: '2 · WAF managed + custom rules',
      tone: 'brand',
      badge: 'step 2',
      body: 'cloudflare_ruleset phase=http_request_firewall_managed: execute Cloudflare Managed ' +
        'Ruleset (id efb7b8c9…) + OWASP Core Ruleset (id 4814384a…). Custom rule blocks ' +
        '/admin/v1/ at the edge too (defense in depth).',
    },
    {
      title: '3 · Rate-limiting',
      tone: 'brand',
      badge: 'step 3',
      body: 'phase=http_ratelimit on /data/v1/: characteristics [cf.colo.id, ip.src], period 60s, ' +
        '600 req/period, mitigation_timeout 600. Complements the in-stack per-tenant token bucket (m51).',
    },
    {
      title: '4 · Bot management / Turnstile',
      tone: 'brand',
      badge: 'step 4',
      body: 'managed_challenge on /auth/v1/signup or cf.client.bot_score < 30. Pair with a Turnstile ' +
        'widget; verify cf-turnstile-response server-side before issuing a session.',
    },
    {
      title: '5 · Full-strict TLS + AOP (mTLS to origin)',
      tone: 'brand',
      badge: 'step 5',
      body: 'ssl="strict" (Full strict), min_tls 1.2, tls_1_3 on, always_use_https. ' +
        'authenticated_origin_pulls enabled; on the WAF nginx: ssl_client_certificate ' +
        'cloudflare-origin-pull-ca.pem + ssl_verify_client on → cryptographic origin lock.',
    },
    {
      title: '6 · Cache rules',
      tone: 'brand',
      badge: 'step 6',
      body: 'phase=http_request_cache_settings: NEVER cache /data/v1/ or /auth/v1/ ' +
        '(per-tenant + authenticated); cache static assets (js/css/png/svg/woff2) at edge_ttl 86400.',
    },
  ]),
});

// ── 6. honest caveat (§4 / §5 bottom line) ──────────────────────────────────
const caveat = section({
  id: 'caveat',
  title: '6 · Honest framing — the one parity note',
  intro: 'Where Grobase does <em>not</em> outright win in-stack, the path is explicit and labelled.',
  body: calloutGrid([
    {
      title: 'Self-host perimeter — Grobase WINS',
      tone: 'win',
      badge: 'WIN',
      body: 'For a self-hosted deploy Grobase ships an OWASP-CRS WAF as the sole public listener and ' +
        'per-plane segmentation that Supabase OSS simply does not have. Plus full data residency: ' +
        'all of the above runs entirely in the operator\'s own infra.',
    },
    {
      title: 'Volumetric DDoS scrubbing — parity-via-Cloudflare',
      tone: 'parity',
      badge: 'parity',
      body: 'In-stack we have a per-tenant token bucket (m51) + WAF CRS. Edge volumetric DDoS ' +
        'scrubbing needs the §4 Cloudflare front-door. Supabase managed leans on its own Cloudflare; ' +
        'the §4 recipe gives a Grobase hosted deploy the same outer perimeter — on top of the in-stack WAF.',
    },
    {
      title: 'Managed IP-restriction dashboard — parity-via-own-VPC',
      tone: 'parity',
      badge: 'parity',
      body: 'Supabase\'s network restrictions are a polished managed dashboard (paid). Grobase\'s ' +
        'per-tenant allowlist is config + a control-plane endpoint, enforced on every API call and ' +
        're-verifiable by the operator (m106). A dashboard toggle is a DX nicety, not a control gap.',
    },
    {
      title: 'Origin mTLS lock (AOP) — parity once §4.5 applied',
      tone: 'parity',
      badge: 'parity',
      body: 'Authenticated Origin Pulls is a deployment step (nginx ssl_verify_client on, mount ' +
        'Cloudflare\'s origin-pull CA). Once applied, a request that did not come through Cloudflare ' +
        'is rejected at TLS — parity with Supabase managed AOP.',
    },
  ]),
});

// ── 7. reproduce (gates) ────────────────────────────────────────────────────
const reproduce = section({
  id: 'reproduce',
  title: '7 · Reproduce',
  intro: 'Every in-stack control above is re-verifiable by a self-contained gate.',
  body:
    evidenceCard({
      title: 'In-stack network controls — gates',
      status: 'PASS',
      lines: [
        '# WAF block/pass (SQLi/XSS/traversal 403, benign 200) + edge↛data segmentation:',
        'bash mini-baas-infra/scripts/verify/m140-network-controls.sh',
        '',
        '# Segmentation parity/superset + hard-isolation (throwaway scratch):',
        'bash mini-baas-infra/scripts/verify/m66-netseg.sh',
        '',
        '# Per-tenant IP allowlist enforcement + parity:',
        'bash mini-baas-infra/scripts/verify/m106-ip-allowlist.sh',
      ],
      gate: 'm140 · m66 · m106',
    }) +
    '\n<div style="margin-top:14px"></div>\n' +
    calloutGrid([
      {
        title: 'WAF',
        tone: 'win',
        body: 'docker/services/waf/Dockerfile + conf/{nginx,modsecurity,crs-setup}.conf',
      },
      {
        title: 'Segmentation',
        tone: 'win',
        body: 'docker-compose.netseg.yml — 4 internal:true bridges',
      },
      {
        title: 'Edge IP-restrict',
        tone: 'win',
        body: 'docker/services/kong/conf/kong.yml (ip-restriction on /admin/v1/*)',
      },
      {
        title: 'Per-tenant allowlist',
        tone: 'parity',
        body: 'control-plane internal/… + migration 049, gate m106',
      },
    ]),
});

// ── assemble ────────────────────────────────────────────────────────────────
const html = renderPage({
  title: 'Network controls & Cloudflare front-door',
  subtitle: 'In-stack OWASP-CRS WAF · per-plane segmentation · per-tenant IP allowlist — vs Supabase',
  accent: PALETTE.brand,
  updated: '2026-06-15',
  sections: [
    overview, perimeter, wafSection, segSection, controlsKpi, cfRecipe, caveat, reproduce,
  ],
});

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, html, 'utf8');
process.stdout.write(`wrote ${OUT} (${Buffer.byteLength(html, 'utf8')} bytes)\n`);
process.stdout.write(`subtree ${SUBTREE}\n`);
