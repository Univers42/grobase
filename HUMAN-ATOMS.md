# HUMAN-ATOMS — the definitive human/$$/external-action checklist

> **The single authoritative list** of everything that needs a human, money, or an
> external account to reach **10/10** across the three GA targets — each reduced to
> exact, copy-pasteable commands. Everything else is code-ready and gate-proven; this
> file is what a machine cannot do for you.
>
> **Targets:** (1) **OSS self-host** · (2) **Managed cloud** (a stranger can BUY) ·
> (3) **Enterprise** (a company can PROCURE).
>
> **Preflight:** `bash mini-baas-infra/deploy/go-live/go-live.sh` prints READY/MISSING
> for each atom below and the exact command for each (read-only; it never pushes,
> deploys, publishes, or flips a flag — *confirm-the-irreversible*).
>
> **Standing consent (memory):** continue the plan autonomously, but **HOLD** every
> *irreversible* atom (📌) for an explicit human trigger: npm publish, RS256 live
> cutover, pushes/deploys/tags. Those are flagged 📌 below.
>
> **Legend:** 🔵 web-UI / account (only a human can) · ⚪ command (human runs, or paste
> here prefixed `!`) · 📌 irreversible — held · 💰 costs money.
> Paths are relative to `apps/baas/` unless absolute. Run ⚪ commands from
> `apps/baas/mini-baas-infra/` unless noted.

---

## Status board

| # | Atom | Target | Unblocks (scorecard line) | Kind |
|---|------|--------|---------------------------|------|
| 1 | npm SDK publish `@mini-baas/js` v0.2.0 | cloud + OSS | DX / "client SDK on a public registry" | 🔵🔵🔵 + ⚪📌 |
| 2 | Repo version tag `baas-v1.4.0` | all | "released, versioned product" | ⚪📌 |
| 3 | Stripe live account + keys + meters | cloud | Billing bar / "stranger can BUY → Stripe-billed" | 🔵🔵🔵 💰 + ⚪ |
| 4 | Domain + DNS + TLS | cloud | Cloud-ready / "hosted at api.\<domain\>" | 🔵🔵 💰 + ⚪ |
| 5 | Managed k8s cluster (helm install) | cloud + ent | Operational-ready / "HA topology deployed" | 🔵 💰 + ⚪ |
| 6 | Production SMTP provider | cloud | Cloud onboarding / "signup + transactional mail" | 🔵 + ⚪ |
| 7 | RS256 live-auth flip | cloud + ent | Security bar / "asymmetric JWT, JWKS rotation" | ⚪📌 |
| 8 | 100K-tenant load SLO (quiet node) | scale | SLA bar / "100K @ measured p99" (PENDING measurement) | ⚪ |
| 9 | Failover / multi-AZ infra | scale + ent | SLA bar / "uptime SLO" (PENDING — failover unbuilt) | 🔵 💰 + design |
| 10 | SOC 2 Type II + ISO 27001 external audit | enterprise | Compliance / "SOC 2 report + ISO 27001 cert" | 🔵 💰 |
| 11 | Lawyer review + DPO / EU representative | cloud + ent | Procurement / "TOS·DPA·SLA·privacy + RoPA/DPIA" | 🔵 💰 |
| 12 | Live IdP for SSO (OIDC) + SCIM | enterprise | Enterprise auth / "real-IdP SSO+SCIM" | 🔵 💰 |
| 13 | Cloud KMS backend for CMEK (Vault Transit works today; m123 ✅) | enterprise | Compliance / "customer-managed encryption" | ✅ code · 🔵 💰 cloud-KMS optional |
| 14 | Remove the two `*.rootowned-stale` dirs | housekeeping | Repo hygiene / "no dead duplicates" | ⚪ (sudo) |

> "PENDING measurement" = honestly **not yet measured** (the 100K is *projected*;
> failover is *unbuilt*). Do not quote an availability % or a 100K-load number until
> atom 8/9 produce the artifact.

---

# Group 1 — Publish / release

## 1 · npm SDK publish — `@mini-baas/js` v0.2.0  📌

**Unblocks:** managed-cloud + OSS DX scorecard line *"official client SDK on a public
registry"*. The publish workflow is held — nothing reaches npm without your tag.
Workflow: `.github/workflows/baas-cli-publish.yml` (fires on `baas-cli-v*`).

- 🔵 **a. Create the npm org.** npmjs.com → avatar → **Add Organization** → name `mini-baas` → Free.
      *(Already own an org? Skip — rename the scope in `apps/baas/sdk/package.json`, then do b–d only.)*
