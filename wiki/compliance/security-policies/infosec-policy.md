# Information Security Policy

> **POLICY — review by counsel/management before formal adoption.** Thin by design; it points to the
> enforced controls rather than restating them.

## Purpose & scope
Establish management's commitment to protecting the confidentiality, integrity, and availability of
information processed by Grobase and its customers. Scope: the Grobase platform (application/control/
data/realtime planes), the managed-cloud offering, supporting CI/CD, and the staff who operate them.
Self-host customers operate their own instance under their own ISMS; Grobase supplies the controls
and evidence. (ISO/IEC 27001 clause 4 — context & scope; Annex A A.5.1.)

## Principles (the binding kernel rules)
- **Security by default** — Vault secrets; ABAC PDP; RLS/owner-scope enforced per request;
  high-entropy secrets fast-hashed, password-class secrets Argon2id.
- **Measured, not claimed** — every security claim cites an in-repo artifact (a gate `mNN`, a
  migration, a CI job). No invented assurance.
- **Least change, reversible first** — behaviour changes are flag-gated OFF by default; the baseline
  stays byte-parity.

## Roles & responsibilities (A.5.2)
Management owns the ISMS and resourcing; engineering owns control implementation and the gate
battery; operations owns monitoring, incident response, and backups. Specific role assignments and
the security event-reporting channel are recorded in [`access-control-policy.md`](./access-control-policy.md)
and [`incident-response-policy.md`](./incident-response-policy.md).

## How this policy is enforced
The control set is **gate-proven and continuously evaluated**: the enterprise gate battery
(`run-gate-battery.sh --enterprise`), the `m108` continuous-evidence collector, and the `m143`
matrix gate keep policy and reality aligned. The risk register ([`../risk-register.md`](../risk-register.md))
drives treatment; the SoA ([`../iso27001-soa.md`](../iso27001-soa.md)) records applicability.

## Review
At least annually and on material change; nonconformities flow to the risk register and the
residuals runbook ([`../../security-residuals-runbook.md`](../../security/security-residuals-runbook.md)).
