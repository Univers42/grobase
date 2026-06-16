# ISO/IEC 27001:2022 — Statement of Applicability (SoA)

> **Audit-ready SoA draft — not certified; ISMS clauses 4–10 not yet operated over a cycle.** This
> is the Annex A Statement of Applicability for Grobase: every one of the **93** Annex A:2022
> controls is listed with an applicability decision, the implementation route, a status, and (where
> applicable) an in-repo gate. It is the ISO projection of `config/trust/posture.json`; it does not
> assert certification — `formal-iso27001` is **planned** in `posture.json`. A certificate requires
> an operated ISMS plus an accredited body over an audit cycle (a human/$$ atom — see
> [`auditor-handoff.md`](auditor-handoff.md)).

**Columns.** *Applicable?* = yes/no + one-line justification. *Implementation* ∈
**in-repo** (a Grobase control/gate), **inherited-from-cloud** (shared-responsibility: the hosting
provider's certified control — physical, environmental, redundant power), or **org-policy** (a
documented policy/process). *Status* ∈ **proven** (gate/CI) · **partial** (real, named gap) ·
**inherited** (provider) · **org-policy** (documented, pending operation/adoption). If this SoA and
`posture.json` disagree, the JSON is canonical.

Annex A:2022 has four themes: **A.5 Organizational (37)**, **A.6 People (8)**,
**A.7 Physical (14)**, **A.8 Technological (34)** = 93.

---

## A.5 — Organizational controls (37)

| Control | Name | Applicable? | Implementation | Status | Evidence |
|---|---|---|---|---|---|
| A.5.1 | Policies for information security | Yes — ISMS needs a policy set | org-policy | org-policy | [`security-policies/infosec-policy.md`](security-policies/infosec-policy.md) |
| A.5.2 | Information security roles and responsibilities | Yes — roles must be assigned | org-policy | org-policy | [`security-policies/00-index.md`](security-policies/00-index.md) |
| A.5.3 | Segregation of duties | Yes — change vs. review separation | org-policy + CI | partial | [`security-policies/change-management-policy.md`](security-policies/change-management-policy.md) |
| A.5.4 | Management responsibilities | Yes — management drives the ISMS | org-policy | org-policy | [`security-policies/infosec-policy.md`](security-policies/infosec-policy.md) |
| A.5.5 | Contact with authorities | Yes — breach/incident contact | org-policy | org-policy | [`security-policies/incident-response-policy.md`](security-policies/incident-response-policy.md) |
| A.5.6 | Contact with special interest groups | Yes — vuln intelligence | org-policy | org-policy | [`security-policies/infosec-policy.md`](security-policies/infosec-policy.md) |
| A.5.7 | Threat intelligence | Yes — feeds vuln management | org-policy + CI SCA | partial | [`../security-audit.md`](../security-audit.md) |
| A.5.8 | Information security in project management | Yes — security gates per change | in-repo (gate harness) | proven | gate `m143` |
| A.5.9 | Inventory of information and other associated assets | Yes — control/asset catalog | in-repo + risk register | partial | [`risk-register.md`](risk-register.md) |
| A.5.10 | Acceptable use of information and other associated assets | Yes | org-policy | org-policy | [`../legal/acceptable-use-policy.md`](../legal/acceptable-use-policy.md) |
| A.5.11 | Return of assets | Yes — offboarding | org-policy | org-policy | [`security-policies/access-control-policy.md`](security-policies/access-control-policy.md) |
| A.5.12 | Classification of information | Yes — tenant data vs. metadata | org-policy | org-policy | [`security-policies/data-retention-policy.md`](security-policies/data-retention-policy.md) |
| A.5.13 | Labelling of information | Yes | org-policy | org-policy | [`security-policies/data-retention-policy.md`](security-policies/data-retention-policy.md) |
| A.5.14 | Information transfer | Yes — TLS + export controls | in-repo | partial | gate `m109` |
| A.5.15 | Access control | Yes — core control | in-repo | proven | gate `m103`, gate `m136` |
| A.5.16 | Identity management | Yes — users/orgs/SSO/SCIM | in-repo | proven | gate `m110`, gate `m111` |
| A.5.17 | Authentication information | Yes — keys/passkeys, secret hygiene | in-repo | proven | gate `m107` |
| A.5.18 | Access rights | Yes — provisioning/review/revocation | in-repo | proven | gate `m111`, gate `m136` |
| A.5.19 | Information security in supplier relationships | Yes — subprocessors | org-policy | org-policy | [`security-policies/vendor-supplier-policy.md`](security-policies/vendor-supplier-policy.md) |
| A.5.20 | Addressing information security within supplier agreements | Yes — DPA/SCC | org-policy | org-policy | [`../legal/data-processing-addendum.md`](../legal/data-processing-addendum.md) |
| A.5.21 | Managing information security in the ICT supply chain | Yes — supply-chain locks | in-repo (CI) | proven | [`../security-audit.md`](../security-audit.md) |
| A.5.22 | Monitoring, review and change management of supplier services | Yes | org-policy | org-policy | [`security-policies/vendor-supplier-policy.md`](security-policies/vendor-supplier-policy.md) |
| A.5.23 | Information security for use of cloud services | Yes — managed-cloud overlay | org-policy + in-repo | partial | [`../legal/subprocessors.md`](../legal/subprocessors.md) |
| A.5.24 | Information security incident management planning and preparation | Yes | org-policy | org-policy | [`security-policies/incident-response-policy.md`](security-policies/incident-response-policy.md) |
| A.5.25 | Assessment and decision on information security events | Yes — triage | org-policy + audit | partial | gate `m104` |
| A.5.26 | Response to information security incidents | Yes | org-policy | org-policy | [`../operations-runbook.md`](../operations-runbook.md) |
| A.5.27 | Learning from information security incidents | Yes — post-incident | org-policy | org-policy | [`security-policies/incident-response-policy.md`](security-policies/incident-response-policy.md) |
| A.5.28 | Collection of evidence | Yes — forensic, tamper-evident | in-repo | proven | gate `m104` |
| A.5.29 | Information security during disruption | Yes — BCP | in-repo + org-policy | partial | gate `m87`, gate `m99` |
| A.5.30 | ICT readiness for business continuity | Yes — backup/PITR/restore drill | in-repo | partial | gate `m99`, gate `m47` |
| A.5.31 | Legal, statutory, regulatory and contractual requirements | Yes — GDPR mapping | org-policy + in-repo | partial | [`gdpr-article-matrix.md`](gdpr-article-matrix.md) |
| A.5.32 | Intellectual property rights | Yes — licensing/dependencies | org-policy | org-policy | [`security-policies/vendor-supplier-policy.md`](security-policies/vendor-supplier-policy.md) |
| A.5.33 | Protection of records | Yes — tamper-evident audit + backups | in-repo | proven | gate `m104`, gate `m87` |
| A.5.34 | Privacy and protection of PII | Yes — GDPR machinery | in-repo | proven | gate `m105`, gate `m109` |
| A.5.35 | Independent review of information security | Yes — external review/pen test | org-policy | org-policy | [`auditor-handoff.md`](auditor-handoff.md) |
| A.5.36 | Compliance with policies, rules and standards for information security | Yes — gate battery enforces | in-repo | proven | gate `m143`, gate `m108` |
| A.5.37 | Documented operating procedures | Yes — runbooks | org-policy | org-policy | [`../operations-runbook.md`](../operations-runbook.md) |

