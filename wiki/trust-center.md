# Grobase Trust Center (Track-D D4.6)

> **Ethos (kernel #4):** a claim without an artifact is not on this page. Every
> control below is tagged **implemented · partial · planned**, and an *implemented*
> control **must** cite the numbered gate (`mNN`) or wiki doc that proves it. An
> unproven claim is marked partial/planned — never "implemented" without evidence.

This page is the **human-readable half** of the trust posture. The
**machine-readable half** is `mini-baas-infra/config/trust/posture.json`, served at
`GET /v1/trust` and `GET /v1/trust/controls` when `TRUST_CENTER_ENABLED` is on
(flag-gated **OFF** by default — byte-parity with today when off). The two are kept
in sync; the m112 gate proves the endpoint reflects the file, and the
`internal/trust` package test fails if any control claims *implemented* with no
evidence. **If this page and the JSON ever disagree, the JSON is canonical** (it is
the source the API serves and the gate checks).

---

## 1. Posture at a glance

| Control | Category | Status | Evidence |
|---|---|---|---|
| Tamper-evident tenant audit log | audit-and-logging | **implemented** | gate **m104** |
| GDPR hard-erase (right to erasure) | data-protection | **implemented** | gate **m105** (migration 048) |
| Data export / portability (GDPR Art. 20) | data-protection | **implemented** | gate **m109** |
| SOC2-lite continuous evidence collector | compliance | **partial** | gate **m108** (migration 051) |
| Formal SOC 2 Type II report | compliance | **planned** | external auditor required |
| Per-tenant data isolation (per-request RLS) | isolation | **implemented** | gate **m46** |
| Encryption in transit (TLS to engines + edge) | encryption | **partial** | `security-audit-asvs.md` |
| Encryption at rest (per-tenant) | encryption | **planned** | `security-audit-asvs.md` |
| Secrets management (Vault, dynamic DB creds) | encryption | **partial** | `security-audit.md` |
| ABAC PDP + owner-scoped writes | access-control | **implemented** | `orgs-rbac-design.md` |
| Network access control / IP allowlist | network | **implemented** | gate **m106** |
| Web Application Firewall (L7) | network | **planned** | `operations-runbook.md` |
| Phishing-resistant auth (WebAuthn passkeys) | access-control | **implemented** | gate **m107** (migration 050) |
| Organizations / teams / members / RBAC | access-control | **implemented** | gate **m103** |
| Vulnerability disclosure (security.txt) | compliance | **partial** | `status-sla.md` |
| Uptime SLA + status page | operations | **planned** | `status-sla.md` |
| Supply-chain hardening (lockfiles, SCA) | compliance | **implemented** | `security-audit.md` |

---

## 2. The gate-proven controls (what we can demonstrate)

These controls are exercised by self-contained gates that run a tenant-control built
from current source against a throwaway database; each gate proves the behavior AND
its flag-off parity.

- **Tamper-evident audit (`tamper-evident-audit`, m104).** Per-tenant audit entries are
  hash-chained; the chain is recomputable, so any insert/edit/delete is detectable.
  `scripts/verify/m104-audit-chain.sh` proves a tampered row breaks verification.
- **Hard-erase (`hard-erase`, m105, migration 048).** Scoped hard delete of a subject's
  data with a verifiable erasure record; `m105-hard-erase.sh` proves the data is gone
  and another tenant is never touched.
- **Data portability (`data-portability-export`, m109).** Engine-neutral JSON bundle of
  ONE tenant's data with a manifest (tables, counts, sha256), strictly tenant-scoped
  (`m109-tenant-export.sh`).
- **SOC2-lite evidence (`soc2-lite-evidence`, m108, migration 051).** A collector seals
  signed snapshots of CI results, access posture, and the change-management trail;
  `m108-soc2-evidence.sh` proves collect/verify integrity. **This is internal evidence,
  not a formal report** — see §4.
- **Per-tenant isolation (`per-tenant-isolation`, m46).** Isolation is per-**request**
  (`app.current_tenant_id` + owner predicate re-stamped every request), not per-pool —
  which is why 10K tenants collapse onto 1 pool with byte-identical results to
  per-tenant pools. `m46-share-pools-isolation.sh` proves cross-engine isolation at
  density; see `scale-slo.md`.
- **IP allowlist (`network-access-control`, m106).** Per-tenant network access control
  enforced in the control plane; `m106-ip-allowlist.sh` proves enforcement + parity.
  (This is access control, **not** a full L7 WAF — see §4.)
- **Passkeys (`enterprise-passkeys`, m107, migration 050).** Server-side WebAuthn
  registration + authentication, minting a GoTrue-shaped session; `m107-passkeys.sh`
  drives the full ceremony and proves wrong-key / replay / cross-user rejection.
- **Organizations / RBAC (`organizations-rbac`, m103).** Control-plane org model with
  members, invites, and roles; `m103-orgs-rbac.sh`. Org scoping stays control-plane,
  preserving the shared-pool density story.
- **Supply chain (`supply-chain`).** Frozen lockfiles; `npm ci --ignore-scripts`; pnpm
  `minimum-release-age` + `onlyBuiltDependencies` allowlist; cargo-audit on both Rust
  workspaces; `make baas-security-scan` (SEMGREP + npm audit). See `security-audit.md`.

---

## 3. Partial controls (real, with named gaps)

- **Encryption in transit (`encryption-in-transit`, partial).** Under
  `SECURITY_MODE=max`, MSSQL verifies TLS by default and refuses insecure DSNs;
  mongo/redis insecure DSN params are rejected; CA-pin via `DATA_PLANE_TLS_CA_FILE`.
  **Gap:** Postgres `sslmode=require` is accept-any *outside* max (audit O4) — run max
  for multi-tenant. Edge TLS is operator-provided. (`security-audit-asvs.md`)
- **Secrets management (`secrets-management`, partial).** Vault-backed secrets with
  `credential_ref{provider:vault}` and dynamic short-lived DB credentials. **Gap:**
  plaintext `DATA_PLANE_MOUNTS` are not yet forbidden outside max (audit O5).
  (`security-audit.md`)
- **SOC2-lite evidence (`soc2-lite-evidence`, partial).** The collector (m108) is real
  and integrity-checked, but it is **input to** an audit, not the audit itself — see §4.
- **Vulnerability disclosure (`vulnerability-disclosure`, partial).** The disclosure
  policy + contact are defined; the public status page + `security.txt` endpoint are
  on-demand infra not yet stood up (`status-sla.md`).

---

## 4. Planned controls (honestly not yet proven)

- **Formal SOC 2 Type II (`formal-soc2-type2`, planned).** Requires an independent
  external auditor over a multi-month observation window. **Not yet engaged.** The m108
  evidence collector shortens that audit; it does not replace it.
- **Encryption at rest, per-tenant (`encryption-at-rest`, planned).** Disk/volume
  encryption is an operator/host responsibility today; per-tenant encrypted-at-rest
  backups are a roadmap follow-up (B6 / audit solution #11). Not yet Grobase-enforced.
- **Web Application Firewall (`waf`, planned).** A managed L7 WAF is provided by the
  hosting edge in the managed-cloud offering and is operator-supplied for self-host;
  it is not yet a Grobase-enforced, gate-proven control. The closest enforced control
  today is the per-tenant IP allowlist (m106).
- **Uptime SLA + status page (`sla-uptime`, planned).** Per-tier uptime targets are
  `(TARGET)` pending the C7 uptime probe; the SLA is not enforceable until a probe
  writes durable availability samples (`status-sla.md` §1, §2).

---

## 5. Compliance & legal posture

- **Framework cross-walks (audit-ready, not certified).** Per-standard control matrices map every
  control above to its framework clause, each citing an in-repo, re-runnable gate:
  [SOC 2 TSC matrix](compliance/soc2-tsc-matrix.md) ·
  [GDPR article matrix](compliance/gdpr-article-matrix.md) ·
  [ISO 27001:2022 Statement of Applicability](compliance/iso27001-soa.md) (all 93 Annex A controls).
  The [security policy set](compliance/security-policies/00-index.md) (infosec, access-control,
  incident-response, change-management, vendor, BCP/DR, data-retention) and the
  [auditor handoff](compliance/auditor-handoff.md) (the single index for a SOC 2 / ISO body /
  Vanta / Drata, plus the honest human/$$ atoms) complete the pack. Index +
  honesty bar: [compliance/README.md](compliance/README.md); kept honest by gate `m143`.
- **GDPR.** Data portability (Art. 20, m109) and erasure (Art. 17, m105) are shipped
  and gate-proven. Processor terms are in the [DPA](legal/data-processing-addendum.md)
  (Art. 28) with SCC references; subprocessors are listed in
  [subprocessors.md](legal/subprocessors.md). Article-by-article: the
  [GDPR matrix](compliance/gdpr-article-matrix.md); records of processing
  [RoPA](compliance/gdpr-ropa.md) (Art. 30) and the [DPIA template](compliance/dpia-template.md)
  (Art. 35).
- **Legal documents (TEMPLATES, counsel review required).**
  [Terms of Service](legal/terms-of-service.md) ·
  [Privacy Policy](legal/privacy-policy.md) ·
  [DPA](legal/data-processing-addendum.md) ·
  [Subprocessors](legal/subprocessors.md) ·
  [Acceptable Use Policy](legal/acceptable-use-policy.md) ·
  [SLA](legal/sla.md). Each is clearly marked *TEMPLATE — not legal advice*.

---

## 6. Consuming the posture programmatically

```bash
# enabled deployment (TRUST_CENTER_ENABLED=1)
curl -s https://<host>/v1/trust            # full manifest (envelope + controls)
curl -s https://<host>/v1/trust/controls   # {count, controls[]}
```

The endpoint is **public-readable** (no secrets, no tenant data — the public half of
the security story) and reflects `config/trust/posture.json` exactly. When the flag
is off, `/v1/trust*` returns 404 (byte-parity). Source: `internal/trust/`; gate:
`scripts/verify/m112-trust-center.sh`.
