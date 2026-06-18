# Grobase — Compliance Posture (Control Matrix)

> **What this is.** A single **control matrix** mapping Grobase's *shipped* controls to
> **OWASP ASVS 4.0**, the **SOC 2 Trust Services Criteria (TSC)**, and the relevant
> **GDPR articles** — with, for every control, an **in-repo artifact** (a numbered gate
> `mNN`, a migration, a source path, or a CI job) a buyer can run themselves.
>
> **Honesty bar (kernel #4 — a claim without an artifact is not on this page).** Grobase
> is **AUDIT-READY**, not **"SOC 2 certified."** Audit-ready means the *controls exist*,
> the *evidence is in the repo*, the *standards mapping is explicit*, and *CI gates keep
> it honest*. A formal SOC 2 Type II / HIPAA / ISO 27001 attestation needs an external
> auditor over a multi-month window plus a business milestone — that is **deferred
> (decision D4)** and labelled **planned** below, never claimed.

This doc is the **control-matrix half** of the trust story. Its companions:
[`security-audit-asvs.md`](../security/security-audit-asvs.md) (the full ASVS L1/L2 map + open
residuals), [`trust-center.md`](../security/trust-center.md) (the public posture page), and the
**machine-readable** [`config/trust/posture.json`](../../mini-baas-infra/config/trust/posture.json)
served at `GET /v1/trust`. If this page and the JSON disagree, **the JSON is canonical.**

**Gate:** [`scripts/verify/m141-compliance-posture.sh`](../../mini-baas-infra/scripts/verify/m141-compliance-posture.sh)
runs this matrix's load-bearing checks live (see §6).

---

## 1. The headline (win + the one honest caveat)

| | Grobase (self-host / OSS) | Supabase (managed) |
|---|---|---|
| **Data residency** | **You own it** — runs in your infra, your region, your cloud or bare metal. No subprocessor sees the data. | Their region menu; data lives in their account / subprocessors. |
| **Control set** | **In-repo + transparent** — every control is source you can read, run, and modify. | Closed; you trust the attestation. |
| **Audit log** | **Tamper-evident, hash-chained, exportable** — a buyer recomputes the chain (`sha256(prev_hash‖canonical(row))`) and detects any insert/edit/delete/reorder at the exact link (gate **m104**). | Audit logs exist; not a buyer-recomputable cryptographic chain. |
| **GDPR rights** | **Erase (Art. 17) + export (Art. 20) are shipped + gate-proven** (m105 / m109) with a tamper-evident erasure receipt. | Shipped as platform features. |
| **Formal certification** | **No external attestation** (audit-ready posture only). ← *the caveat* | **SOC 2 Type II + ISO/IEC 27001:2022 (Apr 2026) + HIPAA BAA (Enterprise).** ← *they win here* |

**Verdict:** **WIN on self-host data-residency + transparency + in-repo, re-verifiable
evidence (incl. a cryptographically tamper-evident audit log neither rival ships);
PARITY-WITH-CAVEAT on formal certification** — Supabase has third-party-attested SOC 2 /
ISO / HIPAA that an OSS project cannot claim as a *hosted cert* until Grobase Cloud engages
an auditor (a human + $$ milestone, not a code gap).

---

## 2. Control matrix — ASVS × SOC 2 TSC × GDPR, every row backed by an artifact

Status: **`[v]` implemented & gate/CI-proven · `[~]` partial (real, with a named gap) ·
`[+]` differentiator Supabase lacks · `[plan]` planned (honestly not yet proven).**

### 2.1 Data residency & self-host control

| Control | ASVS | SOC 2 TSC | GDPR | Status | In-repo evidence |
|---|---|---|---|---|---|
| Customer owns deployment + data location (self-host) | V1.1 (SDLC), V14 | CC1.x, **C1.1** | **Art. 28** (processor), **Art. 44–46** (transfers) | `[+]` | Single-binary / Docker self-host; no Grobase-operated subprocessor sees data — `mini-baas-infra/Makefile` editions; `wiki/02-layer-edition-model.md`. Supabase cannot offer customer-owned residency. |
| Single hardened public listener (defence in depth) | V1.14, V14.4 | **CC6.6** | Art. 32 | `[+]` | In-stack **OWASP ModSecurity v3 + CRS** as sole public ingress (`docker/services/waf/Dockerfile`); data plane is server-to-server only. |
| Per-plane network segmentation | V1.14 | **CC6.6** | Art. 32 | `[v]` | `docker-compose.netseg.yml` isolates the planes onto separate networks (opt-in overlay) — Supabase ships no in-stack segmentation. |

### 2.2 Encryption — in transit & at rest

| Control | ASVS | SOC 2 TSC | GDPR | Status | In-repo evidence |
|---|---|---|---|---|---|
| TLS verify-full to engines (no cert bypass at max) | V9.1, V9.2 | **CC6.7** | **Art. 32(1)(a)** | `[v]` | `apply_mssql_tls` verifies + refuses insecure under `SECURITY_MODE=max`; CA-pin via `DATA_PLANE_TLS_CA_FILE`; mongo/redis insecure DSN params rejected at max (`security-audit-asvs.md` §V9/V13; audit #1/#4). |
| SSRF egress guard on the HTTP engine | V12.6, V5.2 | CC6.7 | Art. 32 | `[v]` | `guard_and_resolve` rejects loopback/private/CGNAT/ULA + cloud-metadata + pins to validated public IPs (data-plane-pool; audit #2). |
| Stored credentials encrypted at rest | V6.2 | **CC6.7** | Art. 32(1)(a) | `[v]` | Connection strings sealed AES-256-GCM, scrypt-derived per-record key, GCM tag verified on decrypt — `internal/adapterregistry/crypto.go`. |
| Postgres TLS verify outside max | V9.2 | CC6.7 | Art. 32 | `[~]` | `sslmode=require` is accept-any *outside* `max` (audit O4) → run `SECURITY_MODE=max` for multi-tenant. **Gap, stated.** |
| Per-tenant encryption at rest (volumes) | V6.x | CC6.7 | Art. 32 | `[plan]` | Disk/volume encryption is operator/host responsibility today; per-tenant encrypted backups are roadmap B6 / audit solution #11. Labelled planned in `posture.json`. |

### 2.3 Access control & isolation

| Control | ASVS | SOC 2 TSC | GDPR | Status | In-repo evidence |
|---|---|---|---|---|---|
| Owner-scoped predicates on **every** engine (RLS-equiv) | V4.1, V4.2 | **CC6.1**, C1.1 | **Art. 25** (by design), Art. 32 | `[v]` | Owner predicate + GUC re-stamped per request; writes owner-stamped on all 8 adapters — `data-plane-core/src/isolation.rs`. |
| ABAC policy decision point + field masks | V4.1, V4.3 | CC6.1 | Art. 25, Art. 32 | `[v]` | Per-principal ABAC + field masking — `data-plane-server/src/abac.rs`; `wiki/orgs-rbac-design.md`. |
| Per-request isolation under shared pools (10K→1 pool) | V4.2 | CC6.1, **A1.2** | Art. 32 | `[+]` | Isolation is per-**request**, not pool-state → 10K tenants collapse onto 1 pool @ ~30 MiB, byte-identical to per-tenant pools (gate **m46**; `scale-slo.md`). |
| Organizations / teams / members / RBAC | V4.1 | CC6.1, CC6.3 | Art. 28 | `[v]` | Control-plane org model with members/invites/roles (gate **m103**); org scoping stays control-plane to preserve shared-pool density. |
| Phishing-resistant auth (WebAuthn passkeys) | V2.1, V2.7 | CC6.1 | Art. 32 | `[v]` | Server-side WebAuthn register+auth; wrong-key / replay / cross-user rejected (gate **m107**, migration 050). |
| Per-tenant network access control (IP allowlist) | V1.14, V4.x | **CC6.6** | Art. 32 | `[v]` | Control-plane per-tenant IP allowlist, enforced + parity-proven (gate **m106**). |
| Internal service auth bound per request (no static bearer on the wire) | V3.5, V13.2 | CC6.1 | Art. 32 | `[+]` | `X-Service-Auth: v1.<ts>.<hmac>` binds ts/method/path/body, ±120 s skew, token never transits the wire (audit O1). |

### 2.4 Tamper-evident + exportable audit logs

| Control | ASVS | SOC 2 TSC | GDPR | Status | In-repo evidence |
|---|---|---|---|---|---|
| Tamper-evident, hash-chained per-tenant audit log | V7.1, V7.2, V7.3 | **CC7.2**, CC4.1 | Art. 30 (records), Art. 33 (breach evidence) | `[+]` | `hash = sha256(prev_hash ‖ canonical(row))`, computed in Go (engine-agnostic). Any insert/edit/delete/reorder breaks the chain at the exact link. Migration 047; `internal/audit/chain.go`; **gate m104** proves a tampered row → `intact:false` at the broken seq. |
| Append-only audit at the grant layer | V7.x | CC7.2 | Art. 30 | `[v]` | `authenticated` has **no** UPDATE/DELETE on `tenant_audit_log` (migration 047 grants); the m141-compliance-posture gate asserts this. |
| Exportable / portable audit bundle (self-verifiable) | V7.x | CC7.2 | Art. 30 | `[v]` | `GET /v1/audit/tenants/{id}/export` → `grobase.audit.v1` bundle (events + verify summary) re-runnable offline — `internal/audit/handler.go`; gate m104. |
| SOC2-lite continuous evidence collector | V1.x | **CC4.1**, CC7.x | — | `[~]` | Seals signed snapshots of CI-gate results, access posture, change-mgmt trail; a failing/stub control records `all_passing:false` + detects DB tamper (gate **m108**, migration 051). **Internal evidence, NOT a formal report** — see §3. |

### 2.5 Secret management & rotation

| Control | ASVS | SOC 2 TSC | GDPR | Status | In-repo evidence |
|---|---|---|---|---|---|
| Vault-backed secrets + dynamic DB creds | V6.4, V2.10 | CC6.1, CC6.7 | Art. 32 | `[~]` | Vault present (`docker/services/vault`) with `credential_ref{provider:vault}`; **gap:** plaintext DSNs possible outside `max` (audit O5) → forbid in prod. Stated. |
| High-entropy secrets → fast hash (not password hash) | V2.4, V6.2 | CC6.1 | Art. 32 | `[v]` | 160-bit API keys verified with SHA-256 + dual-scheme lazy upgrade; Argon2id only for password-class secrets (scale-program FIX 1). |
| Constant-time secret comparison | V6.2 | CC6.1 | Art. 32 | `[v]` | `shared.SecureCompare` / `crypto/subtle` at all service-token sites (audit #3). |
| Atomic key-rotation primitive (no restart) | V6.4 | CC6.1 | Art. 32 | `[~]` | `vault-rotate-approles` exists; rotation-without-restart for `JWT_SECRET`/service-token is not yet wired (audit solution #9). Stated gap. |

### 2.6 Supply-chain locks

| Control | ASVS | SOC 2 TSC | GDPR | Status | In-repo evidence |
|---|---|---|---|---|---|
| Frozen lockfiles + no install-time lifecycle hooks | V14.2 | **CC6.8** | — | `[v]` | `npm ci --ignore-scripts` (`src/.npmrc`); pnpm `minimum-release-age=1440` + `onlyBuiltDependencies` allowlist; digest pinning (`pin-digests.sh`). |
| SCA in CI (blocking known-CVE gate) | V14.2 | CC7.1 | — | `[v]` | cargo-audit (both Rust workspaces) + govulncheck + npm/pnpm audit + Trivy fs/image, all blocking in `.github/workflows/mini-baas-security.yml`. |
| SAST + secret-scan in CI (blocking) | V14.2 | CC7.1 | — | `[v]` | Semgrep `p/owasp-top-ten` → SARIF; TruffleHog `--only-verified --fail` + gitleaks `--exit-code 1`. `.env` gitignored, never tracked. |

### 2.7 Data-subject rights (GDPR)

| Control | ASVS | SOC 2 TSC | GDPR | Status | In-repo evidence |
|---|---|---|---|---|---|
| Right to erasure (hard-erase + receipt) | V8.3 | C1.2, P (privacy) | **Art. 17** | `[v]` | Scoped hard delete (`DROP SCHEMA … CASCADE` / `WHERE tenant_id`) + a tamper-evident **erasure receipt** cross-linked to the D3 audit chain (migration 048; `internal/erase/service.go`; **gate m105**). Gate proves the data is gone and another tenant is never touched. |
| Right to data portability (export) | V8.1 | C1.x, P | **Art. 20** | `[v]` | Engine-neutral JSON bundle of ONE tenant's data + manifest{tables, counts, sha256}, strictly tenant-scoped (migration 052; `internal/export/`; **gate m109**). |
| Records of processing / breach evidence | V7.x | CC7.2 | **Art. 30, Art. 33** | `[v]` | The tamper-evident audit chain (m104) is the processing record; the SOC2-lite collector (m108) seals the broader evidence set. |
| Processor terms + subprocessor transparency | — | C1.x | **Art. 28** | `[~]` | DPA (Art. 28) with SCC refs + subprocessor list — `wiki/legal/data-processing-addendum.md`, `wiki/legal/subprocessors.md` (TEMPLATES, counsel review required). |

### 2.8 Backup / restore + DR

| Control | ASVS | SOC 2 TSC | GDPR | Status | In-repo evidence |
|---|---|---|---|---|---|
| Cluster backups + restore-drill | V8.x | **A1.2** | Art. 32(1)(c) | `[v]` | Daily `pg_dump -Fc`, 14-day retention → MinIO, optional WAL/PITR, restore-drill (gate **m47**). |
| Per-tenant granular backup + restore | V8.x | A1.2, C1.x | Art. 32 | `[+]` | Atomic Go-native per-tenant logical backup/restore scoped to ONE tenant (gate **m87**, migration 042) — neither rival ships per-tenant granular restore. |
| Point-in-time restore (PITR to timestamp) | V8.x | A1.2 | Art. 32 | `[v]` | Restore-to-timestamp proven (gate **m99**). |

### 2.9 Vulnerability management & breach process

| Control | ASVS | SOC 2 TSC | GDPR | Status | In-repo evidence |
|---|---|---|---|---|---|
| Vulnerability management lifecycle | V1.x | **CC7.1** | Art. 32 | `[v]` | Blocking SAST/SCA/secret/container scans in CI + tracked accepted residuals (`.trivyignore`, `audit-deps.sh`); residuals runbook `wiki/security-residuals-runbook.md`. |
| Vulnerability disclosure (security.txt / contact) | V1.x | CC7.x | — | `[~]` | Disclosure policy + contact defined; the public status page + `security.txt` endpoint are on-demand infra not yet stood up (`wiki/status-sla.md`). Stated gap. |
| Breach detection + notification process | V7.x | **CC7.3, CC7.4** | **Art. 33, Art. 34** | `[~]` | Observability fully wired (Prometheus/Grafana/Loki/Tempo, gate m19) + tamper-evident audit as forensic evidence; cross-tenant-404 anomaly alerting + SIEM shipping recommended (audit solution #6). Process documented in `operations-runbook.md`. |

---

## 3. Formal certification — the honest caveat (Supabase wins here)

These are **planned**, not claimed. Calling them anything else would violate the honesty bar.

| Attestation | Grobase | Supabase | Why it's deferred (not a code gap) |
|---|---|---|---|
| **SOC 2 Type II** | `[plan]` — m108 evidence collector shortens the audit; it does **not** replace it. Needs an external auditor + multi-month observation window. | **Has it** (Team+). | Requires an engaged CPA firm + an operating company over time. |
| **ISO/IEC 27001:2022** | `[plan]` — no cert. | **Certified Apr 2026.** | Same: external certification body + audit cycle. |
| **HIPAA BAA** | `[plan]` — no BAA. | **BAA-gated HIPAA-eligible** (Enterprise). | Requires a covered-entity relationship + signed BAA — a legal/business artifact. |

**The close-path:** Grobase Cloud (Track B7 go-live) turns the flag-gated controls ON in a
hosted product, and the m108 evidence collector becomes the auditor's input. The *controls*
are already built and re-verifiable; the *certificate* is the human + $$ milestone. This is a
**parity-with-caveat**, not a gap — Grobase has the substance; Supabase additionally has the
paper.

---

## 4. Why the in-repo evidence beats a paper attestation (the differentiator)

A SOC 2 report tells a buyer *"trust this third party who looked once."* Grobase lets the
buyer **independently re-verify, continuously, in their own infra:**

- **The audit log is cryptographically re-checkable.** A buyer recomputes
  `sha256(prev_hash ‖ canonical(row))` over the exported bundle and detects any tamper at
  the exact link — they don't take our word for it (gate m104).
- **The controls are source.** Every row in §2 cites a file or gate they can read and run —
  not a redacted report.
- **The evidence is continuous.** CI gates (cargo-audit, govulncheck, Trivy, Semgrep,
  gitleaks, TruffleHog, ZAP) keep the posture honest on every commit; the m108 collector
  records reality (a stubbed control records `all_passing:false`).
- **They own the data.** Self-host means data residency is a *customer* decision — no
  subprocessor, no region menu, no transfer-mechanism paperwork.

---

## 5. Known gaps (stated, not hidden)

Carried verbatim from [`security-audit-asvs.md`](../security/security-audit-asvs.md) §3 so this matrix
never overclaims:

- **G-RS256** — RS256 issuer not flipped (verify side ready; GoTrue still signs HS256). MED, deferred cross-repo.
- **G-Vault** — Vault not *enforced*; plaintext DSNs possible outside `max`. MED.
- **G-ReadAudit** — only mutations + denials audited; sensitive reads not yet. LOW.
- **G-Rotate** — no atomic (no-restart) key-rotation primitive. LOW.
- **Encryption-at-rest per-tenant**, **public status page / security.txt**, **SIEM shipping** — planned.
- **No external attestation** (SOC 2 / ISO / HIPAA) — §3.

---

## 6. The gate — how this matrix is kept non-vacuous

[`scripts/verify/m141-compliance-posture.sh`](../../mini-baas-infra/scripts/verify/m141-compliance-posture.sh)
runs the load-bearing checks against a tenant-control built from current source on an
isolated, throwaway database (it never touches the shared stack):

1. **Docs + standards mapping exist and map all three families.** This matrix + the ASVS
   map + `posture.json` are present, non-empty, and reference ASVS + SOC 2 (CC6) + GDPR
   (≥4 article citations). A placeholder fails.
2. **No dangling evidence.** Every control `posture.json` claims *implemented* must resolve
   to an existing `verify/mNN-*.sh` or a real `wiki/` doc — a claim with no artifact fails.
3. **Tamper-evident audit actually verifies (the load-bearing assertion).** Append entries
   → recompute the chain (INTACT) → DB-tamper one row → verify reports `intact:false` at the
   exact `broken_seq` with `hash_mismatch`. A verify that always says "intact" **fails here**.
4. **GDPR rights are reachable + authorized.** The erase (Art. 17) and export (Art. 20)
   routes are mounted (not 404) under a service token and reject an unauthenticated call (401).

Run it:

```bash
bash apps/baas/mini-baas-infra/scripts/verify/m141-compliance-posture.sh
```

> **Naming note.** This gate is `m141-compliance-posture.sh`, the posture-level sibling of
> [`m104-audit-chain.sh`](../../mini-baas-infra/scripts/verify/m104-audit-chain.sh) (which proves
> the chain in depth). m104-audit-chain is the cryptographic spine; m141-compliance-posture
> proves the **whole posture** — docs + standards mapping + the spine + the GDPR rights surface.

---

## See also

- **Framework cross-walks (the per-standard projections of this matrix):**
  [`compliance/soc2-tsc-matrix.md`](./soc2-tsc-matrix.md) (SOC 2 Trust Services Criteria
  CC1–CC9 + A/C/PI/P), [`compliance/gdpr-article-matrix.md`](./gdpr-article-matrix.md)
  (GDPR Art. 5–50, controller/processor split), and
  [`compliance/iso27001-soa.md`](./iso27001-soa.md) (ISO/IEC 27001:2022 Annex A Statement
  of Applicability — all 93 controls). Index: [`compliance/README.md`](./README.md);
  gate-kept by `m143`.
- [`security-audit-asvs.md`](../security/security-audit-asvs.md) — full ASVS L1/L2 map + open residuals
- [`trust-center.md`](../security/trust-center.md) — the public, human-readable posture page
- [`security-audit.md`](../security/security-audit.md) — the underlying HIGH/MED/LOW findings
- [`config/trust/posture.json`](../../mini-baas-infra/config/trust/posture.json) — canonical machine-readable posture (`GET /v1/trust`)
- [`competitive-matrix.md`](../competitive/competitive-matrix.md) — rows 72–76 (the compliance/security cluster)