---

## A.6 — People controls (8)

| Control | Name | Applicable? | Implementation | Status | Evidence |
|---|---|---|---|---|---|
| A.6.1 | Screening | Yes — personnel screening pre-hire | org-policy | org-policy | [`security-policies/infosec-policy.md`](security-policies/infosec-policy.md) |
| A.6.2 | Terms and conditions of employment | Yes — security in contracts | org-policy | org-policy | [`security-policies/infosec-policy.md`](security-policies/infosec-policy.md) |
| A.6.3 | Information security awareness, education and training | Yes — recurring training | org-policy | org-policy | [`security-policies/infosec-policy.md`](security-policies/infosec-policy.md) |
| A.6.4 | Disciplinary process | Yes | org-policy | org-policy | [`security-policies/infosec-policy.md`](security-policies/infosec-policy.md) |
| A.6.5 | Responsibilities after termination or change of employment | Yes — offboarding | org-policy | org-policy | [`security-policies/access-control-policy.md`](security-policies/access-control-policy.md) |
| A.6.6 | Confidentiality or non-disclosure agreements | Yes — NDAs | org-policy | org-policy | [`security-policies/vendor-supplier-policy.md`](security-policies/vendor-supplier-policy.md) |
| A.6.7 | Remote working | Yes — distributed team | org-policy | org-policy | [`security-policies/access-control-policy.md`](security-policies/access-control-policy.md) |
| A.6.8 | Information security event reporting | Yes — reporting channel | org-policy | org-policy | [`security-policies/incident-response-policy.md`](security-policies/incident-response-policy.md) |

---

## A.7 — Physical controls (14)

> **All A.7 controls are inherited-from-cloud (shared responsibility).** Grobase ships no data
> centre; physical and environmental security is the certified hosting provider's control (and, for
> self-host, the customer's facility). Each row is **Applicable = yes** for the managed-cloud offering
> and inherited from the provider's own ISO/SOC attestation; for self-host it is the customer's.

