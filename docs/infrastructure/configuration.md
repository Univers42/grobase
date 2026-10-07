# Configuration, secrets and environments

> Configuration describes how the system behaves. Secrets prove identity or grant access.
> Infrastructure describes what exists. An environment describes where a deployment runs.
> These never mix.

The machine-readable form of this document is **[`infra/config/env/schema.json`](../../infra/config/env/schema.json)**.
It is authoritative; prose here explains it. Gate **`m214`** holds the tree to it.

---

## 1. The six categories

| Category | Means | Lives in |
|---|---|---|
| **SECRET** | Proves identity or grants access | vault42 → `.env.secrets` (gitignored) |
| **CONFIG** | Non-sensitive behaviour | `config.env` (committed) |
| **PUBLIC** | Safe in a browser — assume anyone reads it | emitted into frontend config |
| **ENVIRONMENT** | Which deployment this is | `GROBASE_ENV` |
| **INFRASTRUCTURE** | What exists | `orchestrators/compose/`, `deploy/helm/` |
| **DEPLOYMENT** | Image tag / commit | stamped at build (gate `m190`) |

A key absent from the schema defaults to CONFIG. **A SECRET must be listed** — that is
what makes "which values are secret?" answerable by a machine.

### What counts as a secret

Anything whose exposure permits authentication, authorisation, impersonation, decryption,
signing, privileged infrastructure access, database access, service-to-service auth, or
third-party API access. When unsure, it is a secret.

Two values that look alike but are not:

- `ANON_KEY` is **PUBLIC** — a signed anon JWT, shipped to browsers by design.
  `SERVICE_ROLE_KEY` is **SECRET** — it bypasses RLS entirely. Same shape, opposite class.
- `mongodb://mongo:27017` is **CONFIG** — a host and port. The same URI with
  `user:password@` is **SECRET**. The credential makes the class, not the key name.

---

## 2. Precedence — one order, no exceptions

```
config.env          (committed, CONFIG only)
   ↓  overridden by
.env.secrets        (gitignored · from vault42, or minted by `make env`)
   ↓  overridden by
.env.local          (gitignored · per-developer; never a production source)
   ↓  assembled by scripts/env/assemble-env.sh into
.env                (gitignored, mode 600 — the single file compose reads)
   ↓  interpolated into
compose `environment:`   per service, key by key
   ↓  overridden at runtime by
the process environment  (what a deploy system injects)
```

Later wins. Only `assemble-env.sh` writes `.env`; only `make env` (or a vault42 pull)
writes `.env.secrets`. Nothing else may.

**Derived values are built, not stored twice.** `generate-env.sh` composes
`DATABASE_URL`, `PGRST_DB_URI` and `ADAPTER_REGISTRY_DATABASE_URL` from
`POSTGRES_PASSWORD` / `AUTHENTICATOR_PASSWORD` plus host and database name, and writes
them into `.env.secrets`. `PG_BACKUP_DATABASE_URL` has no builder at all: compose nests
the fallback `${PG_BACKUP_DATABASE_URL:-${DATABASE_URL:?…}}`, so it is optional and
inherits. One password, one place. (`assemble-env.sh` only concatenates the three layers —
it does not derive.)

It also **withholds GitHub-token-shaped values** from `.env`: every container reads that
file, and a PAT has no business in any of them.

---

## 3. Secrets: from source of truth to process

```
          vault42  (org Univers42 · project grobase · env local|dev|staging|prod)
             │          the SOURCE OF TRUTH. Zero-knowledge: the server stores
             │          ciphertext only; the environment's scope key decrypts.
             │  make vault-pull-env        (42ctl env pull, sealed to the env key)
             ▼
        .env.secrets          gitignored · mode 600 · never committed
             │  make env  (assemble-env.sh: + config.env + .env.local, derive DSNs)
             ▼
            .env             gitignored · mode 600
             │  compose interpolation, per service, key by key
             ▼
   container environment     only the keys that service reads (gates m211 · m212)
```

Never the other way round. A production secret has no path into git:

