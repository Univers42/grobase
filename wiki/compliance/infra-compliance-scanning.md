# Infrastructure Compliance Scanning (SOC 2 / ISO 27001 / GDPR — as code)

> **What this is.** The *runnable* layer under the compliance cross-walk pack. The matrices in this
> directory ([`soc2-tsc-matrix.md`](soc2-tsc-matrix.md), [`iso27001-soa.md`](iso27001-soa.md),
> [`gdpr-article-matrix.md`](gdpr-article-matrix.md)) say **what** each control satisfies; this page
> wires the **scanners that produce evidence for them** and is brutally honest about which of those
> scanners can run today and which need a live cloud account.

---

## The one honesty bar you must read first

Compliance scanning splits into **two halves**, and only one is runnable on a laptop:

| Half | What it audits | Tools | Runnable **now** (no cloud)? |
|---|---|---|---|
| **App-controls half** | the *code and behaviour* of Grobase: authz, RLS/owner-scope, crypto, secret handling, dependency & container CVEs, web vulns | the numbered **gate battery** (`scripts/verify/m*.sh`) + **Semgrep/Trivy/TruffleHog** ([`run-security-scans.sh`](../../mini-baas-infra/scripts/security/run-security-scans.sh)) + **ZAP** ([`zap-baseline.sh`](../../mini-baas-infra/scripts/verify/zap-baseline.sh)) | **Yes** — already wired and gate-kept |
| **Infra-config half** | the *deployment configuration* (the IaC we ship) and, ultimately, the *live cloud account* it runs in | **Checkov** (IaC) · **Prowler** + **Steampipe/Powerpipe** (live cloud) | **Partly** — Checkov yes; Prowler/Steampipe need real cloud creds |

The infra-config half is what this page adds. It splits **again**:

```
infra-config half
├── IaC config (our Helm charts)         → infra-compliance-scan.sh   ✅ RUNS NOW (Docker, no cloud)
└── LIVE cloud account (AWS/GCP/Azure/K8s)
    ├── Prowler  --compliance soc2_aws   → prowler-scan.sh            ⏳ needs cloud creds
    └── Steampipe/Powerpipe benchmark    → steampipe-compliance.sh    ⏳ needs cloud creds
```

> **A green local run is NOT a SOC 2 / ISO 27001 / GDPR pass.** Checkov over our charts proves *our
> deployment config has no flagged misconfigurations*. Prowler and Steampipe are the tools that audit
> a real account against the built-in SOC 2 / ISO 27001 / GDPR frameworks — and **they cannot run
> without live cloud credentials we do not have locally**, so they are *wired and documented*, not
> "passing." None of these tools issues a certificate; a certificate needs an external party over a
> calendar-bound window (see [`README.md`](README.md) honesty bar and
> [`auditor-handoff.md`](auditor-handoff.md)).

---

## The three scripts

All three are **Docker-first** (host needs only `docker`, mirroring
[`run-security-scans.sh`](../../mini-baas-infra/scripts/security/run-security-scans.sh) and
[`zap-baseline.sh`](../../mini-baas-infra/scripts/verify/zap-baseline.sh)) and write to
`mini-baas-infra/artifacts/security-audit/compliance/`.

Location: `mini-baas-infra/scripts/security/compliance/`.

### 1. `infra-compliance-scan.sh` — Checkov over the Helm charts (RUNS NOW)

