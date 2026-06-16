# Go-to-market: the human atoms

> **For a founder/operator.** Your engine is built and gate-proven. This is your
> go-to-market checklist — the short list of steps that turn an
> engineering-complete, gate-green codebase into a *running business with paying
> clients*. **None of these is an engineering blocker.** Each is a contract you
> sign, an account you buy, infrastructure you provision, or a sign-off a lawyer
> gives — work a *human/business* must do, that no script can do for you.
>
> Read this alongside the three companion docs it distils:
> - **`../HUMAN-ATOMS.md`** — the copy-pasteable command-by-command checklist (the
>   "do it now" sheet, with 🔵/⚪/📌/💰 legend per atom).
> - **`ga-readiness-scorecard.md`** — the honest /10 per GA target, every "done"
>   citing a gate, every remainder tagged `[ENG]/[HUMAN]/[INFRA-MEAS]/[LEGAL]`.
> - **`../mini-baas-infra/deploy/go-live/README.md`** + `deploy/ha/README.md` — the
>   one-command cloud go-live runbook and the honest HA architecture.

---

## 1. The concept — engineering-complete ≠ a running business

A gate is green when the script boots the real services and asserts the behavior,
then logs `GATE m<NN>=PASS`. That is **engineering-complete**: the *capability*
exists, is exercised, and stays byte-parity OFF in the committed baseline. But a
green gate is not a paying customer. Between the two sits a small, finite set of
steps that have nothing to do with code.

**A human-atom is a single step that requires a human to sign, buy, or provision
something *external* to the platform — irreversible or off-platform — not write
code.** Three properties define one:

1. **Off-platform / external.** It crosses the boundary of the repo: a Stripe
   account, a domain registrar, a managed Kubernetes cluster, an IdP, an auditor,
   a lawyer. The codebase cannot reach in and create it.
2. **Requires a human decision or spend.** It costs money, accepts legal
   liability, or commits the business to an operational obligation. A machine has
   no standing to do it.
3. **Often irreversible.** An npm version is immutable; a pushed release tag fires
   CI that publishes images; a live Stripe charge is real money; an RS256 partial
   flip 401s every authenticated request. These are gated for an *explicit human
   trigger* (📌 in `../HUMAN-ATOMS.md`).

The thesis of this doc: **the only remaining distance to a buyable, procurable,
SLA-backable product is human atoms — plus three infra *measurements* we have not
yet taken.** The engineering surface is gate-green (§4). This is the inverse of
the usual startup position: most products are *missing features*; Grobase is
missing *signatures, accounts, and a quiet load-test box*.

What is **NOT** a human atom (and is therefore *not* on this list):

- Anything a gate already proves (metering, quota, billing-reporter, self-serve,
  SSO/SCIM protocol, CMEK envelope, RBAC, audit chain — all built, all OFF by
  default). Flipping the flag ON *in production* is the atom; the code is done.
- Data-plane **write-failover**. This is **delegated by design**, not unbuilt: the
  Rust data plane opens `sqlx` pools lazily, so retrying a write on a standby
  risks a double-write — the safe owner of write-failover is the database (RDS
  Multi-AZ / Cloud SQL HA / Patroni / CloudNativePG). What remains is to *measure*
  its RTO/RPO, not to *build* it (`../mini-baas-infra/deploy/ha/README.md` §3).

---

## 2. The atom catalog

Grouped by kind. For each: **what it is · what it UNBLOCKS (which capability
becomes LIVE) · the exact step · reversible?** Every gate cited below was
confirmed to exist as a real script in
`../mini-baas-infra/scripts/verify/`.

### A. Infrastructure atoms

| Atom | Unblocks (becomes LIVE) | The exact step | Reversible? |
|---|---|---|---|
| **Managed k8s cluster** | HA topology actually deployed; everything in §B–§C has somewhere to run | Provision a managed cluster (GKE/EKS/DO/AKS), point `KUBECONFIG` at it, then `helm upgrade --install grobase deploy/helm/grobase` (the chart is the one `go-live.sh` consumes). 💰 cloud bill. | Yes — `helm uninstall` removes the release; the cloud spend is the commitment. |
| **Domain + DNS + TLS** | A hosted, valid-TLS endpoint at `api.<yourdomain>` — the address a stranger types | Buy a domain (💰), add an A/AAAA record → the ingress EXTERNAL-IP, and let cert-manager issue `grobase-api-tls` from Let's Encrypt (or BYO cert via `kubectl create secret tls`). | Yes. |
| **Production SMTP provider** | Signup verification + billing-receipt + transactional mail (local dev uses Mailpit, which never sends outbound) | Sign up with a transactional provider (SES/Postmark/Resend/Mailgun); set `SMTP_HOST`/`SMTP_USER`/`SMTP_PASS` via your secrets tool, never committed. | Yes. |
| **The cloud bill** | Sustained operation — the cluster, PG, egress, KMS, etc. keep running | A funded cloud account. This is the standing operational cost; it is not a one-time step but a business commitment. 💰 | n/a (ongoing). |

