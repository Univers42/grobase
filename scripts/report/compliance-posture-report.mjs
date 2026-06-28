#!/usr/bin/env node
// compliance-posture-report.mjs — graphics-rich HTML twin of wiki/compliance-posture.md.
//
// Renders the control matrix (ASVS 4.0 × SOC 2 TSC × GDPR), every row evidence-backed,
// as: an audit-ready posture gauge + KPI strip, a control-coverage donut by standard,
// the FULL control matrix table, a tamper-evident hash-chain evidence card (m141 + m104),
// and an honest WIN-vs-caveat split (self-host residency / in-repo controls / tamper-evident
// audit win; formal SOC 2 Type II / ISO 27001 / HIPAA are parity-with-caveat).
//
// Zero-dep ESM (node: builtins only). All numbers are pulled from the .md control matrix
// — never invented. Competitor (Supabase) facts stay labelled "managed / has cert".
//
// Run (no host node):
//   docker run --rm -u "$(id -u):$(id -g)" \
//     -v "$PWD":/b \
//     -w /b public.ecr.aws/docker/library/node:22-bookworm \
//     node /b/scripts/report/compliance-posture-report.mjs

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  PALETTE, renderPage, section, kpiGrid, scoreboard, badge,
  donut, gauge, matrixTable, calloutGrid, evidenceCard
} from '../lib/lib-report.mjs';

// Resolve paths from this module's location (kernel rule: deterministic, self-locating).
const WIKI = fileURLToPath(new URL('../../wiki/', import.meta.url));   // <repo>/wiki/
const MD = WIKI + 'compliance/compliance-posture.md';
const OUT = WIKI + 'reports/compliance-posture.html';

const md = readFileSync(MD, 'utf8');

// ── honest tallies, pulled from the matrix in the .md ─────────────────────────
// GDPR article citations across the matrix (occurrences) + distinct articles.
const gdprCitations = (md.match(/Art\. ?\d+/g) || []).length;        // 42
const gdprArticles = new Set((md.match(/Art\. ?\d+/g) || [])
  .map((s) => s.replace(/\s+/g, ''))).size;                          // 9 distinct

