# Grobase — OWASP ASVS & SOC2-lite Control Map

> **Companion to [security-audit.md](./security-audit.md).** That doc is the *findings*
> (what was broken, fixed, verified, and what remains). This doc is the *control
> map*: it maps Grobase's **shipped** controls to **OWASP ASVS** (Application
> Security Verification Standard) L1/L2 categories and a **SOC2-lite** control list,
> with concrete code/config evidence, and it lists the **open residuals as gaps**.
>
> This satisfies the Bar 3 line "OWASP ASVS / SOC2-lite control map" in
> [marketability-readiness.md](../go-to-market/marketability-readiness.md) and the A6 exit-gate
> requirement in [roadmap-to-market.md](../go-to-market/roadmap-to-market.md) §4 (m60).
>
> **Honesty bar:** this is an *audit-ready posture* map, **not** a compliance
> attestation. Formal SOC2 Type 2 / HIPAA are **deferred** (external auditor + window).
> ISO 27001:2022 SoA drafted (audit-ready); certification pending ISMS stand-up +
> external body — see [compliance/iso27001-soa.md](../compliance/iso27001-soa.md).
> Where a control is partial or absent it is marked `[~]` / `[x]` and listed in
> §3 (Open residuals — gaps) — nothing here is overclaimed.

**Status glyphs** (consistent with the other wiki docs): `[v]` shipped & gated ·
`[~]` partial / built-but-off / mode-dependent · `[x]` missing · `[+]` differentiator.

---

## 1. OWASP ASVS control map (L1/L2)

ASVS chapter numbers are indicative (ASVS 4.0.x). Evidence cites the audit doc and
the code path that implements the control.

### V1/V14 — Architecture, configuration & supply chain

| Control | Status | Evidence |
|---|---|---|
| Sole public listener is a hardened gateway (defence in depth) | `[+]` | In-stack OWASP **WAF** = ModSecurity v3 + CRS as the only public ingress (`docker/services/waf`); data plane is behind Kong, server-to-server only. |
| Restrictive CORS by default (no permissive cross-origin) | `[v]` | Data-plane CORS denies browser cross-origin by default; allow-list via `DATA_PLANE_CORS_ALLOW_ORIGINS` (audit O3, FIXED). |
| Dependency / supply-chain locking | `[v]` | Frozen lockfiles everywhere; npm `--ignore-scripts` (`src/.npmrc`), pnpm `minimum-release-age=1440` quarantine (`.npmrc`) + `onlyBuiltDependencies` allowlist; digest pinning (`pin-digests.sh`). |
| SCA in CI (known-CVE gate) | `[v]` | `cargo-audit` (Rust) + `govulncheck` (Go) + `npm/pnpm audit` + Trivy fs/image, all **blocking** in `.github/workflows/mini-baas-security.yml` (`sca-cargo-audit`, `sca-govulncheck`, `sca-npm-audit`, `container-trivy`). |
| SAST in CI | `[v]` | Semgrep (`p/owasp-top-ten` + lang rules), SARIF to the Security tab (`sast-semgrep`). |
| Secret-scan in CI (blocking) | `[v]` | TruffleHog (`--only-verified --fail`) + gitleaks (working-tree regex/entropy, `--exit-code 1`); `.env`/`.env.local` gitignored and never tracked, `ANON_KEY` runtime-derived from `JWT_SECRET` (no committed secret). |
| Vault enforced for all secrets | `[~]` | Vault present (`docker/services/vault`); but plaintext DSNs are possible outside `SECURITY_MODE=max` (audit O5). → **gap G-Vault**. |
| Plane network isolation / NetworkPolicy | `[x]` | Flat single bridge network (`docker-compose.yml`); no per-plane segmentation. → **gap G-Net**. |

### V2 — Authentication

| Control | Status | Evidence |
|---|---|---|
| API-key authentication, single authority | `[v]` | Argon2id key verify is the sole authority in Go; the Rust bypass scope-gates every op and owner-stamps writes (audit "Verified safe"). 160-bit keys, sha256 fast-verify with lazy upgrade (scale-program FIX 1). |
| JWT verification pinned to one algorithm (no alg-confusion) | `[v]` | `JWTVerifier` pins a single alg; RS→HS / `none` confusion class closed in BOTH modes; RS256/JWKS verify-side shipped + unit-proven (`jwks.go`, `jwks_test.go`) (audit O2). |
| RS256 *issuer* live (GoTrue signs RS256 + JWKS) | `[~]` | Verify side ready; **issuer flip is cross-repo and not done** — GoTrue still signs HS256 (audit O2). → **gap G-RS256** (deferred, coordinated). |
| Per-deployment / non-shared keys | `[~]` | `generate-env.sh` emits a distinct `ADAPTER_REGISTRY_SERVICE_TOKEN` (JWT/service-token coupling FIXED, audit O2); per-deployment key strategy + rotation primitive still open. → **gap G-Rotate**. |

