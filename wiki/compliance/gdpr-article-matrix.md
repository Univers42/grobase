# GDPR — Article-by-Article Cross-Walk

> **Audit-ready cross-walk.** This maps the relevant GDPR articles to the Grobase technical measure
> (a backticked gate) or organizational/legal measure that addresses them, and to **who owns it** —
> the **controller** (the customer) or the **processor** (Grobase). It is the GDPR projection of
> [`../compliance-posture.md`](../compliance-posture.md) and `config/trust/posture.json`; it does not
> assert compliance for any specific deployment — GDPR compliance is a property of *how a controller
> uses* Grobase, not of the software alone.

## The processor-default framing (read this first)

> **In the common deployment, Grobase is the PROCESSOR and the customer is the CONTROLLER.** The
> customer decides the purposes and means of processing personal data of *their* end-users; Grobase
> processes that data **on the controller's documented instructions** (Art. 28). Grobase is a
> **controller only** for its own account/billing/auth data (its direct customers — see the
> controller view in [`gdpr-ropa.md`](gdpr-ropa.md)).
>
> This split decides ownership of every right below: data-subject *requests* (Art. 12–22) are
> **fulfilled by the controller**, using Grobase's technical tools (export `m109`, erase `m105`).
> Grobase's job as processor is to **make those tools available, secure the data, assist the
> controller, and not process beyond instructions.**

**Status legend:** **proven** (in-repo gate) · **partial** (real, named gap) · **org/legal**
(satisfied by policy/contract, not code) · **planned** (not yet stood up). If this doc and
`posture.json` disagree, the JSON is canonical.

---

## 1. Principles & lawful basis (Art. 5–7)

| Article | Requirement | Technical OR org/legal measure | Owner | Status |
|---|---|---|---|---|
| Art. 5 | Principles (lawfulness, purpose limitation, minimisation, accuracy, storage limitation, integrity & confidentiality, accountability) | Per-tenant isolation (`m46`) + tamper-evident audit as accountability record (`m104`); retention via erasure (`m105`) | Controller (principles) / Processor (security & accountability tooling) | partial |
| Art. 6 | Lawful basis for processing | Controller establishes basis; Grobase processes only on instruction | Controller | org/legal |
| Art. 7 | Conditions for consent | Controller obtains & records consent; Grobase stores it as ordinary tenant data under isolation | Controller | org/legal |

---

## 2. Data-subject rights (Art. 12–23)

| Article | Right | Technical OR org/legal measure | Owner | Status |
|---|---|---|---|---|
| Art. 12 | Transparent information & modalities for exercising rights | Controller's privacy notice; Grobase provides the technical surface | Controller | org/legal |
| Art. 13–14 | Information to be provided (collected from / not from subject) | Controller's privacy notice ([`../legal/privacy-policy.md`](../legal/privacy-policy.md) is a TEMPLATE) | Controller | org/legal |
| **Art. 15** | **Right of access** | Engine-neutral export bundle of ONE tenant's data + manifest (tables/counts/sha256), strictly tenant-scoped | Controller (issues) / Processor (tool) — gate `m109` (migration `052_tenant_exports.sql`) | proven |
| Art. 16 | Right to rectification | Standard authenticated CRUD under owner-scope/ABAC | Controller — gate `m46`, gate `m136` | proven |
| **Art. 17** | **Right to erasure ("right to be forgotten")** | Scoped hard delete (`DROP SCHEMA … CASCADE` / `WHERE tenant_id`) + tamper-evident erasure receipt cross-linked to the audit chain; CMEK KEK revocation crypto-shreds | Controller (issues) / Processor (tool) — gate `m105` (migration `048_tenant_erasure.sql`), gate `m123` | proven |
| Art. 18 | Right to restriction of processing | ABAC condition/grant revocation + per-instance grants suspend access without deletion | Controller — gate `m136`, gate `m137` | partial |
| Art. 19 | Notification of rectification/erasure/restriction | Controller notifies recipients; erasure receipt is the technical record | Controller — gate `m105` | partial |
| **Art. 20** | **Right to data portability** | Same engine-neutral export bundle as Art. 15, structured + machine-readable JSON | Controller (issues) / Processor (tool) — gate `m109` | proven |
| Art. 21 | Right to object | Controller honours objection (process); enforced via access revocation | Controller — gate `m136` | partial |
| Art. 22 | Automated decision-making / profiling | Grobase performs no automated decision-making on subjects' behalf; controller-defined logic only | Controller | org/legal |
| Art. 23 | Restrictions (Member-State law) | Controller's legal determination | Controller | org/legal |

---

## 3. Controller & processor obligations (Art. 25, 28, 30, 32–34)