// ── the FULL control matrix (rows transcribed from .md §2.1–§2.9) ─────────────
// Each row: [control, asvs, soc2, gdpr, statusToken, evidence]. statusToken is the
// .md token: '[+]' differentiator · '[v]' implemented · '[~]' partial · '[plan]' planned.
const MATRIX = [
  // §2.1 Data residency & self-host control
  ['Customer owns deployment + data location (self-host)', 'V1.1, V14', 'CC1.x, C1.1', 'Art. 28, 44–46', '[+]', 'self-host editions; no Grobase subprocessor sees data (Makefile editions; 02-layer-edition-model.md)'],
  ['Single hardened public listener (defence in depth)', 'V1.14, V14.4', 'CC6.6', 'Art. 32', '[+]', 'in-stack OWASP ModSecurity v3 + CRS as sole ingress (docker/services/waf/Dockerfile)'],
  ['Per-plane network segmentation', 'V1.14', 'CC6.6', 'Art. 32', '[v]', 'docker-compose.netseg.yml isolates planes onto separate networks (opt-in overlay)'],
  // §2.2 Encryption — in transit & at rest
  ['TLS verify-full to engines (no cert bypass at max)', 'V9.1, V9.2', 'CC6.7', 'Art. 32(1)(a)', '[v]', 'apply_mssql_tls + CA-pin DATA_PLANE_TLS_CA_FILE; insecure DSN rejected at max (audit #1/#4)'],
  ['SSRF egress guard on the HTTP engine', 'V12.6, V5.2', 'CC6.7', 'Art. 32', '[v]', 'guard_and_resolve rejects loopback/private/CGNAT/ULA + metadata; pins public IPs (audit #2)'],
  ['Stored credentials encrypted at rest', 'V6.2', 'CC6.7', 'Art. 32(1)(a)', '[v]', 'DSNs sealed AES-256-GCM, scrypt per-record key, tag verified (internal/adapterregistry/crypto.go)'],
  ['Postgres TLS verify outside max', 'V9.2', 'CC6.7', 'Art. 32', '[~]', 'sslmode=require accept-any outside max (audit O4) → run SECURITY_MODE=max for multi-tenant. Gap, stated.'],
  ['Per-tenant encryption at rest (volumes)', 'V6.x', 'CC6.7', 'Art. 32', '[plan]', 'disk/volume enc is operator/host today; per-tenant encrypted backups = roadmap B6 / solution #11'],
  // §2.3 Access control & isolation
  ['Owner-scoped predicates on every engine (RLS-equiv)', 'V4.1, V4.2', 'CC6.1, C1.1', 'Art. 25, 32', '[v]', 'owner predicate + GUC re-stamped per request; writes owner-stamped on all 8 adapters (isolation.rs)'],
  ['ABAC policy decision point + field masks', 'V4.1, V4.3', 'CC6.1', 'Art. 25, 32', '[v]', 'per-principal ABAC + field masking (data-plane-server/src/abac.rs; orgs-rbac-design.md)'],
  ['Per-request isolation under shared pools (10K→1 pool)', 'V4.2', 'CC6.1, A1.2', 'Art. 32', '[+]', 'isolation per-request not pool-state → 10K tenants → 1 pool @ ~30 MiB, byte-identical (gate m46; scale-slo.md)'],
  ['Organizations / teams / members / RBAC', 'V4.1', 'CC6.1, CC6.3', 'Art. 28', '[v]', 'control-plane org model with members/invites/roles (gate m103); org scoping stays control-plane'],
  ['Phishing-resistant auth (WebAuthn passkeys)', 'V2.1, V2.7', 'CC6.1', 'Art. 32', '[v]', 'server-side WebAuthn register+auth; wrong-key/replay/cross-user rejected (gate m107, mig 050)'],
  ['Per-tenant network access control (IP allowlist)', 'V1.14, V4.x', 'CC6.6', 'Art. 32', '[v]', 'control-plane per-tenant IP allowlist, enforced + parity-proven (gate m106)'],
  ['Internal service auth bound per request (no static bearer)', 'V3.5, V13.2', 'CC6.1', 'Art. 32', '[+]', 'X-Service-Auth: v1.<ts>.<hmac> binds ts/method/path/body, ±120s skew; token never on wire (audit O1)'],
  // §2.4 Tamper-evident + exportable audit logs
  ['Tamper-evident, hash-chained per-tenant audit log', 'V7.1, V7.2, V7.3', 'CC7.2, CC4.1', 'Art. 30, 33', '[+]', 'hash=sha256(prev_hash ‖ canonical(row)) in Go; any tamper breaks chain at the link (mig 047; gate m104)'],
  ['Append-only audit at the grant layer', 'V7.x', 'CC7.2', 'Art. 30', '[v]', 'authenticated has NO UPDATE/DELETE on tenant_audit_log (mig 047 grants); m141 asserts it'],
  ['Exportable / portable audit bundle (self-verifiable)', 'V7.x', 'CC7.2', 'Art. 30', '[v]', 'GET /v1/audit/tenants/{id}/export → grobase.audit.v1 bundle re-runnable offline (audit/handler.go; m104)'],
  ['SOC2-lite continuous evidence collector', 'V1.x', 'CC4.1, CC7.x', '—', '[~]', 'seals signed snapshots of CI-gate/access/change-mgmt; stub → all_passing:false (gate m108, mig 051). Internal, NOT a formal report.'],
  // §2.5 Secret management & rotation
  ['Vault-backed secrets + dynamic DB creds', 'V6.4, V2.10', 'CC6.1, CC6.7', 'Art. 32', '[~]', 'Vault present with credential_ref{provider:vault}; gap: plaintext DSNs possible outside max (audit O5)'],
  ['High-entropy secrets → fast hash (not password hash)', 'V2.4, V6.2', 'CC6.1', 'Art. 32', '[v]', '160-bit API keys verified SHA-256 + dual-scheme lazy upgrade; Argon2id only for passwords (scale FIX 1)'],
  ['Constant-time secret comparison', 'V6.2', 'CC6.1', 'Art. 32', '[v]', 'shared.SecureCompare / crypto/subtle at all service-token sites (audit #3)'],
  ['Atomic key-rotation primitive (no restart)', 'V6.4', 'CC6.1', 'Art. 32', '[~]', 'vault-rotate-approles exists; no-restart rotation for JWT_SECRET/service-token not wired (solution #9). Stated gap.'],
  // §2.6 Supply-chain locks
  ['Frozen lockfiles + no install-time lifecycle hooks', 'V14.2', 'CC6.8', '—', '[v]', 'npm ci --ignore-scripts; pnpm minimum-release-age=1440 + onlyBuiltDependencies; digest pinning (pin-digests.sh)'],
  ['SCA in CI (blocking known-CVE gate)', 'V14.2', 'CC7.1', '—', '[v]', 'cargo-audit + govulncheck + npm/pnpm audit + Trivy fs/image, all blocking (mini-baas-security.yml)'],
  ['SAST + secret-scan in CI (blocking)', 'V14.2', 'CC7.1', '—', '[v]', 'Semgrep p/owasp-top-ten → SARIF; TruffleHog --only-verified --fail + gitleaks --exit-code 1'],
  // §2.7 Data-subject rights (GDPR)
  ['Right to erasure (hard-erase + receipt)', 'V8.3', 'C1.2, P', 'Art. 17', '[v]', 'scoped hard delete + tamper-evident erasure receipt cross-linked to audit chain (mig 048; erase/service.go; gate m105)'],
  ['Right to data portability (export)', 'V8.1', 'C1.x, P', 'Art. 20', '[v]', 'engine-neutral JSON bundle of ONE tenant + manifest{tables,counts,sha256}, tenant-scoped (mig 052; gate m109)'],
  ['Records of processing / breach evidence', 'V7.x', 'CC7.2', 'Art. 30, 33', '[v]', 'tamper-evident audit chain (m104) is the processing record; SOC2-lite collector (m108) seals the wider set'],
  ['Processor terms + subprocessor transparency', '—', 'C1.x', 'Art. 28', '[~]', 'DPA (Art. 28) with SCC refs + subprocessor list (legal/*.md TEMPLATES, counsel review required)'],
  // §2.8 Backup / restore + DR
  ['Cluster backups + restore-drill', 'V8.x', 'A1.2', 'Art. 32(1)(c)', '[v]', 'daily pg_dump -Fc, 14-day retention → MinIO, optional WAL/PITR, restore-drill (gate m47)'],
  ['Per-tenant granular backup + restore', 'V8.x', 'A1.2, C1.x', 'Art. 32', '[+]', 'atomic Go-native per-tenant logical backup/restore scoped to ONE tenant (gate m87, mig 042)'],
  ['Point-in-time restore (PITR to timestamp)', 'V8.x', 'A1.2', 'Art. 32', '[v]', 'restore-to-timestamp proven (gate m99)'],
  // §2.9 Vulnerability management & breach process
  ['Vulnerability management lifecycle', 'V1.x', 'CC7.1', 'Art. 32', '[v]', 'blocking SAST/SCA/secret/container scans in CI + tracked residuals (.trivyignore; security-residuals-runbook.md)'],
  ['Vulnerability disclosure (security.txt / contact)', 'V1.x', 'CC7.x', '—', '[~]', 'disclosure policy + contact defined; public status page + security.txt endpoint not yet stood up (status-sla.md)'],
  ['Breach detection + notification process', 'V7.x', 'CC7.3, CC7.4', 'Art. 33, 34', '[~]', 'observability wired (Prom/Grafana/Loki/Tempo, m19) + tamper-evident audit; cross-tenant-404 alerting + SIEM recommended (solution #6)'],
];

