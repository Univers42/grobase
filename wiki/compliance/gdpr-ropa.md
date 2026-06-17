# GDPR Art. 30 — Records of Processing Activities (RoPA)

> **Template + maintained record.** GDPR Art. 30 requires both controllers and processors to keep a
> record of processing activities. This document has **two views**: Grobase as **PROCESSOR** (the
> default — processing on behalf of customer-controllers) and Grobase as **CONTROLLER** (its own
> account/billing/auth data). Controller-specific fields a deployment must fill carry `[TBD]`.
>
> The **technical processing record** that underpins this RoPA is the tamper-evident, hash-chained
> audit log (gate `m104`, migration `047_tenant_audit_log.sql`) — it records who did what, when, to
> which resource, in a manner a buyer can cryptographically re-verify.

---

## View A — Grobase as PROCESSOR (default)

In the common deployment Grobase processes personal data **on the documented instructions of the
customer-controller** (Art. 28). The processor record per Art. 30(2):

| Field | Record |
|---|---|
| **Processor** | Grobase (the operator running Grobase Cloud, or the self-host operator) |
| **Processor's representative / DPO** | `[TBD]` — appoint per Art. 27/37 where required |
| **Controllers on whose behalf processing occurs** | The customers/tenants — each is a controller for its end-users' data |
| **Categories of processing carried out** | Storage, retrieval, structuring, transmission (API), backup, deletion/erasure, export/portability of controller-supplied data; metering of usage |
| **Categories of data subjects** | Determined by the controller (e.g. the controller's end-users/customers) — `[TBD]` per controller |
| **Categories of personal data** | Determined by the controller (whatever they store in their tenant) — `[TBD]` per controller; Grobase is data-type-agnostic by design |
| **Special-category data (Art. 9)** | Possible if the controller stores it; the controller decides — `[TBD]` |
| **Categories of recipients** | The controller and its authorized principals only (per-request isolation `m46`); no Grobase-operated subprocessor sees self-hosted data |
| **Subprocessors (managed-cloud)** | Listed in [`../legal/subprocessors.md`](../legal/subprocessors.md) (hosting, object storage, email, payments) — **template, counsel review required**; **self-host has none** |
| **International transfers** | **Self-host: none** (controller chooses region). Managed-cloud: per the subprocessor regions + SCC references in the [DPA](../legal/data-processing-addendum.md) |
| **Retention / erasure** | Controller-defined; erasure executed via hard-erase (gate `m105`, migration `048_tenant_erasure.sql`); export via gate `m109` (migration `052_tenant_exports.sql`) |
| **Technical & organizational security measures (Art. 32)** | Per-request isolation (`m46`), CMEK envelope encryption (`m123`), credentials AES-256-GCM, TLS in transit, tamper-evident audit (`m104`), backup/PITR (`m87`/`m99`), IP allowlist (`m106`) |
| **Technical processing record** | Tamper-evident audit chain — gate `m104` |

> **The processor-default point:** Grobase does not determine purposes/means of processing the
> controller's end-user data. It provides a secure, isolated substrate and the rights tooling
> (export/erase). Categories of subjects and data are therefore the **controller's** record to
> complete (`[TBD]` above), which is correct under Art. 30(2).

---

## View B — Grobase as CONTROLLER (its own data)

Grobase is a controller for the personal data of **its own direct customers** — account, billing,
and authentication data — processed to run the service. The controller record per Art. 30(1):

| Field | Record |
|---|---|
| **Controller** | Grobase (the operator of Grobase Cloud) |
| **Controller's representative / DPO** | `[TBD]` — appoint per Art. 27/37 where required |
| **Purposes of processing** | Account management, authentication, billing/metering, support, security/abuse prevention |
| **Categories of data subjects** | Grobase's direct customers (account holders, org members, billing contacts) |
| **Categories of personal data** | Name/email, authentication credentials (hashed: API keys SHA-256, passwords Argon2id), org membership/roles, billing identifiers (Stripe customer/meter ids), usage counters, access logs |
| **Special-category data (Art. 9)** | None processed by Grobase as controller |
| **Categories of recipients** | Internal authorized staff (least-privilege, `m136`); payment processor + email provider as subprocessors ([`../legal/subprocessors.md`](../legal/subprocessors.md)) |
| **International transfers** | `[TBD]` — depends on hosting region; SCC references in the DPA where applicable |
| **Retention** | Account/billing data retained for the contractual + statutory period; deleted/anonymised on closure per [`security-policies/data-retention-policy.md`](./security-policies/data-retention-policy.md) |
| **Lawful basis** | Contract (Art. 6(1)(b)) for service delivery; legitimate interests (Art. 6(1)(f)) for security/abuse; legal obligation (Art. 6(1)(c)) for billing records |
| **Technical & organizational security measures** | Same control set as View A; secrets via Vault, high-entropy keys fast-hashed, passwords Argon2id |
| **Technical processing record** | Tamper-evident audit chain — gate `m104` |

---

## Maintaining this record

- **Self-host operators** maintain their own controller record; Grobase ships the technical
  processing record (`m104`) and the rights tooling (`m105`/`m109`).
- **Managed-cloud** keeps both views current; the subprocessor list is the authoritative recipient
  record ([`../legal/subprocessors.md`](../legal/subprocessors.md)).
- Review cadence: at least annually and on any material change of processing (new subprocessor, new
  data category, new transfer). The change-management gate harness flags posture drift; the audit
  chain is the durable evidence.

See also: [`gdpr-article-matrix.md`](./gdpr-article-matrix.md) (article-by-article),
[`dpia-template.md`](./dpia-template.md) (Art. 35), [`../legal/data-processing-addendum.md`](../legal/data-processing-addendum.md) (Art. 28).
