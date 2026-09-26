# A6 Security Residuals — Human-Supervised Runbooks

> Companion to [`security-audit-asvs.md`](./security-audit-asvs.md) §3 (the 7 open residuals) and the A6
> roadmap row. Authored 2026-06-13 from a read-only research fan-out that ranked all 7 residuals by
> **value × autonomous-safety**.
>
> **Two residuals were closed autonomously** (additive, flag-gated **OFF** = byte-parity baseline,
> provable by isolated scratch gates): **G-ReadAudit** (`DATA_PLANE_AUDIT_READS`, gate `m72`) and
> **G-QoS slice A** rows-per-query cap (`max_rows`, gate `m73`). See the tracker ([`remediation-tracker-2025-07-14.md`](./remediation-tracker-2025-07-14.md)).
>
> **The five below were deferred to human-supervised waves** — each is **cross-repo** and/or **touches
> the live login flow** or would **re-network the shared stack**. Each runbook is *prove-on-an-isolated-
> scratch-scope first, flip the live thing last*. Run each with the security-review skill.
>
> **Status 2026-09-26:** G-Vault and G-Net are done in the repo, and the service-token half of
> G-Rotate is done. Their sections below say what remains, all of it an operator step. G-ReadAudit
> (m72) and G-QoS slice A (m73) now run nightly.

| Residual | ASVS value | State | What is left |
|---|---|---|---|
| **G-RS256** | MED | Verify side shipped, m81 proves a real RS256 issuer | The coordinated issuer + Kong + verifier flip (human, live login) |
| **G-Vault** | MED | Done in code (m121, nightly) | Move existing max-tier mounts to Vault refs (operator) |
| **G-Net** | MED | Done for compose, default in `make prod-up` (m66) | Enable the Helm NetworkPolicies on a real cluster |
| **G-Hdr** | LOW | Verifier shipped, flag off | Signers in every caller, then the live flip |
| **G-Rotate** | LOW | Service-token half done (m205, m68) | `JWT_SECRET` half: gotrue + PostgREST dual key, staging first |

Priority order for what is left: **G-RS256** (highest value, headline) → the G-Vault mount move → the G-Net Helm policies → **G-Hdr** → **G-Rotate (JWT half)**. The cross-repo/live-login halves of Net/Hdr/Rotate are lowest priority (LOW value, highest risk).

---

## G-RS256 — flip the JWT issuer to RS256/JWKS (the headline)

**Why it can't be flag-gated to byte-parity:** the issuer is a *global* property — GoTrue signs, Kong
validates (~21 jwt-plugin routes), and tenant-control all share `JWT_SECRET`/HS256. The **verify side**
(RS256/JWKS in `jwt.go`/`jwks.go`, OFF-by-default seam) is **already shipped and unit-proven**; only an
isolated gate + a coordinated cross-repo flip remain.

1. **PROVE-FIRST (isolated):** author `scripts/verify/mNN-rs256-issuer-isolated.sh` under
   `COMPOSE_PROJECT_NAME=rs256-probe` (throwaway network/volumes on /mnt/storage). Bring up a gotrue/IdP
   that signs RS256 + publishes `.well-known/jwks.json`, a Kong configured RS256 (`rsa_public_key` from
   that JWKS), and tenant-control with `JWT_ALG=RS256` + `JWKS_URL`. Assert: token header `alg=RS256`;
   the token validates through Kong on a real protected route (200 + correct `X-User-Id`); an HS256
   forgery signed with the RSA modulus → 401; unknown-kid → 401. **Must PASS before touching real config.**
2. **ISSUER (cross-repo/vendored):** bump `docker/services/gotrue/Dockerfile` (currently
   `supabase/gotrue:v2.188.1`, HS256-only, no RS256/JWKS env) to an image supporting asymmetric JWT +
   JWKS, or put a small JWKS-publishing signer in front; supply the private key via Vault; confirm
   `GET <issuer>/.well-known/jwks.json` returns an RSA `sig` key with a stable `kid`.
3. **KONG (`kong.yml`):** change the `authenticated` consumer `jwt_secrets` from
   `algorithm:HS256/secret:__JWT_SECRET__` to `algorithm:RS256/rsa_public_key:<PEM>` (+ a
   `__JWT_RS256_PUBKEY__` token); teach the entrypoint sed block (`docker-compose.yml` ~108–123) to
   substitute the PEM. Kong keys on `iss` → no indefinite dual-alg; plan a brief coordinated window.
4. **VERIFIER (in-repo, ready):** set `JWT_ALG=RS256` + `JWKS_URL=<issuer>/.well-known/jwks.json` for
   tenant-control (`docker-compose.yml`:1087–1088). No code change.