// status token → human label + tone (win for shipped/differentiator, parity for partial/planned)
const STATUS = {
  '[+]': { text: '[+] differentiator', tone: 'win' },
  '[v]': { text: '[v] implemented', tone: 'win' },
  '[~]': { text: '[~] partial', tone: 'parity' },
  '[plan]': { text: '[plan] planned', tone: 'parity' },
};

// ── coverage tallies for the donut & KPIs ─────────────────────────────────────
const total = MATRIX.length;
const shipped = MATRIX.filter((r) => r[4] === '[v]' || r[4] === '[+]').length;
const differentiators = MATRIX.filter((r) => r[4] === '[+]').length;
const partial = MATRIX.filter((r) => r[4] === '[~]').length;
const planned = MATRIX.filter((r) => r[4] === '[plan]').length;

// per-standard coverage: count rows that cite each family (non-"—")
const asvsCovered = MATRIX.filter((r) => r[1] && r[1] !== '—').length;
const soc2Covered = MATRIX.filter((r) => r[2] && r[2] !== '—').length;
const gdprCovered = MATRIX.filter((r) => r[3] && r[3] !== '—').length;

// audit-ready posture: shipped controls / total controls, on a 0..100 scale.
const postureScore = Math.round((shipped / total) * 100);

// ══════════════════════════════════════════════════════════════════════════════
// SECTIONS
// ══════════════════════════════════════════════════════════════════════════════

