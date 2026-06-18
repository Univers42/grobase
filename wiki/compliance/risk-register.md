# Risk Register (ISO 27001 clause 6 · SOC 2 CC3)

> **The information-security risk register.** It satisfies ISO/IEC 27001 clause 6 (planning — risk
> assessment & treatment) and SOC 2 **CC3** (risk assessment). It is **seeded from real findings, not
> fabricated**: every entry traces to a residual in [`../security-audit.md`](../security/security-audit.md)
> (the O1–O8 open list) or a named gap in [`../security-audit-asvs.md`](../security/security-audit-asvs.md)
> §3. Remediation runbooks live in [`../security-residuals-runbook.md`](../security/security-residuals-runbook.md).
> Likelihood × Impact and residual ratings are qualitative (Low/Med/High); they are engineering
> judgement on the stated facts, not measured probabilities.

**Treatment legend:** *Mitigate* (control reduces risk) · *Mitigated/Closed* (control shipped) ·
*Accept* (residual accepted, tracked) · *Transfer* (shared responsibility / insurance) ·
*Avoid* (design removes the risk). Owner = the role accountable for the next action.

If a row's status conflicts with `config/trust/posture.json`, the JSON is canonical.

---

## 1. Active risks (open or accepted)

| Risk ID | Asset / Threat / Vulnerability | Likelihood × Impact | Treatment | Control ref | Owner | Residual | Review |
|---|---|---|---|---|---|---|---|
| R-O4 | Tenant data in transit / MITM / Postgres `sslmode=require` is accept-any **outside** `SECURITY_MODE=max` | Med × High | Mitigate — run `max` for multi-tenant (upgrades require→verify); consider verify-default for non-loopback DSNs | [`../security-audit-asvs.md`](../security/security-audit-asvs.md) (audit O4) | Data-plane | Med (Low at `max`) | 2026-Q4 |
| R-O5 | Stored secrets / credential leak / Vault not *enforced* — plaintext DSNs possible outside `max` | Med × High | Mitigate — under `max` require `credential_ref{provider:vault}`, forbid plaintext mounts in prod; gate proves enforcement | gate `m121`, [`../security-audit.md`](../security/security-audit.md) (audit O5) | Control-plane | Med | 2026-Q4 |
| R-G-RS256 | Authentication / alg-confusion / RS256 **issuer** not flipped — GoTrue still signs HS256 (verify side ready) | Low × High | Mitigate — coordinated cross-repo cutover (issuer + Kong + verifier); verify side shipped + unit-proven | gate `m81`, [`../security-residuals-runbook.md`](../security/security-residuals-runbook.md) | Auth / cross-repo | Med (deferred) | 2026-Q3 |
| R-G-Net | Network / lateral movement / flat bridge — per-plane segmentation is an opt-in overlay, not default | Med × Med | Mitigate — default-deny per-plane netseg (`docker-compose.netseg.yml`) + IP allowlist; staged rollout | gate `m106`, [`../security-audit-asvs.md`](../security/security-audit-asvs.md) (G-Net) | Platform | Med | 2026-Q4 |
| R-G-Hdr | Internal identity headers / spoofing / `X-Baas-*` trusted with no HMAC on the private net | Low × Med | Mitigate — opt-in HMAC verification shipped (`ADAPTER_REGISTRY_IDENTITY_HMAC`, default OFF); enable once the gateway signs the identity tuple | [`../security-audit.md`](../security/security-audit.md) (audit O6 / G-Hdr) | Control-plane | Low | 2026-Q4 |
| R-G-Rotate | Key management / stale credentials / no atomic (no-restart) key-rotation primitive for `JWT_SECRET`/service-token | Low × Med | Mitigate — `vault-rotate-approles` exists; wire rotation-without-restart (needs O1/O2 done) | [`../security-residuals-runbook.md`](../security/security-residuals-runbook.md) (G-Rotate) | Platform | Low | 2027-Q1 |
| R-G-RLS-DiD | Tenant isolation / missing-predicate row leak / native PG RLS not enabled as belt-and-suspenders | Low × Med | Mitigate (hardening) — add native PG RLS on tenant tables atop owner predicates | gate `m46` (owner-scope today) | Data-plane | Low | 2027-Q1 |
| R-ATTEST | Compliance / buyer cannot procure / no external SOC 2 / ISO / HIPAA attestation | Med × Med | Accept (planned) — controls + evidence are audit-ready; engage auditor/body when the business milestone lands | [`auditor-handoff.md`](./auditor-handoff.md), [`soc2-tsc-matrix.md`](./soc2-tsc-matrix.md), [`iso27001-soa.md`](./iso27001-soa.md) | Business | Med | 2026-Q4 |
| R-UPTIME | Availability / unverifiable SLA / no live uptime probe → per-tier targets are TARGETS, not measured | Med × Med | Mitigate — stand up the C7 uptime probe + status page; do not advertise an SLA until samples exist | [`../status-sla.md`](../operations/status-sla.md) (`sla-uptime` planned) | Operations | Med | 2026-Q4 |
| R-AT-REST | Confidentiality / disk theft / per-tenant encryption-at-rest is operator/host responsibility today | Low × High | Transfer + Mitigate — host/volume encryption (operator); CMEK envelope already crypto-shreds external-connection secrets | gate `m123`, [`../security-audit-asvs.md`](../security/security-audit-asvs.md) | Operator / Platform | Med | 2026-Q4 |
| R-SIEM | Detection / late breach discovery / no SIEM shipping + cross-tenant-404 anomaly alerting yet | Low × Med | Mitigate — ship `audit` target to a SIEM; alert on cross-tenant-404 / 401-403 bursts (observability already wired) | [`../security-audit.md`](../security/security-audit.md) (solution #6), gate `m104` | Operations | Low | 2027-Q1 |
| R-DISCLOSE | Vulnerability disclosure / no public intake / status page + `security.txt` not yet stood up | Low × Low | Mitigate — publish `security.txt` + status page (policy + contact already defined) | [`../status-sla.md`](../operations/status-sla.md) | Operations | Low | 2026-Q4 |

---

## 2. Closed risks (control shipped — kept for the audit trail)

| Risk ID | Original finding | Treatment | Control ref | Status |
|---|---|---|---|---|
| R-O1 | Internal service token was a static shared secret on the wire | Mitigated — per-request HMAC (`X-Service-Auth`), default ON stack-wide; plain tokens rejected | [`../security-audit.md`](../security/security-audit.md) (audit O1 FIXED) | Closed |
| R-O2c | `JWT_SECRET` reused as the service token (coupling) | Mitigated — distinct `ADAPTER_REGISTRY_SERVICE_TOKEN`; RS256/JWKS verify side shipped | [`../security-audit.md`](../security/security-audit.md) (audit O2) | Closed (issuer flip → R-G-RS256) |
| R-O3 | `CorsLayer::permissive()` on the data plane | Mitigated — restrictive CORS by default; allow-list via `DATA_PLANE_CORS_ALLOW_ORIGINS` | [`../security-audit.md`](../security/security-audit.md) (audit O3 FIXED) | Closed |
| R-O8 | Sensitive reads not audited (only mutations + denials) | Mitigated — opt-in read audit shipped (`DATA_PLANE_AUDIT_READS`) | gate `m72` (G-ReadAudit) | Closed (flag-gated) |
| R-O-QoS | No per-tenant resource QoS beyond rps (rows-per-query unbounded) | Mitigated — rows-per-query cap shipped (`max_rows`); abuse-guard + spend caps bound load/cost | gate `m73`, gate `m90`, gate `m89` (G-QoS slice A) | Closed (slice A) |
| R-MITM-MSSQL | MSSQL `trust_cert()` accepted any cert even at `max` (MITM) | Mitigated — `apply_mssql_tls` verifies by default; CA-pin via `DATA_PLANE_TLS_CA_FILE` | [`../security-audit.md`](../security/security-audit.md) (audit #1) | Closed |
| R-SSRF | HTTP engine SSRF → cloud metadata / RFC-1918 | Mitigated — `guard_and_resolve` rejects internal addresses + pins to validated public IPs | [`../security-audit.md`](../security/security-audit.md) (audit #2) | Closed |
| R-TIMING | Service token compared with `==`/`!=` (timing side-channel) | Mitigated — `shared.SecureCompare` (`crypto/subtle`) at all sites | [`../security-audit.md`](../security/security-audit.md) (audit #3) | Closed |
| R-DOS-DDL | `/schema,/ddl,/graph` skipped the rate limiter; graph BFS unbounded | Mitigated — rate limiter on all three; `MAX_GRAPH_NODES=5000` | [`../security-audit.md`](../security/security-audit.md) (audit #5/#6) | Closed |

---

## 3. How this register is operated

- **Identification** (CC3.1/CC3.2): new risks enter from the security audit, CI gate failures, the
  residuals runbook, and incident post-mortems.
- **Analysis & evaluation** (CC3.2): each risk gets Likelihood × Impact and a residual rating after
  treatment; ratings are qualitative engineering judgement, restated honestly.
- **Treatment** (clause 6.1.3): linked to a control reference (a backticked gate or a doc); the
  Statement of Applicability ([`iso27001-soa.md`](./iso27001-soa.md)) records which Annex A controls
  implement each treatment.
- **Monitoring** (CC4.1/clause 9): the `m108` continuous-evidence collector seals control results;
  the `m143` gate keeps the matrices honest; review dates above drive the cadence.
- **Change-driven review** (CC3.4): the change-management gate harness flags posture drift on every
  change.

> **The honest summary:** the highest-residual items are **cross-repo/live-flip auth work** (RS256),
> **enforcement defaults** (Vault, netseg) deferred to supervised waves, and the **external
> attestation + uptime probe** that need a business milestone — not undiscovered holes. The exploited
> classes (MITM, SSRF, timing, DoS) are closed and gate-pinned.
