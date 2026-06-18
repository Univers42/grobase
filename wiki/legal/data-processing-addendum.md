# Data Processing Addendum (DPA)

> **TEMPLATE — review by counsel before use; not legal advice.** Scaffold for GDPR
> Art. 28 processor terms. Not lawyer-reviewed. The SCC module selection, liability,
> and audit clauses MUST be set by counsel. The subprocessor list MUST match
> [subprocessors.md](./subprocessors.md).

This Data Processing Addendum ("DPA") forms part of the
[Terms of Service](./terms-of-service.md) between `[CUSTOMER]` ("Controller") and
`[GROBASE LEGAL ENTITY]` ("Processor") and applies where the Processor processes
Personal Data on behalf of the Controller (GDPR Art. 28).

## 1. Definitions

"Personal Data", "processing", "controller", "processor", "data subject",
"supervisory authority" have the meanings in the GDPR. "Customer Data" is data the
Controller submits to the Service.

## 2. Roles

The Controller is the controller of Personal Data within Customer Data; the Processor
is a processor and processes Personal Data only on documented instructions from the
Controller (these terms + the Controller's use of the Service).

## 3. Subject matter, duration, nature, purpose

- **Subject matter:** provision of the Grobase managed Backend-as-a-Service.
- **Duration:** the term of the Agreement plus the retention window in the
  [Privacy Policy](./privacy-policy.md).
- **Nature & purpose:** storage, querying, realtime delivery, functions execution,
  and backup of Customer Data, as directed by the Controller.
- **Categories of data subjects / data:** as determined by the Controller's use.

## 4. Processor obligations (Art. 28(3))

1. Process Personal Data only on documented instructions.
2. Ensure persons authorized to process are bound by confidentiality.
3. Implement appropriate technical and organizational measures (Art. 32) — see the
   [trust center](../security/trust-center.md); each measure is evidence-backed.
4. Engage subprocessors only per §6 below.
5. Assist the Controller with data-subject requests insofar as possible — the Service
   provides export (Art. 20, gate m109) and erasure (Art. 17, gate m105) tooling.
6. Assist with security, breach notification, DPIAs, and consultation (Arts. 32–36).
7. Delete or return Personal Data at the end of provision, at the Controller's choice.
8. Make available information to demonstrate compliance and allow audits `[scope/notice
   per counsel]`.

## 5. Security measures (Art. 32)

The Processor maintains the controls in the [trust center](../security/trust-center.md),
including tamper-evident audit logging (m104), per-tenant isolation (m46),
encryption in transit `[partial — see trust center control encryption-in-transit]`,
and access controls. Per-tenant **encryption at rest** is `[planned — see trust
center control encryption-at-rest]`; this DPA must not assert it as implemented until
the trust center marks it so.

## 6. Subprocessors

The Controller authorizes the subprocessors in [subprocessors.md](./subprocessors.md).
The Processor will give `[N]` days' notice of new subprocessors and a right to object.

## 7. International transfers

Where Personal Data is transferred outside the EEA/UK, the parties rely on the
**Standard Contractual Clauses** (Commission Implementing Decision (EU) 2021/914),
`[module — counsel to select; typically Module Two: controller-to-processor]`, and
any UK Addendum / Swiss amendments as applicable. SCC annexes (parties, processing
description, technical measures) cross-reference §§3–5 and the subprocessor list.

## 8. Breach notification

The Processor will notify the Controller without undue delay after becoming aware of
a Personal Data breach, with the information required by Art. 33(3) as it becomes
available.

## 9. Liability, audits, term

`[Counsel: liability allocation, audit mechanics, order of precedence with the main
Agreement, governing law.]`