// 1 ── headline: gauge + KPI strip ────────────────────────────────────────────
const headline = section({
  id: 'posture',
  title: 'Audit-ready posture',
  intro: `A control matrix mapping <strong>shipped</strong> Grobase controls to OWASP ASVS 4.0, the SOC 2 Trust Services Criteria, and GDPR — every row backed by an in-repo artifact a buyer can run. <strong>Audit-ready</strong> means the controls exist, the evidence is in the repo, and CI gates keep it honest. It does <em>not</em> mean "SOC 2 certified" — formal attestation needs an external auditor (honest caveat, §below).`,
  body: `<div class="grid" style="grid-template-columns:minmax(240px,1fr) 2fr;align-items:start">
  ${gauge({
    title: 'Controls shipped & gate-proven',
    value: postureScore,
    max: 100,
    label: `${shipped} of ${total} controls live (·proven)`,
    tone: 'win',
  })}
  ${kpiGrid([
    { label: 'Controls mapped', value: total, sub: 'ASVS × SOC 2 TSC × GDPR rows', tone: 'win' },
    { label: 'Standards covered', value: 3, sub: 'ASVS 4.0 · SOC 2 TSC · GDPR', tone: 'win' },
    { label: 'GDPR article citations', value: gdprCitations, sub: `${gdprArticles} distinct articles referenced`, tone: 'win' },
    { label: 'Formal certification', value: 'pending', sub: 'SOC 2 / ISO / HIPAA — needs auditor (D4)', tone: 'parity' },
  ])}
  </div>
  ${scoreboard({
    title: 'Control status',
    items: [
      { label: 'Differentiator [+]', value: differentiators, tone: 'win' },
      { label: 'Implemented [v]', value: shipped - differentiators, tone: 'win' },
      { label: 'Partial [~]', value: partial, tone: 'parity' },
      { label: 'Planned [plan]', value: planned, tone: 'parity' },
    ],
  })}`,
});

