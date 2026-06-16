# Auditor Handoff — the single index for SOC 2 / ISO 27001 / Vanta / Drata

> **What this is.** The one document you hand to a SOC 2 auditor, an ISO/IEC 27001 certification
> body, or a compliance-automation platform (Vanta / Drata / Secureframe). It indexes the control
> catalog, the framework matrices, the re-runnable evidence, the policies, and — honestly — the
> **human/$$ atoms** that remain before a *certificate* exists. Grobase is **audit-ready, not
> certified** (kernel rule #4); this index makes the audit a checklist, not an archaeology dig.

---

## 1. The control catalog (start here)

- **Canonical, machine-readable:** `config/trust/posture.json` — served at `GET /v1/trust` (and
  `GET /v1/trust/controls`) when `TRUST_CENTER_ENABLED=1`. Every control carries `id · name ·
  category · status · evidence`. **If any doc disagrees with this file, the file wins.**
- **Human posture matrix:** [`../compliance-posture.md`](../compliance-posture.md) (ASVS × SOC 2 ×
  GDPR), gate-kept by `m141`.
- **Public posture page:** [`../trust-center.md`](../trust-center.md).

## 2. The framework cross-walks

| Framework | Document | Coverage |
|---|---|---|
| SOC 2 (TSC) | [`soc2-tsc-matrix.md`](soc2-tsc-matrix.md) | CC1–CC9 + Availability / Confidentiality / Processing Integrity / Privacy |
| GDPR | [`gdpr-article-matrix.md`](gdpr-article-matrix.md) | Art. 5–50, controller/processor split |
| ISO/IEC 27001:2022 | [`iso27001-soa.md`](iso27001-soa.md) | Statement of Applicability — all 93 Annex A controls + ISMS clause 4–10 gap |

## 3. Re-runnable evidence (the differentiator)

Unlike a paper report, Grobase's controls are **gates an auditor can run themselves** against a
tenant-control built from current source on a throwaway database (they never touch the shared stack):

```bash
# the full enterprise + data-plane battery (the nightly set)
bash mini-baas-infra/scripts/verify/run-gate-battery.sh --enterprise
```

Key gates by assurance area:

| Area | Gate | Proves |
|---|---|---|
| Tamper-evident audit | `m104` | hash-chain recomputes; a tampered row → `intact:false` at the broken seq |
| Right to erasure (GDPR Art. 17) | `m105` | scoped delete + receipt; another tenant never touched |
| Data portability (GDPR Art. 15/20) | `m109` | engine-neutral export + manifest, strictly tenant-scoped |
| Per-tenant isolation | `m46` | per-request isolation byte-identical at 10K tenants → 1 pool |
| Fine-grained ABAC | `m136` | conditions/column-mask/per-instance enforced |
| IP allowlist | `m106` | per-tenant network access control enforced + flag-off parity |
| Passkeys (WebAuthn) | `m107` | full ceremony; wrong-key/replay/cross-user rejected |
| Org RBAC / SSO / SCIM | `m103` / `m110` / `m111` | org model + OIDC + SCIM lifecycle + cross-tenant wall |
| CMEK / BYOK | `m123` | envelope seal/unwrap + crypto-shred on KEK revocation |
| Continuous evidence | `m108` | seals signed snapshots of CI/access/change-mgmt |
| Posture matrix | `m141` | docs + standards mapping + audit spine + GDPR rights surface |
| Framework cross-walks | `m143` | matrices complete (all Annex A) + honest (no dangling citation) |

## 4. The sampled population (SOC 2 Type 2 / continuous monitoring)

The `m108` SOC2-lite evidence collector (migration `051_compliance_evidence.sql`) seals
**hash-sealed evidence snapshots** of CI-gate results, access posture, and the change-management
trail. **This is the sampled population** an auditor draws from for the Type 2 observation window —
it accumulates continuously, so the window's evidence is collected as it happens rather than
reconstructed at audit time. A failing/stubbed control records `all_passing:false` and DB tamper is
detected — the collector cannot be quietly faked.

## 5. Map each Vanta / Drata test → the gate or snapshot that satisfies it

Compliance-automation platforms run a catalog of automated tests. Wire each to the in-repo artifact:

| Platform test (typical) | Grobase artifact |
|---|---|
| "Audit logging enabled / immutable" | gate `m104` (tamper-evident chain) + `m108` snapshot |
| "Data deletion / right-to-erasure capability" | gate `m105` |
| "Data export / portability capability" | gate `m109` |
| "Encryption in transit" / "encryption keys managed" | gate `m123` + TLS evidence (`../security-audit-asvs.md`) |
| "MFA / phishing-resistant auth" | gate `m107` (passkeys) + `m110` (SSO) |
| "RBAC / least privilege" | gate `m103` + `m136` |
| "Access provisioning / deprovisioning" | gate `m111` (SCIM lifecycle) |
| "Network access restricted" | gate `m106` (IP allowlist) |
| "Backups configured / recovery tested" | gate `m87` + `m99` + `m47` |
| "Vulnerability scanning in CI" | `../security-audit.md` (SCA/SAST/secret/container CI jobs) |
| "Change management / code review" | gate `m143` + change-management policy |
| "Risk assessment maintained" | [`risk-register.md`](risk-register.md) |
| "Policies adopted" | [`security-policies/00-index.md`](security-policies/00-index.md) |
| "Continuous control monitoring" | gate `m108` snapshots |

For a custom check that has no automated mapping, point the platform's evidence-upload at the
relevant gate's output or the `m108` snapshot.

## 6. Policies, risk, records, templates

- **Policies (ISMS):** [`security-policies/00-index.md`](security-policies/00-index.md) — infosec,
  access-control, incident-response, change-management, vendor/supplier, BCP/DR, data-retention.
- **Risk register:** [`risk-register.md`](risk-register.md) (ISO clause 6 / SOC 2 CC3).
- **Records of Processing (GDPR Art. 30):** [`gdpr-ropa.md`](gdpr-ropa.md).
- **DPIA template (GDPR Art. 35):** [`dpia-template.md`](dpia-template.md).
- **Legal templates (counsel review required):** [`../legal/data-processing-addendum.md`](../legal/data-processing-addendum.md)
  (DPA/Art. 28), [`../legal/subprocessors.md`](../legal/subprocessors.md), [`../legal/privacy-policy.md`](../legal/privacy-policy.md),
  [`../legal/terms-of-service.md`](../legal/terms-of-service.md), [`../legal/sla.md`](../legal/sla.md),
  [`../legal/acceptable-use-policy.md`](../legal/acceptable-use-policy.md).

## 7. The pending human / $$ atoms (the honest gap to a certificate)

These are **not code gaps** — they need a person, a contract, or a business milestone:

| Atom | Why it's required | Blocks |
|---|---|---|
| External SOC 2 auditor (CPA firm) | Only an auditor can issue the opinion over the observation window | SOC 2 Type 1 → Type 2 report |
| Accredited ISO/IEC 27001 certification body | Stage-1/Stage-2 audit + certificate | ISO 27001 certificate |
| Legal counsel | Convert the DPA/ToS/Privacy/SLA templates into binding agreements | Art. 28 DPA, customer contracts |
| DPO / EU representative | Where Art. 27/37 require appointment | GDPR governance |
| Live IdP (Okta / Entra / Auth0 / Google) | SSO/SCIM are gate-proven against a mock; a live IdP is customer-supplied | Production SSO/SCIM |
| External KMS (Vault Transit / cloud KMS) | CMEK is proven with Vault Transit; a customer's KMS is their atom | Production CMEK/BYOK |
| C7 uptime probe + status page | No SLA is enforceable until durable availability samples exist | `sla-uptime`, Availability (A1.1) |
| Independent penetration test | A6 / A.5.35 independent review | External security validation |

## 8. SOC 2 Type 1 → Type 2 and the ISO ISMS stand-up sequence

**SOC 2:**
1. Engage the CPA firm; confirm scope (Security + Confidentiality strongest; add Availability once
   the uptime probe is live; Processing Integrity is partial; Privacy via GDPR).
2. **Type 1** — auditor opines on suitable *design* at a point in time. The control catalog +
   matrices + gates above are the design evidence.
3. Run the **observation window** (3–12 months); the `m108` collector accumulates the sampled
   population continuously.
4. **Type 2** — auditor tests *operating effectiveness* over the window from the `m108` snapshots +
   gate outputs.

**ISO/IEC 27001:**
1. Stand up the ISMS management system (clauses 4–10): scope, policies (adopt the set in
   [`security-policies/`](security-policies/00-index.md)), risk treatment ([`risk-register.md`](risk-register.md)),
   the SoA ([`iso27001-soa.md`](iso27001-soa.md)).
2. Operate it over a cycle: internal audits, management reviews, corrective actions
   (clauses 9–10) — the gap noted in the SoA's "ISMS management-system gap" section.
3. **Stage-1** (documentation review — the SoA is the centerpiece) → **Stage-2** (operating
   effectiveness) → **certificate** from the accredited body.

> **Bottom line for the auditor:** the substance is built and continuously re-verifiable. What
> remains is your opinion, the calendar window, and the business artifacts (auditor engagement,
> counsel, live IdP/KMS, uptime probe) — all enumerated above, none hidden.
