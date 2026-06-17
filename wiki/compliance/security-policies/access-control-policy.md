# Access Control Policy

> **POLICY — review by counsel/management before formal adoption.** Points to enforced controls.

## Purpose & scope
Govern how access to information and systems is granted, reviewed, and revoked, for both platform
identities (tenants, org members, API keys, service-to-service) and staff. (ISO/IEC 27001 Annex A
A.5.15–A.5.18; SOC 2 CC6.)

## Policy
- **Authentication.** Phishing-resistant auth (WebAuthn passkeys) and enterprise SSO (OIDC) are the
  preferred mechanisms; API keys are high-entropy and verified by a single authority; JWT
  verification is pinned to one algorithm (no alg-confusion). Enforced: gate `m107` (passkeys),
  gate `m110` (SSO/OIDC).
- **Authorization.** Access is least-privilege via the fine-grained ABAC PDP (conditions, column
  masks, per-instance grants) and organization roles; owner-scoping is re-stamped on **every**
  request, not held in pool state. Enforced: gate `m136`, gate `m103`, gate `m46`.
- **Provisioning & de-provisioning.** User lifecycle (joiners/movers/leavers) is automated via SCIM
  2.0 into the org-members backend; revocation is immediate. Enforced: gate `m111`.
- **Network access.** Per-tenant IP allowlists restrict where access originates. Enforced:
  gate `m106`.
- **Staff access.** Staff access to production and source follows least-privilege, MFA, and the
  joiner/mover/leaver process; off-premises devices, clear-screen, and asset return are covered here
  (Annex A A.6.5, A.6.7, A.7.7, A.7.9, A.8.1, A.8.18).

## Review
Access rights reviewed at least annually; changes flow through change management
([`change-management-policy.md`](./change-management-policy.md)). Exceptions are recorded in the risk
register ([`../risk-register.md`](../risk-register.md)).