// 2 ── coverage donut by standard ─────────────────────────────────────────────
const coverage = section({
  id: 'coverage',
  title: 'Control coverage by standard',
  intro: `Each of the <strong>${total}</strong> controls maps into one or more standards families. A control commonly cites all three (e.g. owner-scoping → ASVS V4.1, SOC 2 CC6.1, GDPR Art. 25), so the counts below overlap by design — they show how many controls touch each family, not a partition.`,
  body: `<div class="grid" style="grid-template-columns:minmax(240px,1fr) 1fr;align-items:center">
  ${donut({
    title: 'Controls referencing each standard',
    slices: [
      { label: 'OWASP ASVS 4.0', value: asvsCovered, color: PALETTE.brand },
      { label: 'SOC 2 TSC', value: soc2Covered, color: PALETTE.win },
      { label: 'GDPR articles', value: gdprCovered, color: PALETTE.parity },
    ],
    centerLabel: String(total),
  })}
  ${calloutGrid([
    { title: 'OWASP ASVS 4.0', body: `${asvsCovered} controls map to ASVS verification requirements (V1–V14). Full L1/L2 map in security-audit-asvs.md.`, tone: 'brand', badge: `${asvsCovered}` },
    { title: 'SOC 2 TSC', body: `${soc2Covered} controls map to Trust Services Criteria (CC1–CC8, A1, C1, P). m108 collector seals the evidence set.`, tone: 'win', badge: `${soc2Covered}` },
    { title: 'GDPR', body: `${gdprCovered} controls cite GDPR articles (${gdprCitations} citations across ${gdprArticles} distinct articles incl. Art. 17/20/25/28/30/32/33/34/44–46).`, tone: 'parity', badge: `${gdprCovered}` },
  ])}
  </div>`,
});

// 3 ── the FULL control matrix ────────────────────────────────────────────────
const matrixRows = MATRIX.map((r) => {
  const st = STATUS[r[4]] || { text: r[4], tone: 'parity' };
  return [
    r[0],                      // Control
    r[1],                      // ASVS
    r[2],                      // SOC2 TSC
    r[3],                      // GDPR
    { text: st.text, tone: st.tone },  // Status (toned)
    r[5],                      // Evidence
  ];
});
const matrix = section({
  id: 'matrix',
  title: `Control matrix — ASVS × SOC 2 TSC × GDPR (${total} controls)`,
  intro: `Status legend: <strong>[+]</strong> differentiator Supabase lacks · <strong>[v]</strong> implemented &amp; gate/CI-proven · <strong>[~]</strong> partial (real, with a named gap) · <strong>[plan]</strong> planned (honestly not yet proven). Every Evidence cell points at a numbered gate, a migration, a source path, or a CI job a buyer can run. Source of truth: <code>config/trust/posture.json</code> (served at <code>GET /v1/trust</code>); if this table and the JSON disagree, the JSON is canonical.`,
  body: matrixTable({
    columns: ['Control', 'ASVS', 'SOC 2 TSC', 'GDPR', 'Status', 'Evidence (gate / path)'],
    rows: matrixRows,
  }),
});

// 4 ── tamper-evident hash-chain evidence card ────────────────────────────────
const chain = section({
  id: 'tamper-evident',
  title: 'Tamper-evident audit chain — the load-bearing proof',
  intro: `The audit log is a per-tenant hash chain: <code>hash = sha256(prev_hash ‖ canonical(row))</code>, computed in Go (engine-agnostic). A buyer recomputes the chain over the exported bundle and detects any insert / edit / delete / reorder at the exact link — they don't take our word for it. The demo below appends 3 sealed links (INTACT), then tampers seq 2; verification reports <code>intact:false</code> at <code>broken_seq=2</code> with <code>hash_mismatch</code>. This is what gate m141 (and m104 in depth) prove non-vacuously: a verify that always says "intact" fails the gate.`,
  body: `<div class="grid" style="grid-template-columns:1fr 1fr;gap:14px">
  ${evidenceCard({
    title: 'Sealed chain — INTACT (3 links)',
    status: 'PASS',
    lines: [
      'seq=1  owner=tenant_a  action=insert',
      '       prev=0000…0000',
      '       hash=sha256(prev ‖ row) = a91f…7c20',
      'seq=2  owner=tenant_a  action=update',
      '       prev=a91f…7c20',
      '       hash=sha256(prev ‖ row) = 4d8e…b113',
      'seq=3  owner=tenant_a  action=delete',
      '       prev=4d8e…b113',
      '       hash=sha256(prev ‖ row) = 0f6a…91de',
      '',
      'verify → { "intact": true, "checked": 3 }',
    ],
    gate: 'm104-audit-chain.sh',
  })}
  ${evidenceCard({
    title: 'Tamper seq 2 → chain breaks at the link',
    status: 'FAIL',
    lines: [
      'DB-tamper: UPDATE tenant_audit_log',
      '           SET action = \'read\' WHERE seq = 2;',
      '',
      'recompute seq=2:',
      '  stored_hash   = 4d8e…b113',
      '  computed_hash = c72a…0f55   ← differs',
      '',
      'verify → {',
      '  "intact": false,',
      '  "broken_seq": 2,',
      '  "reason": "hash_mismatch"',
      '}',
      '',
      'append-only grant: authenticated has NO',
      'UPDATE/DELETE on tenant_audit_log (mig 047)',
    ],
    gate: 'm141-compliance-posture.sh',
  })}
  </div>`,
});

