# Data Retention & Disposal Policy

> **POLICY — review by counsel/management before formal adoption.** Points to enforced controls.

## Purpose & scope
Define how long information is retained and how it is securely disposed of. (ISO/IEC 27001 Annex A
A.5.12, A.5.13, A.8.10; SOC 2 Confidentiality/Privacy; GDPR storage-limitation principle Art. 5(1)(e)
and erasure Art. 17.)

## Policy
- **Retention is controller-defined.** For tenant data, the **controller** sets the retention period
  per their lawful basis and purpose; Grobase is data-type-agnostic and does not impose a retention
  schedule on controller data. The processor and controller retention records are in
  [`../gdpr-ropa.md`](../gdpr-ropa.md).
- **Disposal is enforced & verifiable.** Erasure is a scoped hard delete with a tamper-evident
  receipt cross-linked to the audit chain, and another tenant is never touched — gate `m105`
  (migration `048_tenant_erasure.sql`). For external-connection secrets, revoking the customer's
  CMEK KEK crypto-shreds the data — gate `m123`.
- **Grobase's own data (as controller).** Account/billing/auth data is retained for the contractual
  plus statutory period, then deleted or anonymised on account closure (controller view in
  [`../gdpr-ropa.md`](../gdpr-ropa.md)).
- **Test data.** Tests use synthetic/seeded data; production personal data is not used in test
  environments (A.8.33).
- **Backups.** Backup retention follows the BCP/DR policy ([`bcp-dr-policy.md`](./bcp-dr-policy.md));
  erasure obligations extend to backups per the controller's documented process.

## Review
At least annually and on any change to legal/contractual retention requirements.
