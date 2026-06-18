# Grobase cloud go-live — the one-command runbook

This is the human's exact runbook for taking Grobase from **built + gate-proven**
to **LIVE on a managed cloud**. The managed-cloud code is already done and proven:

- the cloud edition composes end-to-end with all B1–B7 flags ON — gate
  **`scripts/verify/m94-cloud-funnel.sh`** (provision → key → CRUD → `tenant_usage`
  → `/me/usage` → Stripe meter event + idempotent → Kong `/v1/tenants/me` 200;
  flag-OFF parity stack proves the default stays byte-untouched);
- a **real RS256 issuer** passes Kong's RS256 jwt-plugin + tenant-control's JWKS
  verifier end-to-end, with HS→RS-forge / wrong-key / unknown-kid / `alg=none` /
  no-bearer all 401 — gate **`scripts/verify/m81-rs256-issuer.sh`**;
- the production Helm chart renders to 29 valid manifests
  (`deploy/helm/grobase`, `helm lint` + `helm template` clean).

What was **NOT** done is the set of **human atoms** no script can invent: a live
Stripe key, a k8s cluster + domain + TLS, SMTP, and the RS256 cutover. This
directory collapses all of them to: **paste 9 secrets, run one command.**

```bash
GO_LIVE_APPLY=1 bash deploy/go-live/go-live.sh
```

> **`go-live.sh` is DRY-RUN by default.** Without `GO_LIVE_APPLY=1` it renders the
> chart **offline** (no cluster contact), validates every value, prints every
> action, and applies **nothing**. Run it once with no `GO_LIVE_APPLY` to preview.
> It never `git push`es, never `npm publish`es, never builds/pushes images.

---

## Step 1 — obtain the 5 secrets (+ 4 deploy values)

Export these into the environment (or `set -a; source your-secrets.env; set +a`).
The script **fails fast naming the exact missing variable** and shape-checks each
one (`sk_live_…`, `whsec_…`, `https://…`, a readable kubeconfig, a PEM/JWK key).