### V3 — Session management

| Control | Status | Evidence |
|---|---|---|
| Stateless, signed, time-bound session tokens | `[v]` | JWT sessions verified by the control plane; algorithm-pinned (V2 above). |
| Internal service auth bound per-request (no static bearer on the wire) | `[+]` | `X-Service-Auth: v1.<ts>.<hmac>` binds ts/method/path/body, ±120 s skew, token never transits the wire; default flipped `static`→`hmac` stack-wide; byte-identical across Go/Rust/TS/bash with golden vectors (audit O1, FIXED). |

### V4 — Access control

| Control | Status | Evidence |
|---|---|---|
| Owner-scoped predicates on every engine | `[v]` | RLS-equivalent owner predicates + GUC; writes owner-stamped on all 7 adapters (`data-plane-core/src/isolation.rs`; audit "Verified safe"). |
| ABAC + field masks | `[v]` | Per-principal ABAC + field masking (`data-plane-server/src/abac.rs`); capability mask narrows data ops per tier. |
| Postgres RLS as belt-and-suspenders | `[~]` | Owner predicates ship; native PG RLS policies are recommended defence-in-depth (audit solution #7). → **gap G-RLS-DiD** (hardening, not a hole). |
| Internal identity headers integrity-verified | `[~]` | adapter-registry trusted `X-Baas-*` with no HMAC (audit O6). **Opt-in HMAC now shipped** behind `ADAPTER_REGISTRY_IDENTITY_HMAC` (`internal/adapterregistry/identity.go`); default OFF preserves the private-net trust model. → see §3 G-Hdr. |
| Dense multi-tenant isolation under shared pools | `[+]` | Isolation is per-request, not pool-state — proven byte-identical at 10K tenants→1 pool (gate m46; `pools_shared`). |

### V5 — Validation, sanitization & injection

| Control | Status | Evidence |
|---|---|---|
| No SQL/NoSQL string interpolation of user values | `[v]` | Identifiers via `quote_ident`/`quote_mysql_ident` (allowlist `[A-Za-z0-9_]` then quoted); all values bound (`$n`/`?`/`@Pn`) (audit "Verified safe"). |
| Schema/search-path injection closed | `[v]` | `SET LOCAL search_path` schema from `mount.tenant_schema()` sanitized to `tenant_[a-z0-9_]` (audit "Verified safe"). |
| Mongo NoSQL injection / cross-owner `$or` leak | `[v]` | Fixed and verified (audit "Repaired"/matrix Bar 3); mongo owner-stamp sourced from identity, not pool field (scale-program FIX 3). |
| Request body size bound | `[v]` | axum default 2 MB JSON limit (audit "Verified safe"). |
| Resource/DoS bounds on query surface | `[v]` | Rate limiter wired on `/query` **and** `/schema,/ddl,/graph` (audit #5); graph BFS `MAX_GRAPH_NODES=5000` (audit #6). |

### V6 — Stored cryptography

| Control | Status | Evidence |
|---|---|---|
| Credentials encrypted at rest | `[v]` | Connection strings sealed with AES-256-GCM, scrypt-derived per-record key (`internal/adapterregistry/crypto.go`), GCM auth-tag verified on decrypt. |
| Password/key hashing | `[v]` | Argon2id for password-class secrets; 160-bit API keys via sha256 with dual-scheme lazy upgrade (no key breakage) (scale-program FIX 1). |
| Constant-time secret comparison | `[v]` | `shared.SecureCompare` / `crypto/subtle` at all service-token sites (audit #3, timing fix). |

### V7 — Error handling & logging / audit

| Control | Status | Evidence |
|---|---|---|
| Structured audit of mutations + denials | `[v]` | Writes and denials emit an `audit` tracing target. |
| Sensitive-read auditing | `[x]` | Reads are not audited (audit O8). → **gap G-ReadAudit**. |
| No sensitive data in error responses | `[v]` | Errors return typed codes (`shared.WriteError`); integrity violations map to 409, not raw driver text (`project-baas-constraint-409`). |
| Audit → SIEM + anomaly detection | `[~]` | Observability fully wired (Prometheus/Grafana/Loki/Tempo, gate m19); SIEM shipping + cross-tenant-404 anomaly alerts are recommended (audit solution #6). |

### V8/V12 — Data protection & files

| Control | Status | Evidence |
|---|---|---|
| Tenant data isolation (storage) | `[v]` | storage-router owner-prefixed keys; Kong `pre-function` clears client `X-User-*` then sets them from the verified JWT (anon-path impersonation closed, roadmap A1). |
| Fine-grained file ABAC (`bucket:read/write`) | `[~]` | Owner-prefix is the only isolation today; bucket-level ABAC not wired (roadmap A1 open item). |
| Backups exist + restore-tested | `[v]` | Daily `pg_dump -Fc`, 14-day retention → MinIO, optional WAL/PITR, restore-drill (gate m47). Per-tenant + encrypted-at-rest backups are follow-ups (audit solution #11; roadmap B6). |

### V9/V13 — Communications & API security (TLS)

| Control | Status | Evidence |
|---|---|---|
| TLS verify-full per engine (no cert bypass) at max | `[v]` | MSSQL `apply_mssql_tls` verifies by default, refuses insecure under max, CA-pin via `DATA_PLANE_TLS_CA_FILE` (audit #1, MITM fix); mongo/redis insecure DSN params rejected under max (audit #4). |
| SSRF defence on outbound HTTP engine | `[v]` | `guard_and_resolve` rejects loopback/private/link-local/CGNAT/ULA + cloud-metadata hosts and **pins** to validated public IPs (defeats DNS rebinding) (audit #2). |
| Postgres TLS verify outside max | `[~]` | `sslmode=require` is accept-any outside max; recommend `SECURITY_MODE=max` for multi-tenant (audit O4). |

---

## 2. SOC2-lite control list (Trust Services Criteria, informal)

A lightweight mapping to the SOC2 TSC families — **posture only**, not an attestation.

| TSC | Control | Status | Evidence |
|---|---|---|---|
| **CC6.1** Logical access | API-key + JWT auth, single Argon2id authority, scope-gated ops | `[v]` | audit "Verified safe"; `keys.go` |
| **CC6.1** | Per-request HMAC for service-to-service (no static bearer on the wire) | `[v]` | audit O1 (`X-Service-Auth`) |
| **CC6.1** | Internal identity-header integrity (opt-in HMAC) | `[~]` | `adapterregistry/identity.go` (flag-gated; default OFF) — §3 G-Hdr |
| **CC6.1** | Encryption of stored credentials | `[v]` | AES-256-GCM + scrypt (`crypto.go`) |
| **CC6.6** Boundary protection | In-stack WAF as sole public listener; restrictive CORS | `[v]`/`[+]` | `services/waf`; audit O3 |
| **CC6.6** | Network segmentation between planes | `[x]` | flat bridge — §3 G-Net |
| **CC6.7** Data in transit | TLS verify-full per engine (max); SSRF egress guard | `[v]` | audit #1/#2/#4 |
| **CC6.8** Malicious software / supply chain | Lockfiles, npm quarantine, `--ignore-scripts`, digest pins, SCA gate | `[v]` | `.npmrc`, CI SCA jobs |
| **CC7.1** Vulnerability management | Blocking SAST/SCA/secret/container scans in CI; tracked accepted residuals | `[v]` | `mini-baas-security.yml`; `.trivyignore`; `audit-deps.sh` |
| **CC7.2** Monitoring | Prometheus/Grafana/Loki/Tempo; mutation + denial audit | `[v]`/`[~]` | gate m19; reads unaudited — §3 G-ReadAudit |
| **CC7.2** | Anomaly detection / SIEM shipping | `[~]` | audit solution #6 (recommended) |
| **CC8.1** Change management | PR + CI gates required to merge; shadow→parity→cutover discipline | `[v]` | repo workflow; CLAUDE.md |
| **A1.2** Availability / backups | Daily encrypted backups + restore-drill (whole-cluster) | `[v]` | gate m47; per-tenant DR is roadmap B6 |
| **C1 / P** Confidentiality / privacy | Tenant isolation (RLS+ABAC+field masks), GDPR delete path | `[v]` | `isolation.rs`, `abac.rs`, `gdprsvc` |
| **CC6.1** Secret rotation | `vault-rotate-approles` exists; atomic key-rotation primitive missing | `[~]` | audit solution #9 — §3 G-Rotate |
| **CC6.x** Per-tenant resource QoS | Rate (rps) capped; no per-tenant CPU/RAM/row/timeout QoS | `[x]` | audit solution #12 — §3 G-QoS |

---

## 3. Open residuals — gaps (honest)

These are the controls that are **not** fully shipped. Each is the difference between
"strong" and "audit-ready"; all are tracked against A6 (m60) or deferred by decision.
Sourced from [security-audit.md](./security-audit.md) §"Open" + the roadmap A6 list.

| ID | Gap | Sev | Status / disposition |
|---|---|---|---|
| **G-RS256** | JWT **RS256 issuer not flipped** — GoTrue still signs HS256 though the verify side (RS256/JWKS) is ready. | MED | **Deferred (cross-repo, coordinated).** Touches the live login flow + Kong `jwt` plugin; ships as its own change (audit O2). |
| **G-Vault** | **Vault not enforced** — plaintext / inline-encrypted DSNs possible outside `SECURITY_MODE=max`. | MED | **Deferred (coordinated).** A6: under max require `credential_ref{provider:vault}`; forbid plaintext mounts in prod (audit O5). |
| **G-Net** | **Flat network / no NetworkPolicy** — single bridge, no per-plane segmentation. | MED | A6 / C2: per-plane network isolation + K8s NetworkPolicy (audit; roadmap A6). |
| **G-Hdr** | **adapter-registry header trust** — `X-Baas-*` identity headers were trusted with no HMAC on a flat bridge. | LOW | **Partially closed this track:** opt-in HMAC verification shipped behind `ADAPTER_REGISTRY_IDENTITY_HMAC` (`internal/adapterregistry/identity.go` + `identity_test.go`, `go test ./...` green). Default OFF (no behavior change) until the issuing gateway is taught to sign the identity tuple — *enabling it stack-wide is the remaining cross-repo step* (the gateway must compute `X-Baas-Identity-Auth` = `ComputeServiceSignature(serviceToken, "IDENTITY", "<user>\n<tenant>", nil, ts)`). mTLS service mesh (audit solution #1) is the longer-term answer. |
| **G-ReadAudit** | **Reads not audited** — only mutations + denials emit audit events. | LOW | A6: optional max-mode "sensitive-read" audit on flagged resources (audit O8). |
| **G-QoS** | **No per-tenant resource QoS** — rate (rps) is capped, but rows-per-query / query-timeout / pool-size / storage-per-tenant are not. | LOW | A6 / Track C: per-tenant quotas beyond rate (audit solution #12). |
| **G-Rotate** | **No atomic key-rotation primitive** — `vault-rotate-approles` exists but rotation-without-restart for `JWT_SECRET`/service token is not wired. | LOW | A6: atomic rotation (needs O1/O2 done first) (audit solution #9). |
| **G-RLS-DiD** | Native Postgres RLS policies as belt-and-suspenders on top of owner predicates. | LOW | Hardening, not a hole — recommended (audit solution #7). |

**Explicitly out of scope (decision D4):** formal **SOC2 Type 2 / HIPAA**
attestations. For **ISO 27001:2022**, the Annex A Statement of Applicability is now
drafted (audit-ready); certification is pending ISMS stand-up + an external body —
see [compliance/iso27001-soa.md](../compliance/iso27001-soa.md). This document is the
posture that makes those a checklist; the paid, calendar-bound certification process
(auditor/body engagement) is the deferred part.

---

## 4. CI security gates (the moving floor)

The gates that keep this map honest over time, all in
`.github/workflows/mini-baas-security.yml` and wired into the blocking
`security-gate` aggregate:

| Job | Tool | Scope |
|---|---|---|
| `sast-semgrep` | Semgrep | OWASP-top-ten + TS/JS/Docker rules → SARIF |
| `sca-npm-audit` | npm / pnpm audit | all TS packages |
| `sca-cargo-audit` | cargo-audit | both Rust workspaces (data-plane-router, realtime-agnostic); 3 tiberius-only rustls-webpki advisories `--ignore`d (no upstream fix — see audit §supply-chain) |
| `sca-govulncheck` | govulncheck | Go control plane (reachability-based) |
| `container-trivy` | Trivy | fs + representative image; accepted CVEs in `.trivyignore` |
| `secret-trufflehog` | TruffleHog | verified secrets, fail |
| `secret-gitleaks` | gitleaks | working-tree regex/entropy, blocking |
| `dast-zap` | ZAP baseline | main-only, against the WAF |

**Still TODO for the full A6 m60 gate:** fuzz (cargo-fuzz on the filter/DDL parsers,
audit solution #10) — DAST is shipped (`dast-zap`).

---

## See also

- [security-audit.md](./security-audit.md) — the underlying findings (HIGH/MED/LOW), the
  repaired-this-session table, verified-safe list, open residuals (O1–O8), and the
  defence-in-depth backlog this map draws from.
- [marketability-readiness.md](../go-to-market/marketability-readiness.md) — Bar 3 acceptance.
- [roadmap-to-market.md](../go-to-market/roadmap-to-market.md) — A6 (OSS launch gate) and gate m60.