5. **STAGE + GATE:** full stack on staging; re-run the isolated gate + the standard login/auth m-series +
   `make playground`; assert real login → RS256 token → 200 across /rest, /query, /data, /storage,
   /realtime, /functions.
6. **CUTOVER (irreversible, explicit human go):** flip prod in ONE coordinated deploy so
   issue+validate+verify move together; watch the 401 rate; keep the HS256 path for instant rollback
   until a full token TTL (`GOTRUE_JWT_EXP=3600s`) of clean traffic elapses, then remove HS256
   `jwt_secrets`.
7. **ROLLBACK:** revert env to HS256 + restore Kong HS256 `jwt_secrets` + revert the gotrue image.

### G-RS256 — LIVE-FLIP READINESS (PROVE-FIRST step 1 is DONE)

> Status update 2026-06-14. Step 1 ("PROVE-FIRST, isolated") is **DONE and GREEN**. m64 proved
> only the tenant-control *verifier* against a stub; the new gate proves a **real RS256 ISSUER
> end-to-end** — a service that genuinely *signs* RS256 + serves a JWKS, validated *through Kong's
> RS256 jwt-plugin on a protected route* and then tenant-control's JWKS verifier. The live issuer
> cutover (steps 2–6) is now a **known, low-risk operation**. Gate:
> [`scripts/verify/m81-rs256-issuer.sh`](../../scripts/verify/m81-rs256-issuer.sh)
> (`bash scripts/verify/m81-rs256-issuer.sh`, exit 0 = PASS; scratch-only, never touches the live
> stack). Logged `m81=PASS` (PROVE).

**What m81 proves (off the wire, on $$-scratch):**

| Arm | Token (minted by the REAL issuer) | Through Kong RS256 → tenant-control | Result |
|---|---|---|---|
| ACCEPT | `alg=RS256`, `kid` in the served JWKS, signed by the issuing key | verified twice (Kong `rsa_public_key`, then tenant-control JWKS) | **201** + minted API key; Kong forwards a trusted `X-User-Id` = the verified `sub` |
| REJECT | RS→HS confusion (HS256 signed with the RSA modulus) | Kong RS256 plugin | **401** |
| REJECT | RS256 signed by an unrelated key (sig mismatch) | Kong RS256 plugin | **401** |
| REJECT | RS256 with a `kid` absent from the JWKS | Kong RS256 plugin | **401** |
| REJECT | `alg=none` downgrade | Kong RS256 plugin | **401** |
| REJECT | no bearer (negative control) | Kong jwt plugin | **401** (route is genuinely protected) |

**EXACT config the live cutover needs (proven by m81):**

1. **ISSUER (pick ONE):**
   - **(a) bump vendored gotrue** — `docker/services/gotrue/Dockerfile` `FROM supabase/gotrue:v2.188.1`
     is **HS256-only**. Asymmetric signing landed in supabase-auth's **"JWT signing keys" release
     (2025-07-17)**; a self-hosted gotrue at/after that tag signs RS256 when given a JWK *signing-key
     set* via **`GOTRUE_JWT_KEYS`** (a JSON array of JWKs incl. the RSA private key) +
     **`GOTRUE_JWT_VALID_METHODS`** including `RS256`, and serves the public half at
     `GET <issuer>/auth/v1/.well-known/jwks.json`. Note the documented self-host default is **ES256
     (EC P-256)**, not RS256 — request RS256 explicitly in the key set. Supply the private JWK via
     Vault (`GOTRUE_JWT_KEYS` from a Vault secret, never committed). **DB caveat:** bumping gotrue
     across the signing-keys release runs **auth-schema migrations on the gotrue auth DB** — stage it,
     back up `auth.*`, and confirm `GET .well-known/jwks.json` returns an RSA `sig` key with a stable
     `kid` before flipping consumers. This is the in-product, single-service path.
   - **(b) front-signer** — if the gotrue bump is undesirable, put a tiny JWKS-publishing RS256 signer
     in front (the shape m81 uses: real RSA-2048 key, `/.well-known/jwks.json`, SPKI PEM). This is the
     lower-coupling option but adds a service to operate + secure (its private key is the kingdom).
2. **KONG (`docker/services/kong/conf/kong.yml`):** in the `authenticated` consumer's `jwt_secrets`,
   change the two `algorithm: HS256 / secret: __JWT_SECRET__` entries to `algorithm: RS256` +
   `rsa_public_key: |` `<SPKI PEM>` (one per `iss` key — the GoTrue `iss` and `supabase`). Add a
   `__JWT_RS256_PUBKEY__` substitution token and teach the entrypoint `sed` block
   (`docker-compose.yml` Kong `command:`, the `-e "s|__…__|…|g"` list) to substitute the PEM
   (multi-line PEM via a file include or a `\n`-flattened token). `key_claim_name: iss` is unchanged,
   so Kong selects the RS256 credential by the token's `iss` — no indefinite dual-alg.
   **Required Kong env (already live):** `KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES: "cjson.safe"` — the
   identity `pre-function` decodes claims with `require('cjson.safe')`, which the default Lua sandbox
   blocks (m81 reproduced the 500 without it). No change needed; just don't drop it.