| Var | What it is | Where to get it |
|---|---|---|
| `STRIPE_LIVE_KEY` | Stripe **live** secret key `sk_live_…` (B3 billing → real meter events) | Stripe Dashboard → **Developers → API keys** → *Reveal live key*. (A `sk_test_…` is the sandbox and is **rejected** — that is the m94 mock path.) |
| `STRIPE_WEBHOOK_SECRET` | Stripe signing secret `whsec_…` for the inbound webhook | Stripe Dashboard → **Developers → Webhooks** → add endpoint `https://<your-domain>/...` → *Signing secret*. Stored in the release Secret for you to wire the inbound handler (see *After go-live*). |
| `GO_LIVE_DOMAIN` | the public API hostname, e.g. `api.yourco.com` | your DNS — point an A/AAAA (or the LB's CNAME) at the cluster ingress controller. |
| `KUBECONFIG` | path to the kubeconfig for the **target** cluster | your cloud provider (`aws eks update-kubeconfig`, `gcloud container clusters get-credentials`, `doctl`, `az aks get-credentials`, …). The file must be readable. |
| `SMTP_HOST` / `SMTP_USER` / `SMTP_PASS` | transactional email (signup verify, billing receipts) | a provider (Postmark / SES / SendGrid / Mailgun). `SMTP_PASS` lands in the Secret, never a ConfigMap or a log. |
| `RS256_PRIVATE_KEY` | the JWT issuer's RSA **private** key (PEM) **or** a JWK set — a path or the literal blob | generate once: `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out issuer-rsa.pem`. Keep it in your secrets store; this is the kingdom. |
| `RS256_JWKS_URL` | the **public** JWKS endpoint (https) | the URL your issuer serves the public half at, e.g. `https://<issuer>/auth/v1/.well-known/jwks.json`. tenant-control's verifier reads keys from here (`internal/tenants/jwks.go`). |

**TLS.** The chart's Ingress references a TLS secret named `grobase-api-tls`
(override with `GO_LIVE_TLS_SECRET`). Provide it one of two ways **before**
go-live:
- **cert-manager (recommended):** install cert-manager + a ClusterIssuer; add the
  issuer annotation to the Ingress (e.g. `cert-manager.io/cluster-issuer`) — it
  provisions `grobase-api-tls` automatically from Let's Encrypt for
  `GO_LIVE_DOMAIN`.
- **bring your own cert:**
  `kubectl -n grobase create secret tls grobase-api-tls --cert=fullchain.pem --key=privkey.pem`.

**Images.** The chart pulls `ghcr.io/les-baas/mini-baas-*:1.2.0` by default
(override `GO_LIVE_IMAGE_REGISTRY` / `GO_LIVE_IMAGE_TAG`). Building & pushing
images is a **separate, human-triggered** step — `go-live.sh` only *consumes*
images that already exist in your registry.

---

## Step 2 — preview (dry-run, default), then go live

```bash
# 1. export the secrets above (or source a gitignored env file)
set -a; source go-live.secrets.env; set +a     # NEVER commit this file

# 2. PREVIEW — renders the chart offline, validates everything, applies NOTHING
bash deploy/go-live/go-live.sh

# 3. GO LIVE — the single command
GO_LIVE_APPLY=1 bash deploy/go-live/go-live.sh
```

`go-live.sh` then, in order:

0. **validates** all 9 vars (fail-fast, exact name) + shape;
1. **`helm upgrade --install grobase`** (`--atomic --timeout 10m`) from the
   production chart with images / domain / TLS / cloud flags / Secret wired from
   env — idempotent, re-runnable;
2. **flips the B-track cloud flags ON for this release only** (`METERING_ENABLED`,
   `QUOTA_*`, `BILLING_ENABLED` → live Stripe, `TENANT_SELFSERVE_ENABLED`,
   `TENANT_OBS_ENABLED`, `TENANT_BACKUP_*`, `SPEND_CAPS_ENABLED`,
   `ABUSE_GUARD_ENABLED`). The flag **names** are cross-checked against
   `config/cloud/flags.env.cloud` (the single source of truth) so the list can't
   drift. The **committed baseline stays OFF / byte-parity** — these flags live
   only in the live release's ConfigMap/Secret;
3. **RS256 cutover, safely** (see below);
4. **post-deploy smoke** against `https://$GO_LIVE_DOMAIN` (reachability +
   protected-route shape; the keyed funnel is the 4 curls in *post-deploy smoke*).

### Quota goes live at `warn`, not `enforce`

By default B2 ships at `QUOTA_STAGE=warn` / `QUOTA_ENFORCEMENT=0` — usage is
metered and overage logged, but **no `402`** is returned. This follows the
promotion ladder in `config/cloud/README.md` (R4 → R5): never surprise a paying
tenant with a hard cap before it has shadowed. Promote when ready:

```bash
GO_LIVE_QUOTA_STAGE=enforce GO_LIVE_QUOTA_ENFORCEMENT=1 \
  GO_LIVE_APPLY=1 bash deploy/go-live/go-live.sh
```

---

## RS256 cutover & rollback (the safe flip)

The headline auth change is HS256 → RS256/JWKS. The control-plane verifier
(`internal/tenants/jwt.go` + `jwks.go`) **pins to exactly one algorithm** — so
tenant-control alone cannot dual-accept. The script makes the cutover safe by
holding the dual-accept window **at the Kong edge**:

- **RS256 becomes primary:** tenant-control gets `JWT_ALG=RS256` + `JWKS_URL`
  (set in step 1). New tokens from the issuer verify RS256 (proven by m81).
- **HS256 stays accepted for one token TTL:** Kong's `authenticated` consumer
  holds **both** the existing HS256 `jwt_secrets` **and** the new RS256
  `jwt_secret`, each keyed on `iss` (`key_claim_name: iss`). Any HS256 token still
  circulating within its TTL keeps verifying — **no mass 401**.
- **Rollback is one command.** The script prints the exact line (the prior
  release revision = HS256-primary):

  ```bash
  KUBECONFIG=$KUBECONFIG helm -n grobase rollback grobase <PRIOR_REV>
  ```

  `helm upgrade --atomic` also auto-rolls-back a *failed* upgrade.

- **Removing HS256 is a SEPARATE, later human step.** After **one full token TTL**
  (`GOTRUE_JWT_EXP`, default 3600s — override `GO_LIVE_TOKEN_TTL_S`) of clean
  RS256-only traffic, remove the HS256 `jwt_secrets` from Kong and unset
  `JWT_SECRET`. Do this only once the 401 rate is flat. (The exact Kong edit + the
  gotrue/issuer options are in `wiki/security-residuals-runbook.md` §G-RS256
  *LIVE-FLIP READINESS* — the config the script applies is the one m81 proved.)

> **Issuer note.** The vendored `supabase/gotrue:v2.188.1` is **HS256-only**.
> You must run an RS256 issuer: either bump self-hosted gotrue past the 2025-07-17
> "JWT signing keys" release (`GOTRUE_JWT_KEYS` + `GOTRUE_JWT_VALID_METHODS`
> including RS256; **runs auth-schema migrations — stage + back up `auth.*` first**)
> or run the front-signer shape m81 uses. Either way, `RS256_PRIVATE_KEY` is the
> issuer's key and `RS256_JWKS_URL` is where it publishes the public half.

---

## Post-deploy smoke (the live funnel)

On apply, the script verifies the edge is reachable over TLS and that
`/v1/tenants/me` is wired + protected (a `401` without a key is the **correct**
answer). To run the full buyer journey by hand (the m94 funnel, on real infra):

```bash
BASE="https://$GO_LIVE_DOMAIN"; SVC="<your INTERNAL_SERVICE_TOKEN>"

# 1. provision a tenant
curl -s -X POST "$BASE/v1/tenants" -H "X-Service-Token: $SVC" \
  -H 'Content-Type: application/json' -d '{"id":"smoke-1","name":"smoke","plan":"nano"}'

# 2. issue an API key (returns an mbk_ key)
KEY=$(curl -s -X POST "$BASE/v1/tenants/smoke-1/keys" -H "X-Service-Token: $SVC" \
  -H 'Content-Type: application/json' -d '{"name":"smoke","scopes":["read","write","admin"]}' \
  | grep -o '"key":"mbk_[^"]*"' | cut -d'"' -f4)

# 3. CRUD via the router (200) and 4. read self-serve usage (200 + query.count)
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/v1/tenants/me/usage" -H "X-API-Key: $KEY"
```

---

## Rollback (summary)

| Situation | Action |
|---|---|
| A bad release / RS256 spike in 401s | `helm -n grobase rollback grobase <PRIOR_REV>` (printed by the script) |
| `helm upgrade` itself failed | already auto-rolled-back by `--atomic` (cluster unchanged) |
| Want the cloud features OFF entirely | `helm rollback` to the pre-go-live revision (flags revert to OFF = byte-parity) |
| Quota 402s too aggressive | re-run with `GO_LIVE_QUOTA_STAGE=warn GO_LIVE_QUOTA_ENFORCEMENT=0 GO_LIVE_APPLY=1` |

---

## After go-live (separate human steps)

These remain explicit, human-triggered actions (not automated by `go-live.sh`):

1. **Register the Stripe inbound webhook.** In the Stripe Dashboard add the
   endpoint URL on `$GO_LIVE_DOMAIN` and confirm `STRIPE_WEBHOOK_SECRET` matches.
   (B3 today is meter-event *reporting* — outbound. The inbound webhook
   *handler/verify* is the next slice; the secret is already stored in the
   release Secret so the handler can read it when wired.)
2. **Promote quota to `enforce`** once warn has shadowed cleanly (command above).
3. **Remove HS256** from Kong + unset `JWT_SECRET` after a clean token TTL.
4. **Tag / publish** anything (images, npm, git) — out of scope here, by design.

## What this directory is NOT

- Not a cluster provisioner (bring your own k8s + DNS + cert-manager).
- Not an image builder/pusher.
- Not a flip of the committed baseline — the cloud flags are turned on only in the
  live release; the repo's default compose/chart/env stay byte-parity OFF
  (`config/cloud/README.md` *Parity statement*).

## Overridable knobs (defaults are prod-sane)

`GO_LIVE_APPLY` (0) · `GO_LIVE_RELEASE` (grobase) · `GO_LIVE_NAMESPACE` (grobase) ·
`GO_LIVE_IMAGE_REGISTRY` (ghcr.io/les-baas) · `GO_LIVE_IMAGE_TAG` (1.2.0) ·
`GO_LIVE_TLS_SECRET` (grobase-api-tls) · `GO_LIVE_TOKEN_TTL_S` (3600) ·
`GO_LIVE_QUOTA_STAGE` (warn) · `GO_LIVE_QUOTA_ENFORCEMENT` (0) ·
`GO_LIVE_STRIPE_API_BASE` (https://api.stripe.com) ·
`GO_LIVE_RS256_PUBLIC_PEM` (auto-derived from a PEM private key via openssl) ·
`GO_LIVE_SPEND_RATE_QUERY_COUNT` (0.001) · `GO_LIVE_ABUSE_VELOCITY_MAX` (20) ·
`GO_LIVE_SMOKE_TIMEOUT_S` (120).