| Article | Requirement | Technical OR org/legal measure | Owner | Status |
|---|---|---|---|---|
| **Art. 25** | **Data protection by design & by default** | Owner-scoped predicates re-stamped per request on every engine (isolation by construction) + fine-grained ABAC PDP (conditions/column-mask/per-instance) | Processor (by design) — gate `m46`, gate `m136` | proven |
| **Art. 28** | **Processor obligations / DPA** | Data Processing Addendum with SCC references + subprocessor transparency; process-only-on-instruction; assist-with-rights; sub-processor flow-down | Processor — [`../legal/data-processing-addendum.md`](../legal/data-processing-addendum.md), [`../legal/subprocessors.md`](../legal/subprocessors.md) (TEMPLATES, counsel review required) | org/legal |
| **Art. 30** | **Records of processing activities** | Tamper-evident, hash-chained audit log as the technical processing record + the maintained RoPA | Processor & Controller — gate `m104` (migration `047_tenant_audit_log.sql`), [`gdpr-ropa.md`](gdpr-ropa.md) | proven |
| **Art. 32** | **Security of processing** | Pseudonymisation/encryption (CMEK envelope, credentials AES-256-GCM, TLS in transit), CIA, restore (backup/PITR), and regular testing (the gate battery) | Processor — gate `m123`, gate `m104`, gate `m87`, gate `m99`, TLS in transit (`../security-audit-asvs.md`) | partial |
| **Art. 33** | **Breach notification to supervisory authority** | Forensic evidence = tamper-evident audit chain; notification process in the incident runbook | Controller (notifies) / Processor (assists w/o undue delay) — [`security-policies/incident-response-policy.md`](security-policies/incident-response-policy.md), gate `m104` | partial |
| **Art. 34** | **Breach communication to data subjects** | Controller communicates; Grobase supplies the forensic record & assistance | Controller — [`security-policies/incident-response-policy.md`](security-policies/incident-response-policy.md) | partial |
| **Art. 35** | **Data protection impact assessment (DPIA)** | DPIA template the controller fills, cross-referencing isolation / `m123` / `m105` / `m104` | Controller (conducts) / Processor (provides template + assistance) — [`dpia-template.md`](dpia-template.md) | org/legal |

---

## 4. International transfers (Art. 44–50)

| Article | Requirement | Technical OR org/legal measure | Owner | Status |
|---|---|---|---|---|
| Art. 44 | General principle for transfers | **Self-host removes the transfer** — the controller chooses the region/cloud; no Grobase subprocessor sees self-hosted data | Controller | proven |
| Art. 45 | Adequacy decisions | Controller selects an adequate region; managed-cloud subprocessor regions listed | Controller — [`../legal/subprocessors.md`](../legal/subprocessors.md) | org/legal |
| Art. 46 | Appropriate safeguards (SCCs) | Standard Contractual Clauses referenced in the DPA | Processor — [`../legal/data-processing-addendum.md`](../legal/data-processing-addendum.md) | org/legal |
| Art. 47–49 | BCRs / derogations | Out of scope for self-host; managed-cloud relies on SCCs (Art. 46) | Controller/Processor | org/legal |
| Art. 50 | Cooperation with third countries | Org/legal | Controller | org/legal |

> **The self-host advantage (Art. 44–46).** When the customer self-hosts, personal data never leaves
> the infrastructure they chose — there is **no international transfer to a Grobase subprocessor to
> safeguard**. Transfer mechanisms (SCCs/adequacy) only bite for the managed-cloud offering, where
> the subprocessor list ([`../legal/subprocessors.md`](../legal/subprocessors.md)) and the DPA's SCC
> references apply.

---

## 5. Summary — what is gate-proven vs. controller/legal

- **Gate-proven technical rights & measures:** access/portability (`m109`, Art. 15/20), erasure
  (`m105`, Art. 17), processing record (`m104`, Art. 30), by-design isolation + ABAC (`m46`/`m136`,
  Art. 25), encryption/CMEK (`m123`, Art. 32), recoverability (`m87`/`m99`, Art. 32(1)(c)).
- **Controller-owned (process/legal):** lawful basis & consent (Art. 6–7), notices (Art. 12–14),
  honouring objection/restriction decisions (Art. 18/21), breach *notification* (Art. 33/34),
  conducting the DPIA (Art. 35), choosing the region (Art. 44–45).
- **Processor obligations (legal, via templates):** the DPA (Art. 28) and subprocessor transparency
  — `[`../legal/data-processing-addendum.md`](../legal/data-processing-addendum.md)` and
  `[`../legal/subprocessors.md`](../legal/subprocessors.md)` are **templates pending counsel review**.

Grobase ships the technical tools that make a controller's GDPR program *executable and provable*; it
does not — and cannot — make a deployment compliant on the controller's behalf. The honest line:
**audit-ready data-subject machinery, controller-owned legal program.**