| Control | Name | Applicable? | Implementation | Status | Evidence |
|---|---|---|---|---|---|
| A.7.1 | Physical security perimeters | Yes — provider DC perimeter | inherited-from-cloud | inherited | provider attestation ([`security-policies/vendor-supplier-policy.md`](security-policies/vendor-supplier-policy.md)) |
| A.7.2 | Physical entry | Yes | inherited-from-cloud | inherited | provider attestation |
| A.7.3 | Securing offices, rooms and facilities | Yes | inherited-from-cloud | inherited | provider attestation |
| A.7.4 | Physical security monitoring | Yes | inherited-from-cloud | inherited | provider attestation |
| A.7.5 | Protecting against physical and environmental threats | Yes | inherited-from-cloud | inherited | provider attestation |
| A.7.6 | Working in secure areas | Yes | inherited-from-cloud | inherited | provider attestation |
| A.7.7 | Clear desk and clear screen | Yes — for staff endpoints | org-policy | org-policy | [`security-policies/access-control-policy.md`](security-policies/access-control-policy.md) |
| A.7.8 | Equipment siting and protection | Yes | inherited-from-cloud | inherited | provider attestation |
| A.7.9 | Security of assets off-premises | Yes — staff laptops | org-policy | org-policy | [`security-policies/access-control-policy.md`](security-policies/access-control-policy.md) |
| A.7.10 | Storage media | Yes — provider-managed disks | inherited-from-cloud | inherited | provider attestation |
| A.7.11 | Supporting utilities | Yes — power/cooling | inherited-from-cloud | inherited | provider attestation |
| A.7.12 | Cabling security | Yes | inherited-from-cloud | inherited | provider attestation |
| A.7.13 | Equipment maintenance | Yes | inherited-from-cloud | inherited | provider attestation |
| A.7.14 | Secure disposal or re-use of equipment | Yes — media sanitisation | inherited-from-cloud | inherited | provider attestation |

---

## A.8 — Technological controls (34)

