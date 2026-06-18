# Terms of Service

> **TEMPLATE — review by counsel before use; not legal advice.** This document is
> a starting scaffold for the Grobase managed-cloud offering. It has not been
> reviewed by a lawyer. Do not publish or rely on it as-is. Bracketed `[…]` fields
> must be filled in; numbers (e.g. uptime) must come from the measured SLA, not
> from this template.

**Effective date:** `[DATE]`
**Provider:** `[LEGAL ENTITY NAME, ADDRESS]` ("Grobase", "we", "us").

## 1. Agreement

These Terms of Service ("Terms") govern your access to and use of the Grobase
managed-cloud Backend-as-a-Service ("Service"). By creating an account, you agree
to these Terms. If you are entering into these Terms on behalf of an organization,
you represent that you are authorized to bind that organization.

The OSS self-hosted edition of Grobase is licensed separately under `[OSS LICENSE]`
and is **not** governed by these Terms.

## 2. Accounts and acceptable use

- You are responsible for your account, your API keys, and all activity under them.
- You must keep API keys confidential. Keys can be rotated/revoked from the tenant
  self-service console.
- Use of the Service is subject to the [Acceptable Use Policy](./acceptable-use-policy.md).

## 3. Plans, usage, and billing

- Paid plans (basic, essential, pro, max) are billed per the published pricing and
  measured usage. Usage metering (requests, rows, storage, realtime, functions) is
  recorded per tenant. See the [Privacy Policy](./privacy-policy.md) for what we
  collect and the [Data Processing Addendum](./data-processing-addendum.md) for how
  we process Customer Data.
- Billing is processed by `[Stripe, when billing is enabled]`. We do not store full
  card details.
- The free / nano tier is best-effort with no SLA.

## 4. Service levels

Service-level commitments for paid tiers are stated in the [SLA](./sla.md), which
references measured availability. **No uptime number is invented in this document;**
the SLA is enforceable only once the operational uptime probe is live (see SLA §1).

## 5. Customer Data and ownership

- You retain all rights to data you submit to the Service ("Customer Data").
- You can export your data at any time (GDPR Art. 20 portability is supported; see
  the [trust center](../security/trust-center.md), control `data-portability-export`).
- We act as a processor of Customer Data; the [DPA](./data-processing-addendum.md)
  governs that relationship.

## 6. Security

We maintain technical and organizational measures described in the
[trust center](../security/trust-center.md). Each control there is tagged with the evidence
that proves it (a gate id or a wiki doc). No security claim in our materials is made
without such evidence.

## 7. Suspension and termination

We may suspend or terminate access for breach of these Terms, the AUP, non-payment,
or to protect the Service or other customers. On termination you may export your
data for `[N]` days, after which it is deleted per our retention policy.

## 8. Warranties and disclaimers

THE SERVICE IS PROVIDED "AS IS" EXCEPT AS EXPRESSLY STATED. `[Counsel: insert the
warranty disclaimer and limitation-of-liability appropriate to your jurisdiction.]`

## 9. Limitation of liability

`[Counsel: insert a limitation-of-liability cap and exclusions.]`

## 10. Changes

We may update these Terms; material changes will be notified `[N]` days in advance.

## 11. Governing law

`[Counsel: governing law + venue.]`

## 12. Contact

`[legal@EXAMPLE.com]`