Runs **[Checkov](https://www.checkov.io/)** (`bridgecrew/checkov`) over every chart under
`deploy/helm/*` with the `kubernetes,helm` policy packs. This is the **local proxy for
infrastructure compliance**: it audits the deployment config we actually ship — security contexts,
dropped capabilities, privilege escalation, network policy, secret handling, image pinning.

```bash
# default: scan all charts under deploy/helm, warn-only (does not block)
bash mini-baas-infra/scripts/security/compliance/infra-compliance-scan.sh

# gate hard once the charts are clean
COMPLIANCE_FAIL_LEVEL=error bash mini-baas-infra/scripts/security/compliance/infra-compliance-scan.sh

# scan one chart only
COMPLIANCE_HELM_DIRS="apps/baas/mini-baas-infra/deploy/helm/grobase" \
  bash mini-baas-infra/scripts/security/compliance/infra-compliance-scan.sh
```

| Knob | Default | Meaning |
|---|---|---|
| `COMPLIANCE_FAIL_LEVEL` | `warn` | `off` = always exit 0 · `warn` = report loudly, exit 0 · `error` = exit 1 on any failed check |
| `COMPLIANCE_HELM_DIRS` | all charts with a `Chart.yaml` | space-separated chart dirs |
| `COMPLIANCE_FRAMEWORK` | `kubernetes,helm` | Checkov `--framework` |
| `COMPLIANCE_SKIP_CHECKS` | — | comma list of check IDs to suppress (e.g. `CKV_K8S_43`) |
| `COMPLIANCE_CHECKOV_IMAGE` | `bridgecrew/checkov:latest` | override for an air-gapped mirror |

**Why `warn` by default.** The two charts have an honest split: `deploy/helm/grobase` carries a
hardened `podSecurityContext` / `containerSecurityContext` (runAsNonRoot, drop ALL caps, no
privilege escalation, seccomp RuntimeDefault), while the generated `deploy/helm/mini-baas`
deployment template has **no** securityContext yet — so Checkov flags the usual Kubernetes hardening
checks (`CKV_K8S_*`) there. Reporting that honestly (warn) is the correct first state; flip to
`error` after the mini-baas template gains the same securityContext block.

### 2. `prowler-scan.sh` — Prowler against a live cloud (needs creds)

Wraps **[Prowler](https://github.com/prowler-cloud/prowler)** (`toniblyx/prowler`). Prowler audits a
**live** AWS / GCP / Azure / Kubernetes account against its built-in frameworks.

```bash
# no creds locally → prints exactly what it WOULD run + exits 0 (no failure)
bash mini-baas-infra/scripts/security/compliance/prowler-scan.sh

# with real creds exported, pick cloud + framework:
CLOUD=aws FRAMEWORK=soc2_aws          bash .../prowler-scan.sh
CLOUD=aws FRAMEWORK=iso27001_2013_aws bash .../prowler-scan.sh
CLOUD=aws FRAMEWORK=gdpr_aws          bash .../prowler-scan.sh
CLOUD=aws FRAMEWORK=cis_3.0_aws       bash .../prowler-scan.sh
```

**The no-creds guard is the point.** When no `AWS_*` / `GOOGLE_APPLICATION_CREDENTIALS` / `AZURE_*` /
kubeconfig is present, the script prints the cloud, the framework, the control mapping, **and the
exact `docker run` command it would execute**, then exits `0` with a "needs live cloud creds"
message. It never pretends a local run audited SOC 2.

| Framework flag (AWS) | Maps to |
|---|---|
| `soc2_aws` | SOC 2 Trust Services Criteria |
| `iso27001_2013_aws` | ISO/IEC 27001 Annex A |
| `gdpr_aws` | GDPR technical controls |
| `cis_3.0_aws` | CIS AWS Foundations Benchmark |
| `hipaa_aws` | HIPAA Security Rule |

List what a cloud ships: `docker run --rm toniblyx/prowler:latest prowler aws --list-compliance`.

### 3. `steampipe-compliance.sh` — Powerpipe benchmarks against a live cloud (needs creds)

Wraps **[Steampipe](https://steampipe.io/)** + **[Powerpipe](https://powerpipe.io/)** running the
Compliance mods (the AWS/GCP/Azure Compliance mods ship `soc_2`, `iso_27001_2022`, `gdpr`,
`cis_v300`, …). Steampipe exposes the live account as SQL; Powerpipe runs the benchmark over it.

```bash
# no creds → prints what it WOULD run + exits 0
bash mini-baas-infra/scripts/security/compliance/steampipe-compliance.sh

# with creds:
CLOUD=aws BENCHMARK=soc_2          MOD=aws_compliance bash .../steampipe-compliance.sh
CLOUD=aws BENCHMARK=iso_27001_2022 MOD=aws_compliance bash .../steampipe-compliance.sh
CLOUD=aws BENCHMARK=gdpr           MOD=aws_compliance bash .../steampipe-compliance.sh
```

Same no-creds guard contract as Prowler: prints the full plugin-install + `powerpipe benchmark run
benchmark.<name>` command sequence, exits `0`.

---

## How findings map back to the compliance pack

The two halves feed the cross-walk matrices differently:

| Scanner | Evidence it produces | Cross-walk home |
|---|---|---|
| `infra-compliance-scan.sh` (Checkov) | IaC misconfig findings on our charts | ISO **A.8.9** Configuration management · **A.8.20** Networks security · **A.8.22** Segregation of networks · **A.8.24** Use of cryptography — [`iso27001-soa.md`](iso27001-soa.md). SOC 2 **CC6.1** logical access · **CC6.6** boundary protection · **CC7.1** misconfiguration detection — [`soc2-tsc-matrix.md`](soc2-tsc-matrix.md) |
| `prowler-scan.sh` (live cloud) | live-account findings vs the *named* framework | the framework it is run with maps 1:1 — `soc2_aws` → [`soc2-tsc-matrix.md`](soc2-tsc-matrix.md), `iso27001_2013_aws` → [`iso27001-soa.md`](iso27001-soa.md), `gdpr_aws` → [`gdpr-article-matrix.md`](gdpr-article-matrix.md) |
| `steampipe-compliance.sh` (live cloud) | benchmark pass/fail vs the *named* benchmark | as above, per `BENCHMARK` |

The **app-controls half** (already wired) maps to the same rows from the other side — `run-security-scans.sh`
and `zap-baseline.sh` are the evidence behind SOC 2 **CC6.8** (malicious software / supply chain),
**CC7.1** (vulnerability detection), and ISO **A.8.8** (technical vulnerabilities), **A.8.28** (secure
coding) — see [`../security-audit.md`](../security-audit.md) and
[`../security-residuals-runbook.md`](../security-residuals-runbook.md).

> Per the pack's source-of-truth hierarchy ([`README.md`](README.md)), these scanners *produce
> findings*; they do **not** set a control's status. A control is `proven` only when its gate `mNN`
> passes — a Checkov pass is supporting evidence for the config-management controls, not a status of
> its own. Status lives in `config/trust/posture.json`.

---

## Where this sits in the whole security toolchain

```
Grobase compliance-as-code
│
├── APP-CONTROLS HALF  (runs now, gate-kept)
│   ├── scripts/verify/m*.sh          numbered control gates (authz, RLS, crypto, erasure, audit…)
│   ├── security/run-security-scans   Semgrep (SAST) · npm/pnpm audit (SCA) · Trivy (CVE) · TruffleHog (secrets)
│   └── verify/zap-baseline.sh        ZAP DAST against the live WAF
│
└── INFRA-CONFIG HALF  (this page)
    ├── compliance/infra-compliance-scan.sh   Checkov over deploy/helm/*        ✅ runs now
    ├── compliance/prowler-scan.sh            Prowler vs live cloud (SOC2/ISO/GDPR/CIS)  ⏳ needs creds
    └── compliance/steampipe-compliance.sh    Powerpipe benchmark vs live cloud          ⏳ needs creds
```

---

## Recommended `make` target (not yet wired — Makefile untouched)

Add alongside `baas-security-scan` / `baas-zap` in
`infrastructure/makes/baas-verify.mk` (where the other security-script targets live):

```make
.PHONY: baas-compliance-scan
baas-compliance-scan:
## IaC compliance (Checkov over deploy/helm/*) — local proxy for ISO A.8 / SOC2 CC6-7.
	@bash apps/baas/mini-baas-infra/scripts/security/compliance/infra-compliance-scan.sh
```

`prowler-scan.sh` / `steampipe-compliance.sh` are intentionally **not** wired to a default `make`
target — they are run by hand against a live cloud when one exists, with `CLOUD=` / `FRAMEWORK=` set.

---

## Caveats (the non-negotiable ones)

1. **These are not a certificate.** Audit-ready ≠ certified. A SOC 2 Type 2 report / ISO 27001
   certificate needs an external auditor over a window — enumerated in
   [`auditor-handoff.md`](auditor-handoff.md).
2. **Prowler/Steampipe need a live cloud account.** Until Grobase runs in a real AWS/GCP/Azure/K8s
   account, those two scripts only *document* what they would audit — by design, they exit 0 and
   never claim a pass.
3. **Checkov audits config, not runtime.** A clean chart can still be deployed into a misconfigured
   cluster; the live-cloud scanners are what close that gap.
4. **No invented status.** A scanner finding is evidence; the control status remains owned by
   `config/trust/posture.json` and the gate that proves it.

## See also

- [`README.md`](README.md) — the compliance pack map + honesty bar
- [`soc2-tsc-matrix.md`](soc2-tsc-matrix.md) · [`iso27001-soa.md`](iso27001-soa.md) · [`gdpr-article-matrix.md`](gdpr-article-matrix.md) — the cross-walk matrices these findings feed
- [`auditor-handoff.md`](auditor-handoff.md) — the human/$$ atoms a real certification still needs
- [`../security-audit.md`](../security-audit.md) · [`../security-residuals-runbook.md`](../security-residuals-runbook.md) — the app-controls-half findings