| Control | Name | Applicable? | Implementation | Status | Evidence |
|---|---|---|---|---|---|
| A.8.1 | User end point devices | Yes — staff endpoints | org-policy | org-policy | [`security-policies/access-control-policy.md`](security-policies/access-control-policy.md) |
| A.8.2 | Privileged access rights | Yes — admin scope-gating + ABAC | in-repo | proven | gate `m136`, gate `m103` |
| A.8.3 | Information access restriction | Yes — owner-scope + column masks | in-repo | proven | gate `m136`, gate `m46` |
| A.8.4 | Access to source code | Yes — repo access + review | org-policy + CI | partial | [`security-policies/change-management-policy.md`](security-policies/change-management-policy.md) |
| A.8.5 | Secure authentication | Yes — passkeys + SSO/OIDC, alg-pinned JWT | in-repo | proven | gate `m107`, gate `m110` |
| A.8.6 | Capacity management | Yes — measured capacity | in-repo (bench) | partial | `make bench-capacity` ([`../scale-slo.md`](../scale-slo.md)) |
| A.8.7 | Protection against malware | Yes — supply-chain + container scans | in-repo (CI) | proven | [`../security-audit.md`](../security-audit.md) |
| A.8.8 | Management of technical vulnerabilities | Yes — blocking SCA/SAST in CI | in-repo (CI) | proven | [`../security-residuals-runbook.md`](../security-residuals-runbook.md) |
| A.8.9 | Configuration management | Yes — compose/editions as config-as-code | in-repo | partial | [`../02-layer-edition-model.md`](../02-layer-edition-model.md) |
| A.8.10 | Information deletion | Yes — GDPR hard-erase | in-repo | proven | gate `m105` (migration `048_tenant_erasure.sql`) |
| A.8.11 | Data masking | Yes — ABAC column masking | in-repo | proven | gate `m136`, gate `m135` |
| A.8.12 | Data leakage prevention | Yes — per-request isolation + SSRF guard | in-repo | partial | gate `m46` |
| A.8.13 | Information backup | Yes — per-tenant backup + PITR | in-repo | proven | gate `m87`, gate `m99` |
| A.8.14 | Redundancy of information processing facilities | Yes — provider redundancy + read-replica routing | inherited-from-cloud + in-repo | partial | gate `m122` |
| A.8.15 | Logging | Yes — tamper-evident audit log | in-repo | proven | gate `m104` (migration `047_tenant_audit_log.sql`) |
| A.8.16 | Monitoring activities | Yes — observability + continuous evidence | in-repo | partial | gate `m108`, gate `m72` |
| A.8.17 | Clock synchronization | Yes — HMAC skew window relies on NTP | inherited-from-cloud | inherited | provider attestation |
| A.8.18 | Use of privileged utility programs | Yes — scoped tooling | org-policy | org-policy | [`security-policies/access-control-policy.md`](security-policies/access-control-policy.md) |
| A.8.19 | Installation of software on operational systems | Yes — image-pinned, no install hooks | in-repo (CI) | proven | [`../security-audit.md`](../security-audit.md) |
| A.8.20 | Networks security | Yes — segmentation overlay + IP allowlist | in-repo | proven | gate `m106` (migration `049_tenant_ip_allowlist.sql`) |
| A.8.21 | Security of network services | Yes — Kong gateway, service-auth HMAC | in-repo | partial | [`../security-audit-asvs.md`](../security-audit-asvs.md) |
| A.8.22 | Segregation of networks | Yes — per-plane netseg overlay | in-repo | partial | [`../security-audit-asvs.md`](../security-audit-asvs.md) |
| A.8.23 | Web filtering | Yes — egress SSRF guard; L7 WAF operator/edge | in-repo + planned | partial | [`../security-audit.md`](../security-audit.md) |
| A.8.24 | Use of cryptography | Yes — CMEK envelope + AES-256-GCM + TLS | in-repo | proven | gate `m123` (migration `061_tenant_database_cmek.sql`) |
| A.8.25 | Secure development life cycle | Yes — gated SDLC, shadow→parity→cutover | in-repo | proven | gate `m143` |
| A.8.26 | Application security requirements | Yes — ASVS map + per-request authz | in-repo | partial | [`../security-audit-asvs.md`](../security-audit-asvs.md) |
| A.8.27 | Secure system architecture and engineering principles | Yes — three-plane, isolation by design | in-repo | proven | gate `m46` |
| A.8.28 | Secure coding | Yes — SAST/secret scan + identifier allowlisting | in-repo (CI) | proven | [`../security-audit.md`](../security-audit.md) (supply-chain CI) |
| A.8.29 | Security testing in development and acceptance | Yes — the gate battery is the acceptance test | in-repo | proven | gate `m143` |
| A.8.30 | Outsourced development | No — development is in-house, not outsourced | n/a | org-policy | [`security-policies/vendor-supplier-policy.md`](security-policies/vendor-supplier-policy.md) |
| A.8.31 | Separation of development, test and production environments | Yes — editions/compose overlays | in-repo + org-policy | partial | [`../02-layer-edition-model.md`](../02-layer-edition-model.md) |
| A.8.32 | Change management | Yes — PR + CI gate harness | in-repo | proven | gate `m143` |
| A.8.33 | Test information | Yes — synthetic/seeded test data, no prod PII in tests | in-repo + org-policy | partial | [`security-policies/data-retention-policy.md`](security-policies/data-retention-policy.md) |
| A.8.34 | Protection of information systems during audit testing | Yes — gates run on throwaway scratch DBs | in-repo | proven | gate `m141` |

---

## ISMS management-system gap (clauses 4–10 — not yet operated over a cycle)

The Annex A SoA above is the **controls** half. ISO/IEC 27001 certification also requires the
**management system** (clauses 4–10) to be *operated* over a cycle. Status of each, and which doc
satisfies it today:

| Clause | Requirement | Satisfied by (today) | Status |
|---|---|---|---|
| 4 — Context of the organization | Scope, interested parties, ISMS boundaries | [`security-policies/infosec-policy.md`](security-policies/infosec-policy.md) (scope section) | org-policy (draft) |
| 5 — Leadership | Policy, roles, management commitment | [`security-policies/infosec-policy.md`](security-policies/infosec-policy.md), [`security-policies/00-index.md`](security-policies/00-index.md) | org-policy (pending adoption) |
| 6 — Planning | Risk assessment & treatment, objectives | [`risk-register.md`](risk-register.md) + this SoA | partial |
| 7 — Support | Resources, competence, awareness, documented info | [`security-policies/00-index.md`](security-policies/00-index.md) | org-policy |
| 8 — Operation | Operate the risk treatment plan | The enforced controls above (gates) + runbooks | partial |
| 9 — Performance evaluation | Monitoring, internal audit, management review | gate `m108` (continuous evidence) + internal-audit notes (to be operated) | partial (pending-auditor) |
| 10 — Improvement | Nonconformity, corrective action, continual improvement | [`../security-residuals-runbook.md`](../security-residuals-runbook.md) + internal-audit notes | partial |

**The honest gap:** the controls are in-repo and re-verifiable; the *operated management system*
(internal audit cycle, management reviews, corrective-action records over time) is not yet run, and
certification needs an accredited body. This SoA is the Stage-1 centerpiece, not a certificate —
`formal-iso27001` is **planned** in `posture.json`. The human/$$ atoms are in
[`auditor-handoff.md`](auditor-handoff.md).
