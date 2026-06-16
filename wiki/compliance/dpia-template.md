# GDPR Art. 35 — Data Protection Impact Assessment (DPIA) Template

> **This is a TEMPLATE the controller fills in.** Under GDPR Art. 35, the **controller** (the
> customer) conducts a DPIA where processing is likely to result in a high risk to data subjects.
> Grobase, as processor, provides this template and the technical evidence to complete it (isolation,
> CMEK `m123`, erasure `m105`, audit `m104`). Fields the controller must complete carry `[TBD]`. This
> document is not legal advice — have counsel/your DPO review the completed DPIA.

When a DPIA is required (Art. 35(3), non-exhaustive): systematic & extensive automated evaluation
(profiling) with legal/significant effects; large-scale processing of special-category data
(Art. 9) or criminal-offence data; large-scale systematic monitoring of a publicly accessible area.

---

## 1. Description of the processing (Art. 35(7)(a))

| Field | Entry |
|---|---|
| Processing activity name | `[TBD]` |
| Controller | `[TBD]` |
| Processor(s) | Grobase (substrate) + Grobase subprocessors ([`../legal/subprocessors.md`](../legal/subprocessors.md)) |
| Nature of processing | `[TBD]` (e.g. storing & serving end-user records via the Grobase API) |
| Scope (data categories, volume, subjects, geography) | `[TBD]` |
| Context (relationship to subjects, expectations) | `[TBD]` |
| Purposes & lawful basis (Art. 6) | `[TBD]` |
| Data flows / systems | Frontend → Grobase API → engine; isolation per request (`m46`); audit (`m104`) |

## 2. Necessity & proportionality (Art. 35(7)(b))

| Question | Entry |
|---|---|
| Is the processing necessary for the stated purpose? | `[TBD]` |
| Is it proportionate (data minimisation, storage limitation)? | `[TBD]` — Grobase enables minimisation (store only what you need) and storage limitation (erasure `m105`) |
| Lawful basis documented? | `[TBD]` |
| How are data-subject rights supported? | Access/portability via export (`m109`); erasure via hard-erase (`m105`); rectification via authenticated CRUD under ABAC (`m136`) |

## 3. Risks to data subjects (Art. 35(7)(c))

| Risk | Likelihood | Impact | Notes |
|---|---|---|---|
| Unauthorized access / cross-tenant leak | `[TBD]` | `[TBD]` | Mitigated by per-request isolation (`m46`) + ABAC (`m136`) |
| Excessive retention | `[TBD]` | `[TBD]` | Mitigated by erasure (`m105`) + retention policy |
| Loss/destruction of data | `[TBD]` | `[TBD]` | Mitigated by backup + PITR (`m87`/`m99`) |
| Exposure of credentials/keys | `[TBD]` | `[TBD]` | Mitigated by CMEK envelope (`m123`) + secrets hygiene |
| `[TBD]` (controller-specific) | `[TBD]` | `[TBD]` | `[TBD]` |

## 4. Measures to address the risks (Art. 35(7)(d))

Cross-reference the Grobase technical controls that mitigate the risks above:

- **Isolation & access control** — per-request owner-scoping (`m46`), fine-grained ABAC with
  conditions / column masks / per-instance grants (`m136`).
- **Encryption** — CMEK/BYOK envelope encryption with crypto-shred on KEK revocation (`m123`);
  credentials sealed AES-256-GCM; TLS in transit.
- **Erasure & portability** — hard-erase with tamper-evident receipt (`m105`); engine-neutral export
  with manifest (`m109`).
- **Accountability & forensics** — tamper-evident, hash-chained audit log (`m104`).
- **Resilience** — per-tenant backup and point-in-time restore (`m87`/`m99`).
- **Organizational** — DPA/SCCs ([`../legal/data-processing-addendum.md`](../legal/data-processing-addendum.md)),
  subprocessor transparency, incident-response process
  ([`security-policies/incident-response-policy.md`](security-policies/incident-response-policy.md)).

## 5. Residual risk & decision

| Field | Entry |
|---|---|
| Residual risk level (after measures) | `[TBD]` |
| Is residual risk acceptable? | `[TBD]` |
| Prior consultation with supervisory authority required (Art. 36)? | `[TBD]` — required if residual high risk cannot be mitigated |

## 6. Sign-off

| Role | Name | Date | Signature |
|---|---|---|---|
| DPO (or equivalent) | `[TBD]` | `[TBD]` | `[TBD]` |
| Controller representative | `[TBD]` | `[TBD]` | `[TBD]` |
| Review date (next) | `[TBD]` | | |

---

## Appendix — one worked example row

A filled-in illustrative line, to show the intended shape (replace with your real assessment):

| Field | Worked example |
|---|---|
| Processing activity | "Store and serve customer-support tickets (containing end-user name/email) via the Grobase API for a SaaS helpdesk" |
| Nature/scope | CRUD on a `tickets` table, ~50k subjects, EU-hosted single region |
| Lawful basis | Art. 6(1)(b) performance of a contract (the helpdesk's ToS) |
| Top risk | Cross-tenant exposure of ticket contents → **mitigated** by per-request isolation (`m46`) + ABAC column mask on the email field (`m136`/`m135`) |
| Erasure path | End-user "delete my account" → controller calls hard-erase (`m105`); receipt logged in the audit chain (`m104`) |
| Residual risk | Low — isolation gate-proven; controller accepts |

See also: [`gdpr-article-matrix.md`](gdpr-article-matrix.md) (Art. 35 row),
[`gdpr-ropa.md`](gdpr-ropa.md) (Art. 30 record).
