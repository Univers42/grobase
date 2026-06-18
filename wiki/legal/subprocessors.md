# Subprocessors

> **TEMPLATE — review by counsel before use; not legal advice.** This list must
> reflect the **real** deployment. Entries marked `[TBD]` mean a vendor has not been
> chosen for the managed-cloud go-live — fill them in before publishing, and keep this
> list in sync with the [DPA](./data-processing-addendum.md) §6 and the
> [Privacy Policy](./privacy-policy.md) §4.

A subprocessor is a third party engaged by the Processor to process Customer Data.
The Grobase stack is intentionally small; the table below lists the components that
would handle Customer Data in a managed-cloud deployment.

| Subprocessor | Role | Processes Customer Data? | Location | Status |
|---|---|---|---|---|
| **PostgreSQL** (control-plane + default tenant engine) | primary datastore | yes | `[hosting region]` | core stack |
| **MinIO / object storage** | file storage, backups | yes (files + backup artifacts) | `[hosting region]` | core stack |
| **Stripe** | payment processing | no Customer Data (billing identifiers + payment data only) | US/EU | only when `BILLING_ENABLED` |
| **Hosting / IaaS provider** | compute, network, disk | yes (data at rest on their infrastructure) | `[region]` | `[TBD — provider not yet selected]` |
| **Email/SMTP provider** | transactional email (auth, invites) | account emails only | `[region]` | `[TBD — Mailpit in dev; real provider TBD]` |
| **Error/telemetry processor** | logs, error traces | possibly incidental | `[region]` | `[TBD — only if an external observability vendor is used]` |
| **CDN / edge / WAF** | request routing, L7 protection | request metadata | `[region]` | `[TBD — see trust center control `waf` (planned)]` |

Notes:

- The **self-hosted OSS edition** has **no** Grobase subprocessors — the operator runs
  everything; this list applies only to the managed-cloud offering.
- Engines other than Postgres (MySQL, MongoDB, MSSQL, SQLite, Redis, HTTP, DynamoDB)
  are tenant-chosen mounts; if a tenant points Grobase at an external managed database,
  that database is the **Controller's** subprocessor, not Grobase's.
- Update this table whenever a `[TBD]` is resolved or a vendor changes, and notify
  Controllers per [DPA](./data-processing-addendum.md) §6.