### B. Commercial atoms

| Atom | Unblocks (becomes LIVE) | The exact step | Reversible? |
|---|---|---|---|
| **Live Stripe account** | The **Billing** capability: a stranger signs up → uses the product → is metered → is Stripe-billed (real money) | Create + activate a Stripe account (💰). The billing *reporter* is built and gate-proven against a **mock** Stripe — gate `m82-billing-report.sh` — and refuses to start with `BILLING_ENABLED=1` but no key (by design). | Test keys (`sk_test_…`) are fully reversible — rehearse safely. Real charges only on a `sk_live_…` key + `BILLING_ENABLED=1`. |
| **Stripe meters + keys** | The reporter's meter-events have a destination; usage actually accrues to invoices | In Stripe → Billing → Meters create meters matching the reporter's event names (`grobase_query_count`, `grobase_write_rows`, …); copy the secret API key + `whsec_…` webhook secret. | Yes (meters/keys are editable; revoke any time). |

### C. Identity / security atoms

| Atom | Unblocks (becomes LIVE) | The exact step | Reversible? |
|---|---|---|---|
| **A real IdP for SSO/SCIM** | Enterprise auth: a tenant's users sign in through *their* Okta/Entra/Auth0; SCIM provisions/deprovisions them | The SSO (OIDC auth-code) and SCIM protocols are gate-proven against a **mock** IdP — gates `m110-sso-oidc.sh` and `m111-scim.sh` (flags `SSO_ENABLED` etc. OFF by default). The atom: a customer supplies a live IdP; register the per-tenant connection (client id/secret sealed) + redirect URI + SCIM token. | Yes (a connection is config; disable per-org). |
| **A cloud KMS for CMEK** *(optional)* | Customer-managed encryption keys backed by a **cloud** KMS (AWS/GCP KMS) | **Already works today against Vault Transit** — gate `m123-cmek-envelope.sh` proves per-mount DSN envelope-encryption (random DEK → AES-256-GCM; DEK wrapped by an external-KMS KEK) *and* crypto-shred (delete the KMS key → undecryptable). The atom is *optional*: only if a customer demands a specific cloud-KMS backend, provision it + add its `KMSProvider`. 💰 | Yes (additive provider; per-tenant `cmek_kms_key_id`). |
| **RS256 live-auth cutover** 📌 | The security headline: asymmetric JWT signing + JWKS rotation in production | A *real* RS256 issuer end-to-end (Kong RS256 jwt-plugin + tenant-control JWKS verifier) is **already gate-proven** — gate `m81-rs256-issuer.sh` (HS-forge / wrong-key / unknown-kid / `alg=none` / no-bearer all 401). The only blocker is the issuer: the vendored gotrue signs HS256 only. The cutover holds a dual-accept window at the Kong edge for one token TTL. | **Held 📌** — a *partial* flip 401s every authenticated request; explicit human go/no-go. Rollback is one `helm rollback`. |

### D. Legal / compliance atoms

| Atom | Unblocks (becomes LIVE) | The exact step | Reversible? |
|---|---|---|---|
| **Lawyer-reviewed legal templates** | Procurement: executable TOS · DPA · SLA · privacy · subprocessors · AUP a company can sign | The docs in `wiki/legal/` (`terms-of-service.md`, `data-processing-addendum.md`, `sla.md`, `privacy-policy.md`, `subprocessors.md`, `acceptable-use-policy.md`) are **TEMPLATES** — each opens "TEMPLATE — review by counsel before use; not legal advice" with `[…]` fields. A lawyer fills the brackets, sets the legal entity, reviews each. 💰 | Yes — but **publishing un-reviewed legal text is a liability**; gate on the lawyer. |
| **A SOC2 audit firm** | A SOC2 report a procurement team accepts | We ship **SOC2-lite evidence collection** — gate `m108-soc2-evidence.sh` (hash-sealed ci/access/change-mgmt snapshots) — and a trust-center posture (`config/trust/posture.json`, gate `m112-trust-center.sh`). That is **audit-ready, NOT certified**. The atom: engage a licensed SOC2 auditor (Vanta/Drata-assisted or a CPA firm) and hand them the evidence. 💰 | Yes (engagement); the certification, once issued, is a point-in-time attestation. |

> **The honest distinction this group enforces:** *audit-ready ≠ certified*, and a
> *template ≠ an executed contract*. We never claim "SOC2 certified" or quote an
> SLA number a lawyer hasn't reviewed — those stay PENDING their atoms.

