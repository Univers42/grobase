# Privacy Policy

> **TEMPLATE — review by counsel before use; not legal advice.** Scaffold for the
> Grobase managed-cloud offering. Not lawyer-reviewed. Bracketed `[…]` fields must
> be completed; the subprocessor list must match [subprocessors.md](subprocessors.md).

**Effective date:** `[DATE]`
**Controller (for account data):** `[LEGAL ENTITY NAME, ADDRESS]`.

For **Customer Data** that you submit through the Service, Grobase acts as a
**processor**; the [Data Processing Addendum](data-processing-addendum.md) governs
that processing. This Privacy Policy describes data Grobase collects as a
**controller** to operate the Service (account, billing, telemetry).

## 1. What we collect

| Category | Examples | Purpose |
|---|---|---|
| Account data | name, email, organization | authentication, support, billing |
| Billing data | plan, invoices, `[Stripe]` customer id | payment, tax |
| Usage metering | per-tenant request/row/storage/realtime/function counts | billing, capacity, abuse prevention |
| Operational telemetry | logs with `tenant_id` as a field (never a high-cardinality metric label), error traces | reliability, security |
| Security events | auth events, IP allowlist hits, audit log | account security, incident response |

We do **not** sell personal data.

## 2. Customer Data

Data you store in your project (rows, files, realtime messages) is **Customer Data**.
We process it only to provide the Service, under the [DPA](data-processing-addendum.md).
We do not access Customer Data except as needed to operate, secure, or support the
Service, or as you instruct.

## 3. Legal bases (GDPR)

`[Counsel: confirm legal bases — contract performance, legitimate interest,
consent where required.]`

## 4. Subprocessors and transfers

We use the subprocessors listed in [subprocessors.md](subprocessors.md). International
transfers rely on `[Standard Contractual Clauses / other mechanism]` as referenced in
the DPA.

## 5. Retention

- Account/billing data: retained for the life of the account plus `[N]` for tax/legal.
- Customer Data: retained while your account is active; deletable on request
  (GDPR right to erasure is supported — see the [trust center](../trust-center.md),
  control `hard-erase`, gate m105) and exportable (control `data-portability-export`,
  gate m109).
- Usage metering / telemetry: retained `[N days/months]`.

## 6. Your rights

Access, rectification, erasure, portability, restriction, objection — exercisable via
`[privacy@EXAMPLE.com]` and, for portability/erasure, the self-service console.

## 7. Security

See the [trust center](../trust-center.md). Each control is evidence-backed.

## 8. Children

The Service is not directed to children under `[16/13]`.

## 9. Changes & contact

We will notify material changes. Contact: `[privacy@EXAMPLE.com]`,
DPO `[if applicable]`.
