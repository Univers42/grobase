# Grobase Security Policy Set (ISMS) — Index

> **POLICY DRAFTS — review by counsel/management before formal adoption.** This is the thin policy
> set an ISMS (ISO/IEC 27001 clauses 5/7) and a SOC 2 audit expect. Each policy is intentionally ~1
> page and **points to the enforced control or runbook** that gives it teeth — Grobase's posture is
> that *policy without an enforcing control is just paper* (kernel rule #4). The controls these
> policies reference are gate-proven; the policies themselves are pending formal adoption.

These map to ISO/IEC 27001:2022 Annex A organizational/people controls (A.5.1, A.5.2, etc. — see
[`../iso27001-soa.md`](../iso27001-soa.md)) and the SOC 2 CC families (CC1/CC2/CC5).

| # | Policy | Primary Annex A / TSC | Enforcing control |
|---|---|---|---|
| 1 | [`infosec-policy.md`](infosec-policy.md) | A.5.1 / CC1 | the whole ISMS + gate battery |
| 2 | [`access-control-policy.md`](access-control-policy.md) | A.5.15–A.5.18 / CC6 | gate `m103`, `m106`, `m107`, `m110`, `m111`, `m136` |
| 3 | [`incident-response-policy.md`](incident-response-policy.md) | A.5.24–A.5.27 / CC7.3–7.5 | [`../../operations-runbook.md`](../../operations-runbook.md), gate `m104` |
| 4 | [`change-management-policy.md`](change-management-policy.md) | A.8.32 / CC8.1 | the gate harness + CI |
| 5 | [`vendor-supplier-policy.md`](vendor-supplier-policy.md) | A.5.19–A.5.22 / CC9.2 | [`../../legal/subprocessors.md`](../../legal/subprocessors.md) + supply-chain CI |
| 6 | [`bcp-dr-policy.md`](bcp-dr-policy.md) | A.5.29–A.5.30 / CC9.1, A1 | gate `m87`, `m99`, [`../../sla-draft.md`](../../sla-draft.md) |
| 7 | [`data-retention-policy.md`](data-retention-policy.md) | A.5.12, A.8.10 / C1, Privacy | gate `m105` + [`../gdpr-ropa.md`](../gdpr-ropa.md) |

**Governance:** these policies are owned by management, reviewed at least annually (and on material
change), and adopted via the company's normal approval process. Adoption status and approver are
recorded once counsel/management sign off (the ISMS clause 5 commitment).