### E. Operations atoms (and the measurements they unlock)

| Atom | Unblocks (becomes LIVE) | The exact step | Reversible? |
|---|---|---|---|
| **On-call / support** | A buyable SLA you can *answer* — a human responds to incidents | Staff/contract an on-call rotation + a support channel. A business obligation, not code. | n/a (ongoing). |
| **A measured uptime probe** | A *real* availability number (today: unknown — never published) | Run a black-box uptime probe (blackbox-exporter / synthetic `GET /v1/tenants/me` → 401) against the live domain for **≥30 days**; availability % = successful windows ÷ total. Publish the artifact + probe config. (`deploy/ha/README.md` §6.) | Yes. |
| **A failover drill** | A *measured* write-failover **RTO/RPO** (today: unmeasured) | On the managed-PG provider, **force a primary failover** (RDS `--force-failover` / Cloud SQL failover / `patronictl switchover`) while a write workload runs; measure last-write→first-write wall-clock, repeat ≥3×. (`deploy/ha/README.md` §6.) | Yes (drill on a non-prod replica/window). |
| **A 100K-tenant load run** | A *measured* 100K load-latency SLO (today: **projected**, not measured) | Run `scripts/scale/load-100k.sh` (overlay `docker-compose.scale.yml`, `SHARE_POOLS=1`) on a **quiet, dedicated node** — the dev box is Chrome/CPU-contended. Result → `artifacts/scale/`. | Yes (scratch run; only the artifact is kept). |

> **Honesty rule for this group (binding):** until the uptime probe, the failover
> drill, and the 100K run produce artifacts, **do not quote an availability %, an
> RTO/RPO, or a 100K-load number.** The *measured* facts we already have are: read
> **p95 = 2.20 ms** (p50 1.63 ms, n=60) vs Supabase p95 2.57 ms
> (`artifacts/bench/grobase-vs-supabase.json`); **24,887 live tenants held at rest
> by a 2.6 MiB data plane, `pools_open: 0`**
> (`artifacts/scale/footprint-live-24887.json`); and **10K tenants → 1 pool, 0×5xx**
> (gate `m46-share-pools-isolation.sh`). The 100K figure is an *extrapolation* of
> those, explicitly marked projected, until the run above exists.

---

## 3. The one-command path — `go-live.sh`

The infrastructure + commercial + RS256 atoms (Group A, B, and the RS256 cutover)
are the ones a script *can* orchestrate once the human has the external accounts.
`../mini-baas-infra/deploy/go-live/go-live.sh` collapses them to a single
env-driven run:

```bash
# 1. export the secrets (or: set -a; source go-live.secrets.env; set +a  — NEVER commit)
# 2. PREVIEW — renders the chart OFFLINE, validates everything, applies NOTHING:
bash deploy/go-live/go-live.sh
# 3. GO LIVE — the single command:
GO_LIVE_APPLY=1 bash deploy/go-live/go-live.sh
```

It is **DRY-RUN by default** (no `GO_LIVE_APPLY=1` = render + validate + apply
nothing; never `git push`, `npm publish`, or build/push images). It **fails fast
naming the exact missing variable** and shape-checks each — confirmed in the
script:

- `STRIPE_LIVE_KEY` must start `sk_live_` (a `sk_test_…` is rejected as the sandbox);
- `STRIPE_WEBHOOK_SECRET` must start `whsec_`;
- `RS256_JWKS_URL` must be `https://…`;
- `KUBECONFIG` must be a readable file;
- `RS256_PRIVATE_KEY` must be a PEM `… PRIVATE KEY …` or a JWK (`"kty"`).

When applied, in order it: (1) `helm upgrade --install grobase --atomic --timeout
10m` from the production chart with images/domain/TLS wired from env; (2) **flips
the B-track cloud flags ON for this release only** — names cross-checked against
`config/cloud/flags.env.cloud` so they cannot drift; the **committed baseline stays
OFF / byte-parity**; (3) does the RS256 cutover with a Kong-edge dual-accept
window (one token TTL of HS256 still valid for instant rollback); (4) runs a
post-deploy smoke against `https://$GO_LIVE_DOMAIN`. Quota goes live at
`QUOTA_STAGE=warn` (no `402`) — promote to `enforce` only after it has shadowed
(`config/cloud/README.md` R4→R5). **Rollback is one command** the script prints:
`helm -n grobase rollback grobase <PRIOR_REV>`; a failed `--atomic` upgrade
auto-rolls-back.

What `go-live.sh` is **NOT**: a cluster provisioner (bring your own k8s + DNS +
cert-manager), an image builder/pusher, or a flip of the committed baseline. Those
boundaries are intentional (`deploy/go-live/README.md` *What this directory is
NOT*).

