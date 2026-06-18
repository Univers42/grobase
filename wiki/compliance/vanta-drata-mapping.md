# Vanta / Drata automated-test mapping

> **What this is.** A row-per-test cross-walk from the **automated tests** a
> compliance-automation platform (Vanta / Drata / Secureframe) runs continuously
> → the **Grobase control** that satisfies it → the **in-repo evidence** (a
> re-runnable gate `mNN`, a `posture.json` control id, or a `wiki/` doc) the
> platform's evidence-upload can point at.
>
> **Honesty bar (kernel rule #4).** A row is only "satisfied by code" when a real
> gate or source path proves it. The rest are **human atoms** — they need a cloud
> account, an org/IdP, a contract, or a calendar window, and are marked
> **`config`** with the atom named. Source of truth for any control's status is
> `config/trust/posture.json`; this doc maps tests onto it, it does not restate status.

This is the operational companion to [`auditor-handoff.md`](./auditor-handoff.md) §5
(which gives the short version) — here every common platform test gets its own row,
its satisfier, and an explicit **code vs config** verdict.

---

## How to read the "Satisfied by" column

| Marker | Meaning |
|---|---|
| **code** | A re-runnable in-repo gate / source path proves the control. The platform uploads the gate output (or links the source) as the evidence. |
| **config** | The control is real but its *evidence* is produced by cloud/org configuration outside this repo (an IdP, a cloud provider setting, a signed contract). This is a **human atom** — named in the row. |
| **code + config** | The mechanism is in code (and gate-proven), but a *live* deployment artifact (a real IdP, a real KMS, a real backup target) is the customer/operator atom. |

---

## 1. Access control & authentication

| Vanta / Drata test (typical) | Grobase control | In-repo evidence | Satisfied by |
|---|---|---|---|
| **MFA enforced** for privileged/admin access | Phishing-resistant WebAuthn passkeys + SSO MFA delegated to the IdP | gate `m107` (passkeys) · `m110` (SSO/OIDC) · posture `enterprise-passkeys`, `sso-oidc` | **code + config** — passkey ceremony is gate-proven; MFA *policy enforcement* for human operators is set in the live IdP (Okta/Entra/Auth0/Google) — that IdP is a customer atom |
| **SSO / SAML / OIDC enabled** | Per-tenant OIDC IdP connections (auth-code flow, id_token HS256 + RS256/JWKS, single-use state, sealed client secret) | gate `m110` · posture `sso-oidc` · migration `053` | **code + config** — mechanism gate-proven against a mock IdP; a *live* IdP is the customer atom |
| **RBAC / least privilege** | Org model (members/invites/roles) + fine-grained ABAC PDP (conditions, per-instance, column-mask) + per-request owner-scoping | gate `m103` (orgs-rbac) · `m135`/`m136`/`m137`/`m139` (ABAC) · posture `organizations-rbac`, `abac-pdp` | **code** |
| **Access provisioning / deprovisioning (joiner-mover-leaver)** | SCIM 2.0 (RFC 7644) user/group lifecycle into the org-members backend | gate `m111` (scim) · posture `scim-provisioning` · migration `054` | **code + config** — lifecycle gate-proven incl. revocation + cross-tenant wall; the *source IdP* that drives SCIM is the customer atom |
| **Access reviews / periodic recertification** | Org membership + role data is the queryable population for a review; the change is auditable | posture `organizations-rbac` + tamper-evident audit (`m104`) | **config** — the *cadence + sign-off* of the review is an org/HR process, not code (access-control-policy.md defines it) |
| **Strong password policy** | High-entropy machine credentials use fast hash (SHA-256/HMAC), never password hashes; human auth delegated to IdP/GoTrue | [`../security-audit.md`](../security/security-audit.md) + posture `abac-pdp` | **config** — human password policy is the IdP/GoTrue setting; the *secret-hashing discipline* is code |
| **Idle session / session timeout** | Sessions are GoTrue-shaped, short-lived; ABAC conditions support AAL/time-window | posture `enterprise-passkeys` (session mint) | **config** — session TTL is an operator/IdP setting |

## 2. Encryption

| Vanta / Drata test (typical) | Grobase control | In-repo evidence | Satisfied by |
|---|---|---|---|
| **Encryption in transit (TLS)** | Under `SECURITY_MODE=max`, MSSQL verifies TLS + refuses insecure DSNs; mongo/redis insecure params rejected; CA-pin via `DATA_PLANE_TLS_CA_FILE` | [`../security-audit-asvs.md`](../security/security-audit-asvs.md) · posture `encryption-in-transit` | **code + config** — engine TLS enforced in `max`; **edge TLS is operator-provided** (honest partial: Postgres `sslmode=require` is accept-any outside `max`) |
| **Encryption at rest** | Disk/volume encryption is operator/host responsibility today; per-tenant encrypted-at-rest backups are roadmap | posture `encryption-at-rest` (**planned**) | **config** — host/cloud disk encryption is the operator atom; not yet a Grobase-enforced control |
| **Encryption keys managed (CMEK/BYOK/KMS)** | Per-mount connection strings envelope-encrypted: AES-256-GCM DEK wrapped by a customer-controlled external-KMS KEK (Vault Transit); revoking the KEK crypto-shreds | gate `m123` (cmek-envelope) · posture `cmek-byok` | **code + config** — seal/unwrap + crypto-shred gate-proven with Vault Transit; a *customer's KMS* is their atom |
| **Secrets management (no hardcoded secrets)** | Vault-backed secrets, `credential_ref{provider:vault}`, dynamic short-lived DB creds; gate forbids plaintext mounts | gate `m121` (vault credential-ref enforcement) · posture `secrets-management` | **code** (honest partial: plaintext `DATA_PLANE_MOUNTS` not yet forbidden *outside* `max` — enforce Vault refs in prod) |

## 3. Audit, logging & monitoring

| Vanta / Drata test (typical) | Grobase control | In-repo evidence | Satisfied by |
|---|---|---|---|
| **Audit logging enabled / immutable** | Hash-chained per-tenant audit log; the chain is recomputable so any insert/edit/delete is detectable | gate `m104` (audit-chain) · posture `tamper-evident-audit` | **code** |
| **Centralized log retention** | Per-tenant audit entries persisted; data-retention policy defines retention | gate `m104` + [`security-policies/data-retention-policy.md`](./security-policies/data-retention-policy.md) | **code + config** — capture is code; *retention duration + log aggregation* is an operator setting |
| **Continuous control monitoring** | SOC2-lite collector seals signed snapshots of CI-gate results, access posture, change-mgmt trail (the sampled population) | gate `m108` (soc2-evidence) · posture `soc2-lite-evidence` · migration `051`/`064` | **code** (flag `SOC2_EVIDENCE_ENABLED`; the *external SOC 2 opinion* over the window is the auditor atom) |
| **Alerting / anomaly detection** | Per-tenant abuse/KYC guard + edge rate-limiting (Kong) + staged quotas + spend caps | gate `m90` (abuse-guard) · `m89` (spend-caps) · `m120` (data-plane enforcement) · posture `abuse-guard`, `spend-caps` | **code + config** — enforcement gate-proven; *alert routing/on-call* is an ops integration |

## 4. Data protection & privacy (GDPR)

| Vanta / Drata test (typical) | Grobase control | In-repo evidence | Satisfied by |
|---|---|---|---|
| **Data deletion / right-to-erasure process** | Per-tenant scoped hard delete of a subject's data + verifiable erasure receipt; another tenant never touched | gate `m105` (hard-erase) · posture `hard-erase` · migration `048` | **code** |
| **Data export / portability** | Engine-neutral JSON bundle of ONE tenant's data + manifest (tables, row counts, sha256), strictly tenant-scoped | gate `m109` (tenant-export) · posture `data-portability-export` | **code** |
| **Records of Processing (Art. 30)** | RoPA with processor + controller views | [`gdpr-ropa.md`](./gdpr-ropa.md) · [`gdpr-article-matrix.md`](./gdpr-article-matrix.md) | **code + config** — template is in-repo; per-deployment fields are controller-filled |
| **DPIA performed where required (Art. 35)** | DPIA template | [`dpia-template.md`](./dpia-template.md) | **config** — the *assessment* is a controller activity |
| **DPA in place (Art. 28)** | Data Processing Addendum template | [`../legal/data-processing-addendum.md`](../legal/data-processing-addendum.md) | **config** — **counsel atom**: template → binding agreement |
| **Subprocessor list maintained** | Subprocessors register | [`../legal/subprocessors.md`](../legal/subprocessors.md) | **config** — kept current per deployment |
| **Privacy policy published** | Privacy policy template | [`../legal/privacy-policy.md`](../legal/privacy-policy.md) | **config** — publish + counsel review |

## 5. Vulnerability & supply-chain management

| Vanta / Drata test (typical) | Grobase control | In-repo evidence | Satisfied by |
|---|---|---|---|
| **Vulnerability scanning in CI** | SCA/SAST/secret/container scans: SEMGREP + npm audit, cargo-audit on both Rust workspaces | [`../security-audit.md`](../security/security-audit.md) · `make baas-security-scan` · `scripts/security/run-security-scans.sh` | **code** |
| **DAST / dynamic scanning** | OWASP ZAP baseline against the live WAF/Kong stack | `scripts/verify/zap-baseline.sh` | **code + config** — script is in-repo; needs the stack up + a schedule |
| **Dependency / SBOM management** | Frozen lockfiles everywhere; `npm ci --ignore-scripts`; pnpm `minimum-release-age` + `onlyBuiltDependencies` allowlist | posture `supply-chain` · `scripts/security/audit-deps.sh` | **code** |
| **Penetration testing performed** | Documented scope / RoE; the test itself is external | [`pentest-scope.md`](./pentest-scope.md) · auditor-handoff §7 | **config** — **independent pen-test atom** (the strongest single due-diligence artifact) |
| **Patch / remediation SLAs** | Risk register tracks residuals + treatment; findings feed it | [`risk-register.md`](./risk-register.md) | **config** — the *remediation cadence* is an ops process |

## 6. Network & infrastructure

| Vanta / Drata test (typical) | Grobase control | In-repo evidence | Satisfied by |
|---|---|---|---|
| **Network access restricted / firewall** | Per-tenant IP allowlist enforced at the control plane (+ flag-off parity) | gate `m106` (ip-allowlist) · posture `network-access-control` | **code** (this is access control, not a full L7 WAF) |
| **WAF deployed** | Managed L7 WAF at the hosting edge (managed-cloud); operator-supplied for self-host | posture `waf` (**planned**) · [`../operations-runbook.md`](../operations/operations-runbook.md) | **config** — edge/hosting atom; not yet a Grobase-enforced control |
| **Network segmentation** | Per-plane network segmentation overlay (data/control/realtime networks) | `docker-compose.netseg.yml` | **code + config** — overlay is in-repo; deployment topology is operator-chosen |
| **DDoS / rate limiting** | Edge rate-limiting (Kong) + per-tenant quotas/spend caps | gate `m90` · `m89` · posture `abuse-guard` | **code + config** |

## 7. Availability, backup & change management

| Vanta / Drata test (typical) | Grobase control | In-repo evidence | Satisfied by |
|---|---|---|---|
| **Backups configured** | Logical per-tenant backup/restore (schema-per-tenant), atomic Go-native COPY | gate `m87` (backup) · `m47` (restore-verify) · `m99` | **code + config** — mechanism gate-proven; a *real backup target + schedule* is the operator atom |
| **Recovery / restore tested** | Restore is proven (dump→drop→restore→checksum) on a scratch DB; tenant data untouched | gate `m47` (`make restore-verify`) | **code** |
| **Uptime / availability SLA monitored** | Per-tier uptime targets defined | posture `sla-uptime` (**planned**) · [`../legal/sla.md`](../legal/sla.md) | **config** — **uptime-probe atom**: no SLA is enforceable until the C7 probe writes durable availability samples (stated honestly, not advertised live) |
| **Change management / code review** | Change-mgmt policy + the framework-cross-walk gate keeps docs honest; shadow→parity→cutover discipline | gate `m143` · [`security-policies/change-management-policy.md`](./security-policies/change-management-policy.md) · [`../../.claude/instructions.md`](../../.claude/instructions.md) | **code + config** — gate + policy in-repo; *branch-protection / required-reviewer* settings are the VCS-host config atom |
| **BCP / DR plan** | BCP/DR policy | [`security-policies/bcp-dr-policy.md`](./security-policies/bcp-dr-policy.md) | **config** — adopt + exercise |
| **Risk assessment maintained** | Risk register (ISO clause 6 / SOC 2 CC3), seeded from real residuals | [`risk-register.md`](./risk-register.md) | **code + config** — register in-repo; the *review cadence* is governance |
| **Vendor / subprocessor risk management** | Vendor/supplier policy + subprocessor register | [`security-policies/vendor-supplier-policy.md`](./security-policies/vendor-supplier-policy.md) · [`../legal/subprocessors.md`](../legal/subprocessors.md) | **config** — per-deployment vendor reviews |
| **Incident response plan + tested** | Incident-response policy | [`security-policies/incident-response-policy.md`](./security-policies/incident-response-policy.md) | **config** — adopt + run a tabletop |
| **Policies adopted & acknowledged** | The ISMS policy set | [`security-policies/00-index.md`](./security-policies/00-index.md) | **config** — management adoption + employee acknowledgement |

---

## Summary: what's code vs what's a human atom

**Satisfied by code today (a gate proves it, upload the gate output):**
audit immutability (`m104`), erasure (`m105`), portability (`m109`), tenant
isolation (`m46`), ABAC/RBAC (`m103`/`m135`-`m139`), IP allowlist (`m106`),
passkeys (`m107`), SSO/SCIM mechanism (`m110`/`m111`), CMEK/BYOK (`m123`),
secrets/Vault refs (`m121`), backup/restore (`m87`/`m47`), continuous evidence
(`m108`), supply-chain & vuln scanning in CI (`make baas-security-scan`), the
honest framework cross-walks (`m143`/`m141`).

**Human / config atoms (the platform marks these "needs evidence" — they need a
person, a contract, or a cloud account):** a *live* IdP for SSO/SCIM + MFA
policy, a *customer* KMS for CMEK, host/cloud disk encryption-at-rest, an edge
WAF, the C7 uptime probe + status page, the DPA/ToS/privacy → binding via
counsel, periodic access reviews + their sign-off, the incident-response &
BCP/DR tabletops, branch-protection settings, and — the single biggest one — an
**independent penetration test** ([`pentest-scope.md`](./pentest-scope.md)). The
full enumerated list lives in [`auditor-handoff.md`](./auditor-handoff.md) §7.

> **Bottom line.** Wire each Vanta/Drata test to the gate or doc above; the
> code-backed rows pass with a gate upload, and the config rows are the honest,
> enumerated work a real deployment + the business does — none invented, none hidden.