```
vault42 → .env.production → git        ← NEVER
```

**Addressing.** `Univers42 / grobase / <environment> / <group>/<KEY>` — e.g.
`core/JWT_SECRET`, `postgres/POSTGRES_PASSWORD`, `kong/SERVICE_ROLE_KEY`. Each key's
`vault42_path` is in the schema.

**Scoping.** Secrets are per-service by consumption, not one global blob: the schema's
`consumers[]` records which services receive each key (evidence from
`docker compose --profile '*' config`), and `m211`/`m212` prove engines and scoped
services hold only what they read.

### Team access

| Environment | Team `transcendence` |
|---|---|
| `local`, `dev` | **write** |
| `staging`, `prod` | **read** |

Grants are env-scoped, so dev credentials can be rotated by the team while production
stays admin-only. Sharing is **encryption, not RBAC**: a tree pushed the personal way is
unreadable by teammates whatever their role, which is why the team path is the default
(`VAULT_ENV_PERSONAL=1` opts out).

`vendor/` holds other apps' credentials and is sealed to the pusher alone even on a team
push. Each vendor app has its **own vault42 project** (`make vault-app-projects`, `dev`
only — none has a staging or prod deployment), so two apps' secrets can never share an
environment.

Those projects are currently **empty, by construction**: no vendor app has a real env
file on disk, only `.example` templates. Each app's `scripts/seed/<app>-tenant.sh` emits
a gitignored `*-tenant.env` when provisioned, and that is what belongs in its project —
pushed from the app's own tree, not swept into grobase's. The boundary exists before the
secrets do, which is the right order.

---

## 4. Environments as boundaries

`GROBASE_ENV` ∈ `local | dev | staging | prod`, defaulted to `local` in `config.env`.

It exists because **every other check asks whether a value looks weak**, and that can
never catch a `.env` which is simply the wrong environment's file — each value in it is a
perfectly strong *dev* secret. Only a declared identity catches that.

| | local | dev | staging | prod |
|---|---|---|---|---|
| Secrets from | `make env` (minted) | vault42 | vault42 | vault42 |
| Team may write | yes | yes | no | no |
| Required secrets enforced at startup | warn | warn | **fail** | **fail** |
| `make prod-up` accepts | no | no | yes | yes |

`scripts/ops/preflight-production.sh` refuses a production bring-up unless
`GROBASE_ENV` is `staging` or `prod` (gate `m194`).

---

## 5. Compose and Docker

- **No secret carries a literal default.** Every secret-bearing entry is
  `${KEY:?unset - run make env}`, so a stack cannot boot on a credential published in
  this repo. It used to: 45 such fallbacks existed, plus 17 bare `${JWT_SECRET}`
  references that compose resolved to a **blank signing key**. Gate `m214` keeps them out.
- **No Dockerfile holds a secret** — no `ENV`/`ARG` secret, no `COPY .env`. Secrets arrive
  at **runtime**, never at build. `.dockerignore` excludes `.env*` and `secrets/` so a
  build context cannot carry them.
- **Build-time vs runtime** stay separate: an image is identical across environments, and
  the environment supplies the values (this is what keeps `m190` image provenance honest).

---

## 6. The frontend boundary

A browser receives **PUBLIC only**. An app is a declarative contract
(`infra/config/contracts/<app>.json`) whose `frontend_config` may reference just
`${KONG_URL}`, `${ANON_KEY}`, `${API_KEY}`, `${TENANT_ID}`, `${MOUNT_ID}` — the
provisioner substitutes nothing else, so a contract **cannot** emit a service key.
`m214` fails if a contract references a schema SECRET, or if a SECRET is named
`PUBLIC_*` / `VITE_*` / `NEXT_PUBLIC_*`.

Assume anything compiled into frontend JavaScript is readable by the user. Treat
`PUBLIC_API_KEY` accordingly: it is a real tenant key scoped `["read","write"]`, so it is
public *write* access to that app's mount. Minting read-only browser keys is open work —
see §10.

---

## 7. Naming

