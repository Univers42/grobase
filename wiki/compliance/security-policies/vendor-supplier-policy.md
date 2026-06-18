# Vendor & Supplier Security Policy

> **POLICY — review by counsel/management before formal adoption.** Points to enforced controls.

## Purpose & scope
Manage information-security risk arising from suppliers, subprocessors, and the ICT supply chain.
(ISO/IEC 27001 Annex A A.5.19–A.5.22; SOC 2 CC9.2.)

## Policy
- **Subprocessor transparency.** All managed-cloud subprocessors (hosting, object storage, email,
  payments) are listed, with role and region, in [`../../legal/subprocessors.md`](../../legal/subprocessors.md)
  (template — counsel review required). **Self-host has no Grobase-operated subprocessor** — the
  customer owns the data location.
- **Supplier agreements.** Security and data-protection obligations flow down via the DPA
  ([`../../legal/data-processing-addendum.md`](../../legal/data-processing-addendum.md), Art. 28) and
  SCC references for transfers (Art. 46).
- **ICT supply-chain hardening (the enforced part).** Dependencies are locked and scanned: frozen
  lockfiles everywhere, `npm ci --ignore-scripts`, pnpm `minimum-release-age` + `onlyBuiltDependencies`
  allowlist, digest pinning, and **blocking** cargo-audit / govulncheck / npm-audit / Trivy / Semgrep
  / secret scans in CI. See [`../../security-audit.md`](../../security/security-audit.md) (supply-chain) and
  [`../iso27001-soa.md`](../iso27001-soa.md) A.5.21.
- **Monitoring & review.** Subprocessor changes trigger a RoPA update ([`../gdpr-ropa.md`](../gdpr-ropa.md));
  accepted dependency residuals (e.g. the tiberius-only advisories) are tracked in `audit-deps.sh` /
  `.trivyignore` so a *new* vuln still fails the gate.

## Review
At least annually and on onboarding any new supplier/subprocessor; supplier risk feeds the risk
register ([`../risk-register.md`](../risk-register.md)).