---

## 4. What is already engineering-done

So the reader can see the atoms above are the *only* remainder, here is the
engineering surface that is gate-green today. The full /10-per-target breakdown is
in `ga-readiness-scorecard.md`; each cell there cites a gate or a measured
artifact. Highlights, every gate confirmed to exist:

**The buyable-cloud funnel.** Signup → project → key → CRUD → usage →
Stripe-meter-event is gate-green end-to-end against a *mock* Stripe —
`m94-cloud-funnel.sh`. Quota truth on a real tenant `m101-quota-realtenant.sh`;
quota enforce `m80-quota-enforce.sh`; spend/suspend enforce
`m120-spend-suspend-enforce.sh`; self-serve `/v1/tenants/me*` `m83-selfserve.sh` +
console route `m84-console-route.sh`; per-tenant telemetry export
`m100-tenant-telemetry-export.sh`; gateway query path `m102-gateway-query-path.sh`.

**The enterprise control surface (gate-complete m103–m112, + m121/m123).**
Orgs/RBAC `m103-orgs-rbac.sh` (VIEWER → 403 on `project:create`, org-scoping
control-plane-only so SHARE_POOLS density is preserved); tamper-evident audit
`m104-audit-chain.sh`; hard-erase `m105-hard-erase.sh`; IP allowlist
`m106-ip-allowlist.sh`; passkeys/WebAuthn `m107-passkeys.sh`; SOC2-lite evidence
`m108-soc2-evidence.sh`; tenant export `m109-tenant-export.sh`; SSO-OIDC
`m110-sso-oidc.sh`; SCIM `m111-scim.sh`; trust center `m112-trust-center.sh`;
Vault cred-ref `m121-credref-vault-enforce.sh`; CMEK/BYOK + crypto-shred
`m123-cmek-envelope.sh`.

**The HA composition (parts each gate-backed).** Read-availability routing
`m122-read-replica-routing.sh`; PITR `m99-pitr-restore.sh`; backup/restore
`m47-backup-restore.sh` + per-tenant backup `m87-per-tenant-backup.sh`; multi-node
shared rate-limit `m51-multinode.sh`; pooler parity `m98-pooler-parity.sh`;
per-tenant observability `m85-tenant-observability.sh`. Zero-downtime helm
RollingUpdate (≥2 replicas, `maxUnavailable:0`/`maxSurge:1`) + write-failover
*delegated* to managed Postgres — `deploy/ha/README.md`.

**The competitive moat (measured artifacts, not adjectives).** Footprint
**essential = 821.7 MiB** total RSS (`ram_mib_total` in
`artifacts/footprint-essential.json`) vs **Supabase 2884 MiB**
(`artifacts/bench/grobase-vs-supabase.json` + `supabase-footprint-breakdown.txt`) —
**3.5× lighter**; the lean **basic = 309.8 MiB** (`artifacts/footprint-basic.json`)
— **9.3× lighter**; reproducer gate `m32-footprint.sh` / `make bench-footprint`.
8 engine adapters, uniform trait, name-routed, boot-time capability-honesty check
— gate `m25-oltp-matrix.sh` + `artifacts/oltp-matrix.json`. 4 isolation models per
mount + SHARE_POOLS collapse — gate `m46-share-pools-isolation.sh`.

**The honest gaps (so this doc is not a sales sheet):**

- **[ENG]** The final TS→Rust legacy *deletion* is still blocked behind the m18
  live-traffic + shadow-parity + CI-forward gates (UNKNOWN = FAIL). Code is
  *retained*, not deleted. This is the one true remaining code item.
- **[INFRA-MEAS]** Availability %, write-failover RTO/RPO, and a clean 100K
  load-latency SLO are **unmeasured** — *no number is claimed* for any of them
  until the §2.E drills produce artifacts.
- **[LEGAL]** "SOC2 certified" is false until an auditor signs (we have m108
  *evidence*, audit-ready). The `wiki/legal/*` docs are templates until counsel
  reviews them.
- **[HUMAN] held 📌** (explicit human trigger only): RS256 live cutover, npm SDK
  publish, repo release tag/push/deploy.

---

### The shape of "done"

Your engine is built and proven. To stand up the business you: **provision the
infra (k8s + domain + TLS + SMTP), open the commercial account (Stripe + meters),
connect the identity layer (real IdP; cloud-KMS optional), get the legal sign-offs
(lawyer + auditor), staff operations, and run the three measurement drills.**
`go-live.sh` collapses the infra+commercial+RS256 atoms to one env-driven command.
Everything else on this list is a signature, an account, or a quiet load-test box —
not a line of code.