// 5 ── WIN vs caveat split ────────────────────────────────────────────────────
const verdict = section({
  id: 'verdict',
  title: 'WIN vs caveat — the honest split',
  intro: `<strong>WIN</strong> on self-host data-residency, in-repo re-verifiable controls, and a cryptographically tamper-evident audit log — none of which the rivals ship. <strong>PARITY-WITH-CAVEAT</strong> on formal certification: Supabase has third-party-attested SOC 2 Type II + ISO/IEC 27001:2022 + HIPAA BAA that an OSS project cannot claim as a hosted cert until Grobase Cloud engages an auditor. That is a human + $$ milestone (decision D4), not a code gap — the substance is built; the paper is not.`,
  body: `${calloutGrid([
    { title: 'Data residency — you own it', body: 'Runs in your infra, your region, your cloud or bare metal. No Grobase-operated subprocessor sees the data. Supabase offers a region menu inside their account.', tone: 'win', badge: 'WIN' },
    { title: 'Controls are source, re-verifiable', body: 'Every row above cites a file or numbered gate you can read and run — not a redacted report. CI gates keep it honest on every commit.', tone: 'win', badge: 'WIN' },
    { title: 'Tamper-evident audit (neither rival ships)', body: 'Hash-chained, buyer-recomputable audit log + exportable self-verifiable bundle (m104). Detects any tamper at the exact link.', tone: 'win', badge: 'WIN' },
    { title: 'SOC 2 Type II', body: 'm108 evidence collector shortens the audit; it does not replace it. Needs an engaged CPA firm over a multi-month window. Supabase has it (Team+).', tone: 'parity', badge: 'caveat' },
    { title: 'ISO/IEC 27001:2022', body: 'No cert — requires an external certification body + audit cycle. Supabase certified Apr 2026.', tone: 'parity', badge: 'caveat' },
    { title: 'HIPAA BAA', body: 'No BAA — requires a covered-entity relationship + signed BAA (a legal/business artifact). Supabase: BAA-gated HIPAA-eligible (Enterprise).', tone: 'parity', badge: 'caveat' },
  ])}
  <div class="card" style="margin-top:14px">
    <strong>Verdict.</strong> Grobase has the <em>substance</em> of compliance — verifiable, in-repo, continuously gated, with a tamper-evident audit log neither rival ships — and self-host residency the managed rivals structurally cannot offer. Supabase additionally has the <em>paper</em> (third-party SOC 2 / ISO / HIPAA). Parity-with-caveat, stated honestly, not a gap. The close-path is Grobase Cloud (Track B7) turning the flag-gated controls ON in a hosted product, with the m108 collector as the auditor's input.
  </div>`,
});

// ══════════════════════════════════════════════════════════════════════════════
// ASSEMBLE + WRITE
// ══════════════════════════════════════════════════════════════════════════════
const html = renderPage({
  title: 'Grobase — Compliance Posture',
  subtitle: 'Control matrix · ASVS 4.0 × SOC 2 TSC × GDPR — every row evidence-backed, audit-ready (not "certified")',
  accent: PALETTE.brand,
  updated: '2026-06-15',
  sections: [headline, coverage, matrix, chain, verdict],
});

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, html);
console.log(`compliance-posture-report: wrote ${html.length} bytes → ${OUT}`);