- 🔵 **b. Create an automation token.** npmjs.com → avatar → **Access Tokens** → Generate →
      **Granular Access Token** (read/write on scope `@mini-baas`) **or Classic Automation**
      (bypasses the 2FA OTP CI can't enter) → copy `npm_…`.
- 🔵 **c. Add the GitHub secret.** github.com/Univers42/groot → Settings → Secrets and
      variables → Actions → **New repository secret** → name `NPM_TOKEN`, value = the token.
- ⚪📌 **d. Publish** (the tag fires the held `publish` job → `npm publish --provenance --access public`):
  ```bash
  cd /home/dlesieur/Documents/ft_transcendence
  git tag baas-cli-v0.2.0 && git push origin baas-cli-v0.2.0
  ```
  *(The workflow asserts the tag matches `package.json` version `0.2.0`; bump the file or retag if they drift.)*
- ⚪ **e. Verify:** `npm view @mini-baas/js version`   → expect `0.2.0`.

**Irreversible?** YES — an npm version is immutable (unpublish only within 72h). Held 📌.

---

## 2 · Repo version tag — `baas-v1.4.0`  📌

**Unblocks:** all targets' *"released, versioned product"* line. Latest released tag is
`baas-v1.3.0` (`git tag | grep ^baas-v`); the GA-night work is the next minor.
This tag drives `.github/workflows/baas-release.yml` (Docker-image release —
namespace `baas-v*`, **separate** from `baas-cli-v*` so neither fires the other).

- ⚪ **a. Sanity (safe, run anywhere):** confirm the tree is green & the worklog committed.
- ⚪📌 **b. Cut the tag** (only after the GA-night branch has merged / is the intended ref):
  ```bash
  cd /home/dlesieur/Documents/ft_transcendence
  git tag baas-v1.4.0 && git push origin baas-v1.4.0
  ```
- ⚪ **c. Bump the Helm `appVersion`** to match (currently `appVersion: "1.2.0"` in
  `mini-baas-infra/deploy/helm/grobase/Chart.yaml`) so the chart and the image release agree.

**Irreversible?** A pushed tag + the release CI publishing images = effectively irreversible. Held 📌.

---

# Group 2 — Cloud go-live

> All of §3–§7 are the managed-cloud "a stranger can BUY" target. The cloud features
> (B1–B6) are built + gate-proven and **flag-gated OFF = byte-parity** today; go-live
> = providing the external accounts and promoting flags **one rung at a time** via the
> ladder in `mini-baas-infra/config/cloud/README.md` (R0→R7). **Never enable enforcement
> (402s / spend caps / suspends) before it has shadowed + warned.**

## 3 · Stripe live billing (B3)  💰

**Unblocks:** the **Billing** bar / *"stranger signs up → usage → Stripe-billed"*.
Gate m82 (`m82-billing-report.sh`) proves the reporter against a mock Stripe; live
needs a real account. Reporter refuses to start with `BILLING_ENABLED=1` but no key
(by design — `metering/billing.go`).

- 🔵 **a.** Create + activate a Stripe account (stripe.com). 💰
- 🔵 **b.** Stripe → **Billing → Meters**, create meters matching the reporter's event names:
  `grobase_query_count`, `grobase_write_rows` (add `storage_bytes` / `realtime_minutes` /
  `function_invocations` meters if you bill them — see `config/cloud/flags.env.example`
  `BILLING_METER_*`).
- 🔵 **c.** Developers → API keys → copy the Secret key (`sk_test_…` to rehearse, `sk_live_…` for real).
- ⚪ **d.** Wire it (secrets stay OUT of git) and promote via the ladder — **R1 observe first,
  then R6 billing**, never jump to enforce:
  ```bash
  cd /home/dlesieur/Documents/ft_transcendence/apps/baas/mini-baas-infra
  cp config/cloud/flags.env.example config/cloud/flags.prod.env
  # edit flags.prod.env — R1: METERING_ENABLED=1 METERING_INGEST=1 DATA_PLANE_METERING=1
  #                       R6 (later rung): BILLING_ENABLED=1
  # secrets via your secrets tool (NEVER a committed file):
  #   STRIPE_API_KEY=sk_live_xxx
  #   BILLING_METER_QUERY_COUNT=grobase_query_count
  #   BILLING_METER_WRITE_ROWS=grobase_write_rows
  cat config/cloud/flags.prod.env >> .env        # flags.<env>.env is gitignored
  make up EDITION=prod
  ```
- ⚪ **e.** Each billable tenant needs a `tenant_billing` row mapping it to its Stripe `cus_…`.
  Enable metering first, watch `tenant_usage` fill, **then** flip billing.

**Irreversible?** No (test keys are safe to rehearse). Real charges only on `sk_live_` + `BILLING_ENABLED=1`.

## 4 · Domain + DNS + TLS  💰

**Unblocks:** *"hosted at `api.<domain>` with valid TLS"*. cert-manager issues the cert
automatically once DNS points at the ingress.

- 🔵 **a.** Buy a domain from any registrar. 💰   🔵 **b.** Have DNS access to it.
- ⚪ **c.** After the cluster is up (§5), create an **A record** `api.<yourdomain>` → the
  ingress EXTERNAL-IP (`kubectl -n grobase get ingress`). cert-manager then issues TLS.
  Set the host in the Helm values (`ingress.hosts[0].host`, `ingress.tls[0].hosts` —
  default placeholder `api.grobase.example` in `deploy/helm/grobase/values.yaml`).

**Irreversible?** No.

## 5 · Managed k8s cluster — `helm install` (Track-C C3)  💰

**Unblocks:** Operational-ready / *"HA topology deployed"*. Chart is lint-clean at
`mini-baas-infra/deploy/helm/grobase` (2× data-plane / control / adapter / kong with HPA;
StatefulSet PG+Redis; deny-by-default NetworkPolicy; optional Vault-CSI).

- 🔵 **a.** A managed Kubernetes cluster (GKE / EKS / DO / …) — your cloud account + bill. 💰
- ⚪ **b.** Install (once `kubectl` points at the cluster):
  ```bash
  cd /home/dlesieur/Documents/ft_transcendence/apps/baas/mini-baas-infra
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  helm install grobase deploy/helm/grobase --namespace grobase --create-namespace \
    --set ingress.hosts[0].host=api.<yourdomain> \
    --set ingress.tls[0].hosts[0]=api.<yourdomain>
  kubectl -n grobase get ingress,pods    # note the ingress EXTERNAL-IP for §4c
  ```
  *(Laptop dry-run: `helm template grobase deploy/helm/grobase -f deploy/helm/grobase/values-dev.yaml` — renders, deploys nothing.)*
- ⚪ **c.** Prefer **Vault-CSI** for secrets in prod: set `vault.enabled=true` (+ install the CSI
  driver/provider) so `JWT_SECRET`/`POSTGRES_PASSWORD` come from Vault, not a K8s Secret.

**Irreversible?** The install itself is reversible (`helm uninstall`); cloud spend is the commitment.

## 6 · Production SMTP provider

**Unblocks:** cloud onboarding / *"signup + transactional mail"* (local dev uses Mailpit).

- 🔵 **a.** A transactional SMTP provider (SES / Postmark / Resend / …).
- ⚪ **b.** Set `SMTP_HOST`/`SMTP_PORT`/`SMTP_USER`/`SMTP_PASSWORD` (+ `MAILPIT_VERIFY_DELIVERY=false`)
  via your secrets tool / env; never commit them.

**Irreversible?** No.

## 7 · RS256 live-auth flip (security headline)  📌

**Unblocks:** Security bar / *"asymmetric JWT signing + JWKS rotation"*. Runbook:
`wiki/security-residuals-runbook.md` §G-RS256. Gate m81 (`m81-rs256-issuer.sh`) **already
proves a real RS256 issuer end-to-end through Kong + the tenant-control JWKS verifier** —
the in-repo verifier (`jwt.go`/`jwks.go`) is shipped + unit-proven. The **only** blocker is
the issuer: vendored gotrue `v2.188.1` signs **HS256 only**.

- ⚪ **a. Re-confirm the proof (safe, scratch-only, run anywhere incl. `!` here):**
  ```bash
  bash /home/dlesieur/Documents/ft_transcendence/apps/baas/mini-baas-infra/scripts/verify/m81-rs256-issuer.sh
  ```
- ⚪📌 **b. Live cutover (runbook steps 2–6, this is the global-login property):**
  1. Bump `docker/services/gotrue/Dockerfile` to a gotrue/auth image with asymmetric JWT
     signing (Supabase auth ≥ 2025-07 "JWT signing keys") **or** front a JWKS signer.
  2. Private key → Vault.  3. Swap Kong `jwt_secrets` HS256 → RS256 (`rsa_public_key`).
  4. Set `JWT_ALG=RS256` + `JWKS_URL=<issuer>/.well-known/jwks.json` on tenant-control.
  5. `make all && make playground` — must stay **200 across /rest /query /data /storage**.
  6. **Keep HS256 valid for one 3600 s TTL** for instant rollback (runbook step 7).

**Irreversible?** A partial flip 401s **every** authenticated request stack-wide. Held 📌 —
explicit human go/no-go.

---

# Group 3 — Scale / SLA measurement

## 8 · 100K-tenant load SLO (Track-C C6)

**Unblocks:** SLA bar / *"100K tenants at a measured p99"*. **PENDING measurement** — this
box is CPU-starved; the number is currently **projected**, not measured. In-hand evidence
that IS measured: 24,887 live tenants @ 2.6 MiB at rest
(`artifacts/scale/footprint-live-24887.json`) and 10K tenants → 1 pool, 0×5xx (gate m46).

- ⚪ **a.** On any **idle** machine with Docker (data-root on a big disk), after cloning:
  ```bash
  cd <repo>/apps/baas/mini-baas-infra
  docker compose -f docker-compose.yml -f docker-compose.scale.yml up -d   # PG max_connections=2000, SHARE_POOLS=1
  SCALE=100000 RATE=20 DURATION=60s DIST=zipf PREFIX=scale-100k \
    bash scripts/scale/load-100k.sh
  ```
  Seed is resumable (~50 min Argon2id wall). Result → `artifacts/scale/load-100k-100000.json`.
- ⚪ **b.** Record it:
  ```bash
  git add artifacts/scale/load-100k-100000.json
  git commit -m "perf(baas): 100K-tenant load SLO (C6)"
  git push origin feat/baas-scale-program
  ```
  *(Dry-run first to validate inputs without running anything live: prefix with `DRY_RUN=1`.)*

**Irreversible?** No (scratch run; only the artifact is kept).

## 9 · Failover / multi-AZ infra

**Unblocks:** SLA bar / *"uptime SLO"*. **PENDING — failover is unbuilt.** Do **not** publish
an availability % until this exists and is measured. Needs: managed multi-AZ Postgres (CNPG /
Patroni / RDS Multi-AZ — Helm PG StatefulSet is `replicas: 1`, single-AZ today), a second
region/zone for the stateless planes (already HPA-scaled in the chart), and a documented +
*rehearsed* failover drill before any SLA number is claimed.

- 🔵 **a.** Provision multi-AZ managed Postgres + a second AZ/region (cloud account + bill). 💰
- design/⚪ **b.** Set `planes.postgres.enabled=false` in the chart and point data/control at the
  external managed PG (Track-C C4); run + record a failover drill.

**Irreversible?** No (infra), but it gates any uptime claim.

---

# Group 4 — Enterprise / legal

## 10 · SOC 2 Type II + ISO 27001 external audit  💰

**Unblocks:** Compliance / *"SOC 2 Type II report"* + *"ISO 27001 certification"*. The full
audit-ready evidence pack now lives in `wiki/compliance/`: the per-framework cross-walks
(`soc2-tsc-matrix.md`, `gdpr-article-matrix.md`, the 93-control `iso27001-soa.md`), the
`risk-register.md`, the `security-policies/` pack, and the one-page `auditor-handoff.md` that tells
an auditor exactly what to read and which gates to re-run. Gate **m108** (`m108-soc2-evidence.sh`)
ships the **SOC 2-lite evidence collector** (hash-sealed snapshots); gate **m143**
(`m143-compliance-matrices.sh`) proves the cross-walks are complete + honest. This is *"evidence
collected, audit-ready"*, **NOT a certificate** — a certificate requires an external body.

- 🔵 **a.** Engage a licensed SOC 2 auditor (Vanta/Drata-assisted or a CPA firm) **and** an accredited
  ISO 27001 certification body. Hand them `wiki/compliance/auditor-handoff.md`. 💰
- ⚪ **b.** Run the evidence: `SOC2_EVIDENCE_ENABLED=1` (optionally `SOC2_EVIDENCE_SCHEDULE=24h` to
  accumulate the Type II observation-window population), `POST /v1/compliance/collect`, export
  `GET /v1/compliance/evidence`; re-run `scripts/verify/run-gate-battery.sh --enterprise`. Trust-center
  posture is gate m112 (`config/trust/posture.json`).
- 🔵 **c.** Commission an external **penetration test** (the strongest single due-diligence artifact)
  and attach the report. 💰
- ⚪ **d.** Stand up the **C7 uptime probe** (atom 8/9) so the Availability criterion + SLA carry a
  *measured* number, not a target.

**Irreversible?** No. **Sequence:** evidence + SoA (done) → readiness review → remediation →
observation window (SOC 2 Type II) / Stage 1+2 audit (ISO 27001) → report.

## 11 · Lawyer review of legal templates  💰

**Unblocks:** Procurement / *"executable TOS · DPA · SLA · privacy"*. The docs in
`wiki/legal/` (`terms-of-service.md`, `data-processing-addendum.md`, `sla.md`,
`privacy-policy.md`, `subprocessors.md`, `acceptable-use-policy.md`) are **TEMPLATES** — each
opens with *"TEMPLATE — review by counsel before use; not legal advice"* and has `[…]`
fields + an uptime number that must come from the **measured** SLA (atom 8/9), not the template.

- 🔵 **a.** A lawyer fills the bracketed fields, sets the legal entity, and reviews each doc. 💰
- ⚪ **b.** Once executed, point the trust center / signup flow at the published versions.
- 🔵 **c.** Appoint a **DPO** and (if established outside the EU) an **EU representative** (GDPR
  Art. 27/37); publish the **RoPA** (`wiki/compliance/gdpr-ropa.md`, Art. 30) and run a **DPIA**
  (`wiki/compliance/dpia-template.md`, Art. 35) where required. 💰

**Irreversible?** No (but publishing un-reviewed legal text is a liability — gate on the lawyer).

## 12 · Live IdP for SSO (OIDC) + SCIM  💰

**Unblocks:** Enterprise auth / *"real-IdP SSO + SCIM provisioning"*. Gates **m110**
(`m110-sso-oidc.sh`, OIDC auth-code flow per-tenant IdP, `SSO_ENABLED` OFF) and **m111**
(`m111-scim.sh`) are proven against a **mock** IdP; production needs a real one.

- 🔵 **a.** A live enterprise IdP (Okta / Entra ID / Auth0 / Google Workspace). 💰 (customer-supplied per tenant)
- ⚪ **b.** Register the per-tenant connection (client id/secret AES-GCM sealed), set the
  redirect URI, enable `SSO_ENABLED=1` for the org; SCIM token for `m111` provisioning.

**Irreversible?** No.

## 13 · Cloud KMS backend for CMEK (optional — Vault Transit works today)  💰

**Unblocks:** *"customer-managed encryption keys"* against a **cloud** KMS. **The CMEK
envelope-encryption seam now EXISTS and is gate-green** (`internal/cmek/`, migration 061,
`m123-cmek-envelope.sh`): per-mount DSN envelope-encrypted (random DEK → AES-256-GCM; DEK wrapped
by an external KMS KEK), with **crypto-shred proven** (delete the KMS key → undecryptable),
flag-gated OFF = byte-parity. It runs TODAY against **Vault Transit** (already in-stack). Per-tenant
distinct KEKs are schema-supported (`cmek_kms_key_id` per row).

- ✅ **done.** CMEK envelope + Vault-Transit provider + crypto-shred + flag-OFF parity (m123).
- 🔵 **a.** *(optional)* Provision a cloud KMS (AWS KMS / GCP KMS) and add its `KMSProvider`
  implementation if a customer requires that backend instead of Vault Transit. 💰
- 🔵 **b.** *(optional)* Per customer: set `CMEK_ENABLED=1` + their `cmek_kms_key_id` so each tenant's
  DSN is wrapped under their own key.

**Irreversible?** No.

---

# Group 5 — Housekeeping

## 14 · Remove the two `*.rootowned-stale` dirs

**Unblocks:** repo hygiene / *"no dead root-owned duplicates"*. These are dead duplicates of
`sdk-dart/` and `sdk-python/` (never edit them; use the un-suffixed dirs). They are root-owned,
so removal needs `sudo` (the user runs it — no passwordless sudo in this env).

- ⚪ **a.** (human, sudo):
  ```bash
  cd /home/dlesieur/Documents/ft_transcendence/apps/baas
  sudo rm -rf sdk-dart.rootowned-stale sdk-python.rootowned-stale
  git add -A && git commit -m "chore(baas): remove dead root-owned stale SDK duplicates"
  ```

**Irreversible?** A delete, but recoverable from git history — low risk.

---

## The fastest path

The two highest-value / lowest-effort atoms are **#1 npm** (3 web clicks + one held tag push)
and **#7 RS256** (gate m81 already green → one `make all && make playground` flip with a 3600 s
HS256 rollback window). Everything in Groups 3–4 gates on real money / external accounts and is
the genuine remaining distance to 10/10 — not code we still have to write.

> Run the preflight any time to re-check status:
> `bash mini-baas-infra/deploy/go-live/go-live.sh`