`<SUBSYSTEM>_<THING>`: `POSTGRES_PASSWORD`, `REDIS_HOST`, `JWT_SECRET`, `S3_BUCKET`.
Never a bare `SECRET`, `KEY`, `TOKEN`, `PASSWORD`, `URL`. A `*_PASSWORD`, `*_SECRET`,
`*_TOKEN`, `*_KEY` or credentialed `*_URL`/`*_URI` must be classified SECRET in the
schema — the shape is a claim about the class, and `m214` checks it.

---

## 8. Rotation

A leaked credential is **compromised**, and deleting the file does not change that:

```
detect → revoke → generate replacement → update vault42 → update consumers → verify the old one fails
```

Removal from git history is optional cleanup, **never** the remediation — a public repo
has already distributed it.

| What | How |
|---|---|
| JWT secret | `scripts/secrets/rotate-jwt.sh` — refuses without `ROTATE_JWT_FORCE=1`; keeps the old as `JWT_SECRET_PREV` so live sessions survive (gate `m210`) |
| Service token | `scripts/ops/rotate-service-token.sh` — begin → swap → finish, never printing a token (gate `m205`) |
| Engine root passwords | first boot only; live volumes need `scripts/ops/reconcile-credentials.sh` |
| A vault42 environment key | `42ctl env keys rotate` after removing a member |

Open incidents: [`incident-2026-10.md`](incident-2026-10.md).

---

## 9. Local development

```sh
git clone … && cd grobase
make env            # mints .env.secrets, assembles .env   (or: make vault-pull-env)
make hooks          # pre-commit secret scanning
make up EDITION=query
make health
```

With a vault42 account, `make vault-pull-env` replaces `make env` and gives you the
team's `local` tree byte-exact. Without one, `make env` mints a fresh independent set —
nothing blocks a first run.

### Layers of protection against committing a secret

```
developer → .gitignore → pre-commit gitleaks → CI gitleaks (whole tree)
                                             → CI trufflehog (full history, verified only)
```

`.gitignore` covers `.env*` (except the two `*.example`), `/secrets/`, keystores, `*.pem`,
`*-key.pem`, `*.p12/.pfx/.jks`, `id_rsa*`, `credentials*.json`. The gitleaks policy
allowlists **files, never directories** — a directory-wide allowlist is exactly how live
credentials sat in `vendor/` unseen for months.

---

## 10. Production, and what is still open

`make prod-up` runs preflight (refuses dev credentials, dev values and a non-prod
`GROBASE_ENV`), then brings the stack up with the prod overlay plus network segmentation.
Migrations and contract provisioning are run by hand.

Open work, honestly stated:

- **`PUBLIC_API_KEY` carries `write` scope.** Read-only browser keys are not implemented.
- **The HashiCorp Vault plane is dormant.** `secrets.yml` copies `.env` into KV and
  nothing reads it back; vault42 is the real store. It is kept, not deleted.
- **The leaked credentials of 2026-10 are not all rotated** —
  [`incident-2026-10.md`](incident-2026-10.md).
- **`docker-compose.monolith.yml` and `track-binocle.yml` still hold literal defaults.**
  Both are preserved artifacts, excluded from the compose lint, and not built from.

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `required variable POSTGRES_PASSWORD is missing a value` | no `.env` | `make env` |
| A gate fails rendering compose with its own synthetic `.env` | it must supply the required floor | source `scripts/lib/lib-required-env.sh`, call `required_env_floor <filler> <root> <skipfile>` — pass the skip-file or it overrides your sentinel |
| `no manifest for project grobase` on a teammate's pull | the tree was pushed the personal way | re-push with the team path (now default) |
| `FT_S3_KEY and FT_S3_SECRET are not set` mid-pull | the vault holds no `infra/S3_KEY`; files over 4 MiB cannot travel | `42ctl vault set infra/S3_KEY` once |
| `keys recover` reaches a stranger | an old profile seeded dead/foreign fly hosts | `make ctl42` writes the live pair |
| preflight passes but the stack uses dev values | it reads the **file** only; host shell vars override at interpolation | check your shell environment |
