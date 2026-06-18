# SOC 2 — Trust Services Criteria Cross-Walk

> **Audit-ready cross-walk, not a SOC 2 report.** This maps Grobase's shipped controls to the
> AICPA **Trust Services Criteria (TSC, 2017 rev. 2022)**. It is the SOC 2 projection of
> [`../compliance-posture.md`](./compliance-posture.md) and [`config/trust/posture.json`]; it does
> **not** assert an opinion — only an external CPA firm can, over an observation window. Where a row
> is *pending-auditor* or *pending-infra*, that is the honest state (kernel rule #4).

**Status legend (this doc):**

- **proven** — control exists and a re-runnable in-repo gate/CI job demonstrates it.
- **partial** — control is real but has a named gap (carried from `posture.json` / `security-audit.md`).
- **pending-infra** — control depends on infrastructure not yet stood up (e.g. uptime probe, status page).
- **pending-auditor** — control is operated, but the *assurance* requires the external auditor (e.g. management review evidence over the window).

If this doc and `posture.json` disagree on a control's status, **the JSON is canonical.**

---

## 1. Security — Common Criteria (CC1–CC9)

Every CC family maps to Grobase control(s), an in-repo artifact, and a status. The criteria text is
paraphrased; the official AICPA criteria govern.

### CC1 — Control Environment

| Criterion | Grobase control(s) | Evidence | Status |
|---|---|---|---|
| CC1.1 Integrity & ethical values | Org rules + binding kernel (`.claude/CLAUDE.md`), contribution discipline | [`security-policies/infosec-policy.md`](./security-policies/infosec-policy.md) | pending-auditor |
| CC1.2 Board / governance oversight | Management review of ISMS (clause 9.3) — to be operated | [`security-policies/infosec-policy.md`](./security-policies/infosec-policy.md) | pending-auditor |
| CC1.3 Structures, authority & responsibility | Role/owner assignment in policies + risk register owners | [`risk-register.md`](./risk-register.md), [`security-policies/00-index.md`](./security-policies/00-index.md) | pending-auditor |
| CC1.4 Commitment to competence | Engineering review gates (PR + CI) as competence control | [`security-policies/change-management-policy.md`](./security-policies/change-management-policy.md) | partial |
| CC1.5 Accountability | Tamper-evident audit binds actions to principals (`m104`) | gate `m104` | proven |

### CC2 — Communication & Information

| Criterion | Grobase control(s) | Evidence | Status |
|---|---|---|---|
| CC2.1 Quality information for internal control | SOC2-lite evidence collector seals CI/access/change snapshots (`m108`) | gate `m108` (migration `051_compliance_evidence.sql`) | partial |
| CC2.2 Internal communication of objectives & responsibilities | Policy set + runbooks (`../operations-runbook.md`) | [`security-policies/00-index.md`](./security-policies/00-index.md) | pending-auditor |
| CC2.3 External communication | Public posture page + vulnerability disclosure contact | [`../trust-center.md`](../security/trust-center.md), [`../status-sla.md`](../operations/status-sla.md) | partial |

### CC3 — Risk Assessment

| Criterion | Grobase control(s) | Evidence | Status |
|---|---|---|---|
| CC3.1 Objectives specified to enable risk ID | Risk register scope + asset/threat model | [`risk-register.md`](./risk-register.md) | partial |
| CC3.2 Risk identification & analysis | Risk register (likelihood × impact) seeded from real residuals O1–O8 | [`risk-register.md`](./risk-register.md), [`../security-audit.md`](../security/security-audit.md) | partial |
| CC3.3 Fraud risk considered | Abuse-guard + spend caps bound cost/abuse vectors (`m90`, `m89`) | gate `m90`, gate `m89` | proven |
| CC3.4 Significant change risk | shadow→parity→cutover discipline; change-mgmt gate harness | [`security-policies/change-management-policy.md`](./security-policies/change-management-policy.md) | proven |

### CC4 — Monitoring Activities

| Criterion | Grobase control(s) | Evidence | Status |
|---|---|---|---|
| CC4.1 Ongoing / separate evaluations | Continuous evidence collector seals control results (`m108`); CI gate battery | gate `m108`, gate `m143` | partial |
| CC4.2 Deficiencies communicated & remediated | Residuals runbook + tracked accepted residuals | [`../security-residuals-runbook.md`](../security/security-residuals-runbook.md) | partial |

### CC5 — Control Activities

| Criterion | Grobase control(s) | Evidence | Status |
|---|---|---|---|
| CC5.1 Control activities mitigating risk | Owner-scoping + ABAC PDP per request on every engine | gate `m46`, gate `m136` | proven |
| CC5.2 Technology general controls | TLS/SSRF/credential-encryption controls; CMEK | gate `m123`, [`../security-audit-asvs.md`](../security/security-audit-asvs.md) | partial |
| CC5.3 Policies & procedures deployed | Policy set points to enforced controls | [`security-policies/00-index.md`](./security-policies/00-index.md) | partial |

### CC6 — Logical & Physical Access Controls

| Criterion | Grobase control(s) | Evidence | Status |
|---|---|---|---|
| CC6.1 Logical access provisioning & auth | API-key (single Argon2id authority) + JWT alg-pinned; org RBAC; SSO/SCIM; passkeys | gate `m103`, gate `m107`, gate `m110`, gate `m111` | proven |
| CC6.2 Registration / de-registration of users | SCIM 2.0 user lifecycle (provision/deprovision) | gate `m111` (migration `054_scim_tokens.sql`) | proven |
| CC6.3 Role-based access & least privilege | Organizations / roles + fine-grained ABAC conditions & per-instance grants | gate `m103`, gate `m136`, gate `m137` | proven |
| CC6.4 Physical access restriction | Inherited from cloud/host provider (shared responsibility) | [`security-policies/access-control-policy.md`](./security-policies/access-control-policy.md) | pending-auditor |
| CC6.5 Decommissioning / data destruction | GDPR hard-erase (scoped delete + erasure receipt) | gate `m105` (migration `048_tenant_erasure.sql`) | proven |
| CC6.6 Boundary / network protection | Per-tenant IP allowlist; per-plane network segmentation overlay | gate `m106` (migration `049_tenant_ip_allowlist.sql`) | proven |
| CC6.7 Transmission & disposal of confidential info | TLS verify-full at `max`; SSRF egress guard; credentials sealed AES-256-GCM; CMEK envelope | gate `m123`, [`../security-audit-asvs.md`](../security/security-audit-asvs.md) | partial |
| CC6.8 Malicious / unauthorized software | Frozen lockfiles, `--ignore-scripts`, SCA/SAST/secret scans in CI | [`../security-audit.md`](../security/security-audit.md) (supply-chain) | proven |

### CC7 — System Operations

| Criterion | Grobase control(s) | Evidence | Status |
|---|---|---|---|
| CC7.1 Vulnerability detection | Blocking SAST/SCA/secret/container scans in CI; tracked residuals | [`../security-audit.md`](../security/security-audit.md), [`../security-residuals-runbook.md`](../security/security-residuals-runbook.md) | proven |
| CC7.2 Monitoring & anomaly detection | Observability stack (Prometheus/Grafana/Loki/Tempo); tamper-evident audit; read-audit option | gate `m104`, gate `m72` | partial |
| CC7.3 Security incident evaluation | Incident-response process + forensic audit chain | [`security-policies/incident-response-policy.md`](./security-policies/incident-response-policy.md), gate `m104` | partial |
| CC7.4 Incident response & recovery | Runbook + backup/restore + PITR | [`../operations-runbook.md`](../operations/operations-runbook.md), gate `m87`, gate `m99` | partial |
| CC7.5 Recovery from incidents | Per-tenant backup/restore + point-in-time restore | gate `m87`, gate `m99` | proven |

### CC8 — Change Management

| Criterion | Grobase control(s) | Evidence | Status |
|---|---|---|---|
| CC8.1 Change authorization, design, testing & deployment | PR + CI gate battery required to merge; numbered milestone gates; shadow→parity→cutover (milestone 18 live-traffic discipline) | gate `m143`, [`security-policies/change-management-policy.md`](./security-policies/change-management-policy.md) | proven |

### CC9 — Risk Mitigation

| Criterion | Grobase control(s) | Evidence | Status |
|---|---|---|---|
| CC9.1 Business-disruption risk mitigation | BCP/DR: per-tenant backup, PITR, restore drill | gate `m87`, gate `m99`, gate `m47` | partial |
| CC9.2 Vendor & business-partner risk | Subprocessor list + supply-chain locks; vendor policy | [`../legal/subprocessors.md`](../legal/subprocessors.md), [`security-policies/vendor-supplier-policy.md`](./security-policies/vendor-supplier-policy.md) | partial |

---

## 2. Availability (A1) — decision: pending-infra

Grobase has the **restoration** half proven and the **measurement** half pending:

- **Backup & recovery (proven).** Per-tenant logical backup/restore (`m87`), point-in-time restore
  (`m99`), and a whole-cluster restore drill (`m47`) demonstrate recoverability. These satisfy the
  *restoration* expectations of A1.2/A1.3.
- **Capacity (proven by benchmark).** Capacity/headroom is measured, not claimed —
  `artifacts/bench/` + `make bench-capacity` (A1.1).
- **Uptime monitoring (pending-infra).** A1.1's availability *commitment* needs durable uptime
  samples. Per-tier targets are **TARGETS pending the C7 uptime probe** (`sla-uptime` = **planned**
  in `posture.json`); no uptime %, RTO, or RPO is asserted here. Decision: **pending-infra** until
  the probe writes samples and the status page is stood up.

| A1 criterion | Grobase position | Evidence | Status |
|---|---|---|---|
| A1.1 Capacity & demand management | Measured capacity + headroom | `make bench-capacity`, `artifacts/bench/` | partial |
| A1.2 Environmental protections, backup, recovery | Per-tenant backup + PITR + restore drill | gate `m87`, gate `m99`, gate `m47` | proven |
| A1.3 Recovery plan tested | Restore drills are re-runnable gates | gate `m47`, gate `m99` | partial |

---

## 3. Confidentiality (C1)

| C1 criterion | Grobase control(s) | Evidence | Status |
|---|---|---|---|
| C1.1 Confidential info identified & protected | Per-request isolation/owner-scope; CMEK envelope encryption | gate `m46`, gate `m123` (migration `061_tenant_database_cmek.sql`) | proven |
| C1.2 Confidential info disposed of | GDPR hard-erase (crypto-shred via CMEK KEK revocation; scoped delete) | gate `m105`, gate `m123` | proven |

Confidentiality is one of Grobase's strongest axes: isolation is enforced per **request**, not by
pool state (`m46`), so 10K tenants collapse onto one pool with byte-identical results; revoking a
customer's CMEK KEK crypto-shreds that tenant's external connection data (`m123`).

---

## 4. Processing Integrity (PI1) — partial

| PI1 criterion | Grobase position | Evidence | Status |
|---|---|---|---|
| PI1.1 Quality of processing data | Typed errors; integrity violations → 409 (not raw driver text) | [`../security-audit-asvs.md`](../security/security-audit-asvs.md) | partial |
| PI1.2 Inputs complete & accurate | Identifier allowlisting + bound parameters (no SQL string interpolation) | [`../security-audit.md`](../security/security-audit.md) | proven |
| PI1.3 Processing complete & accurate | Atomic single-mount transactions; owner-stamped writes on all engines | gate `m46` | partial |
| PI1.4 Output complete & accurate to recipients | Per-tenant export with manifest (tables/counts/sha256) | gate `m109` (migration `052_tenant_exports.sql`) | proven |
| PI1.5 Storage complete & accurate | Tamper-evident audit + backup integrity | gate `m104`, gate `m87` | partial |

Processing Integrity is **partial**: the input-validation and output-integrity halves are gate-proven,
but end-to-end processing-completeness assurance over the window is auditor work.

---

## 5. Privacy (P) — see the GDPR cross-walk

The Privacy category overlaps GDPR. Rather than restate it, this doc defers to
[`gdpr-article-matrix.md`](./gdpr-article-matrix.md), which maps notice, choice/consent, collection,
use/retention, access, disclosure, quality, and monitoring to the same controls. The load-bearing
privacy controls — access/portability (`m109`), erasure (`m105`), records of processing (`m104` +
[`gdpr-ropa.md`](./gdpr-ropa.md)) — are gate-proven.

---

## 6. SOC 2 Type 1 vs Type 2 — what is and isn't covered here

A **Type 1** report opines on whether controls are *suitably designed* at a point in time. A
**Type 2** report adds *operating effectiveness over an observation window* (commonly 3–12 months),
testing a **sampled population** of evidence.

This pack puts Grobase in a strong **design** posture (the substance behind a Type 1) and pre-stages
the Type 2 population:

- The `m108` SOC2-lite evidence collector (migration `051_compliance_evidence.sql`) **is the sampled
  population**: it seals hash-chained snapshots of CI-gate results, access posture, and the
  change-management trail, so the window's evidence accumulates continuously rather than being
  reconstructed at audit time.
- What it does **not** do: replace the auditor. The opinion, the window, and the testing are the
  external CPA firm's — enumerated as a human/$$ atom in [`auditor-handoff.md`](./auditor-handoff.md).

> **Bottom line:** Grobase is audit-ready for SOC 2 (Security + Confidentiality strongest;
> Availability pending the uptime probe; Processing Integrity partial; Privacy via GDPR). The report
> itself is **pending-auditor** — `formal-soc2-type2` is **planned** in `posture.json`, never claimed.