3. **VERIFIER (tenant-control, in-repo, NO code change):** set `JWT_ALG=RS256` +
   `JWKS_URL=<issuer>/auth/v1/.well-known/jwks.json` (`docker-compose.yml` tenant-control env). The
   seam (`internal/tenants/jwt.go` + `jwks.go`) is committed and unit- + m64- + m81-proven; OFF
   (no `JWT_ALG`) stays byte-parity HS256.
4. **COORDINATION:** the three move together in one window (issue + Kong-validate + tenant-control-verify
   share the `iss`-keyed RS256 credential). Keep the HS256 `jwt_secrets` + `JWT_SECRET` env in place for
   one full token TTL (`GOTRUE_JWT_EXP`, default 3600s) for instant rollback, then remove HS256.

> Build/run note: m81 builds tenant-control **from current source**; if the working tree is broken by
> *unrelated* in-flight work (it was at 2026-06-14 — a half-landed Track-B quota change in
> `internal/packages|metering` references `p.Quota` where the field lives on `p.Limits.Quota`, so
> `cmd/tenant-control` won't compile), the gate falls back to a **clean `git archive HEAD` export** of
> `go/control-plane` (the RS256 seam is committed + byte-identical) and **reports the fallback**. Fix
> that quota typo to restore the working-tree build; it is NOT part of G-RS256.

## G-Vault — enforce Vault-backed credentials at `SECURITY_MODE=max`

**Done in code — the plan below had already shipped; this entry was stale.** Migration `060` adds
`cred_provider`/`cred_reference`/`cred_version` with an exactly-one-of CHECK. `RegisterDatabaseRequest`
takes `credential_ref`. Under a `security_mode=max` package, `register.go` refuses an inline DSN with
`ErrPlaintextDsnForbidden` (403). The Rust `VaultProvider` resolves a ref-backed mount's DSN at query
time. Non-max tiers keep today's encrypt-at-rest path.

- Gate `m121`: max + inline → 403, 0 rows; max + `credential_ref` → 201, then the data plane reads
  through the DSN it resolved from Vault (200); baseline + inline → 201, encrypted at rest.
  2026-09-26: green on Vault 2.1.1 (`:latest`), then green on the pinned 1.21 (the stack's version).
- It now runs nightly (`nightly-proof.yml` job `vault-credref`), building both services from the
  commit. Before, nothing ran it. `M121_AR_IMAGE`/`M121_DPR_IMAGE` reuse prebuilt images locally.
- Left to a human: pointing real max-tier tenants' mounts at Vault paths (their DSNs live with them).

## G-Net — per-plane network segmentation

**Done (`feat/g-net-segmentation`, gate `m66`).** `orchestrators/compose/docker-compose.netseg.yml`
takes the engines (postgres mysql mariadb cockroach mssql mongo redis dynamodb-local) off the app bridge
onto `net-data`, and vault onto `net-vault`, with `networks: !override`. Every backend that dials an
engine joins `net-data`; the routers, the Go control plane and prometheus join `net-vault`. waf, kong,
studio, playground, loki, promtail, functions-runtime, mailpit and minio share no bridge with an
engine or vault. minio stays reachable because kong proxies presigned URLs to it.

- Dev: `make up NETSEG=1`. Prod: `make prod-up` composes it by default; `PROD_NETSEG=0` drops it.
- `m66` renders every service (all profiles) on the dev and prod stacks. It checks the placement, the
  isolation and 64 client→engine/vault edges, and probes a running segmented stack.
- Live proof, 2026-09-26, `make up PACKAGE=max NETSEG=1`: 34/34 healthchecks healthy (as before),
  13/13 Prometheus targets up, no alert firing. kong → postgres is refused by IP and query-router
  connects. m27 passes for all 8 engines; m52, m68, m204, m101-quota-realtenant and m120 are green.
- adapter-registry-go is off the app bridge too (N-22): its register/list trust an asserted tenant, so only
  its callers reach it (routers and tenant-control on net-data/net-vault, kong on `net-registry`).
- Helm: `networkPolicy.enabled` (default false) renders 8 policies in `grobase` and 4 in `mini-baas`.
  Enabling it on a cluster is a human step.

## G-Hdr — enable adapter-registry identity HMAC stack-wide

**Why deferred:** the write+unit+isolated-gate work is in-repo and reversible, but making it *effective*
means flipping `ADAPTER_REGISTRY_IDENTITY_HMAC=1` on the LIVE `adapter-registry-go` — the mount-resolution
hot path for live osionos (every `/connect` + `/databases` read). If any in-repo injector is missed —
notably the Rust `data-plane-router-rust` resolve path — the flip turns those callers into instant 401s.
Value is LOW (defense-in-depth on a path already protected by `SERVICE_TOKEN_MODE=hmac` + the write guard
+ RLS).

1. (in-repo) Add a Go signer in `tenants/provision.go` `register()`/`findMountID()`: after
   `X-Baas-Tenant-Id`, set `X-Baas-Identity-Auth = shared.ComputeServiceSignature(serviceToken,"IDENTITY",
   userID+"\n"+tenantScope,nil,now)`.
2. Add a TS twin `computeIdentityAuth(token,userId,tenantId)` in
   `src/libs/common/src/security/service-auth.ts`; attach `X-Baas-Identity-Auth` wherever
   `query.service.ts` / `rust-data-plane.proxy.ts` set `X-Service-Token` to adapter-registry.
3. **AUDIT every caller signs:** `grep -rniE 'ADAPTER_REGISTRY_URL|adapter-registry-go:3021' --include=*.ts
   --include=*.go --include=*.rs` — CRITICALLY confirm the Rust `data-plane-router-rust` resolve path
   emits the header, else it 401s on flip.
4. Extend `identity_test.go`; `go test ./internal/adapterregistry/...`.
5. ISOLATED gate: `docker compose -p idhmac-probe up -d adapter-registry-go tenant-control postgres` with
   `ADAPTER_REGISTRY_IDENTITY_HMAC=1`; assert signed→200, spoof→401, skew→401, flag-off→200.
6. Only after EVERY injector is confirmed signing, flip `ADAPTER_REGISTRY_IDENTITY_HMAC=1` on live
   adapter-registry-go and immediately smoke a real osionos `/connect` + `/query`; roll back on any 401.
7. Leave storage-router (`IDENTITY_HEADER_MODE=compat`, Kong-fronted) OUT of scope — that is the genuine
   cross-repo Kong-signing change.

## G-Rotate — atomic key-rotation (JWT_SECRET + service token, without restart)

> Note: DSN/credential rotation already ships (`registry.rs drain_pool_key` + `/v1/admin/rotate`). This
> residual is specifically `JWT_SECRET` + service-token rotation-without-restart.

**Service-token half — DONE (`feat/g-rotate-service-token`, gate `m205`, live gate `m68`):**
The Go verifiers (`serviceauth`, static and hmac) and the TS `ServiceTokenGuard` accept
`INTERNAL_SERVICE_TOKEN_PREV` / `ADAPTER_REGISTRY_SERVICE_TOKEN_PREV` besides the current token, in
constant time, and count each such use in `baas_service_token_previous_accepted_total` (alert
`PreviousServiceTokenInUse`). The Rust data plane only sends the token, so it has nothing to verify.
Compose maps the one source key `ADAPTER_REGISTRY_SERVICE_TOKEN_PREV` onto every holder. The procedure
(each step is dry run without `--apply`, prints token lengths only):
1. `bash scripts/ops/rotate-service-token.sh status` — expect "no rotation window".
2. `... begin --apply`, then `make up` with the running PACKAGE/EDITION. The new token is accepted
   everywhere; senders still send the old one.
3. `... swap --apply`, then `make up`. Senders send the new token; the old one is still accepted from
   any container not yet recreated.
4. Wait until `PreviousServiceTokenInUse` is quiet for 15 min, then `... finish --apply` and `make up`.
Limits: each `make up` recreates the containers that load `.env` (a short restart per phase, no 401s);
a token held in Vault (`SECURITY_MODE=max`) is rotated at its source, not by this script.

**JWT half (cross-repo, human + careful):**
5. Confirm vendored gotrue can sign under `JWT_SECRET` while PostgREST accepts `JWT_SECRET` + a secondary
   key (a vendored-gotrue + postgrest config change, NOT this repo's Rust/Go).
6. Stand up STAGING gotrue+postgrest (never the shared live stack); prove a session minted under the new
   secret AND one under the old both validate during the grace window, then old rejected after.
7. Wire `vault-rotate-approles`-style orchestration to bump `JWT_SECRET` + `PREV_JWT_SECRET` and trigger
   gotrue re-sign WITHOUT a hard restart — only after staging proof.
8. Update `security-audit-asvs.md` G-Rotate once both halves are gated. Do NOT run the JWT half against the
   live login flow unsupervised (kernel rule #9).
