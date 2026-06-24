# Org / Team / Group RBAC + Invitations + Zero-Knowledge Per-Environment Secrets

How a team collaborates on grobase: invite people to an **organization**, a **team**, a
project-scoped **group**, or a standalone **project**; grant **per-environment** permissions; and
let an authorized member **decrypt** that environment's secrets — without the server ever seeing a
plaintext or a private key.

Everything here is **flag-gated OFF by default** (a missing flag = byte-parity with the OSS
edition) and lives **entirely in the control plane + the client** — it never enters the data-plane
RLS GUCs or `RequestIdentity` (constraint D-026).

---

## Two planes — authorization vs decryption

```
              CONTROL PLANE (grobase, Go)                     CRYPTO PLANE (vault42, Rust)
              "WHO MAY access WHAT"  — instant                "WHO CAN decrypt"  — provisioned
  org ─┬─ team ──────────────┐                               per-environment X25519 scope keypair
       └─ (members)          ├─ project_grants ──► effective    secrets sealed to the scope PUBLIC key
  project ─┬─ group ─────────┤   (user|team|group,             scope PRIVATE key wrapped per member
           ├─ environments ──┘    role, optional env)           (GrantedScopeKey, granter-signed)
           └─ (standalone: direct user/group)
                              │ seam: user_pubkeys (wrap targets) + grant_key_wraps (provisioned?)
```

- The **control plane** decides authorization *instantly* (a grant is live the moment it's written).
- The **crypto plane** delivers *decryption capability* only when a key-holding admin **provisions**
  the member — wraps the environment's scope key to their public key. A grant is therefore
  **authorized** immediately but **decryptable** after `42ctl vault sync-keys`. This gap is inherent
  to zero-knowledge (the server cannot grant decryption; only a key-holder can) and is surfaced as an
  explicit `pending-provision` state — never silent.

---

## Entity model

| Entity | Scope | Notes |
|---|---|---|
| **Org** | top | roles owner/admin/developer/billing/viewer; optional GitHub-org link (auto-affiliates members) |
| **Project** | a grobase tenant | `org_id` nullable → `NULL` = **standalone** |
| **Environment** | within a project | dev/staging/prod; the **key-bearing scope** (its own X25519 keypair) |
| **Team** | org-scoped, spans projects | a grantee of per-(project,env) grants |
| **Group** | one project | always named `<project>'s group`; a grantee scoped to its project |
| **Grant** | (project, optional env) → role | grantee = user \| team \| group; role owner/admin/writer/reader; effective = **MAX**, TTL-aware, deny-by-default |

**Rules:** a **standalone** project invites users/groups **directly**; an **org-bound** project must
invite via a **team** (a direct project invite returns `409 "invite via a team"`). A grant with an
`env_id` is env-scoped; without one it spans all environments.

---

## Flag matrix (all default OFF)

| Flag | Unlocks | Requires |
|---|---|---|
| `ORG_MODEL_ENABLED` | orgs + org invites (043) | — |
| `RBAC_HIERARCHY_ENABLED` | teams (072) + project grants (073) + effective resolver | ORG_MODEL_ENABLED |
| `ENVIRONMENTS_ENABLED` | per-project environments (077) + scope-pubkey publish (083) | RBAC_HIERARCHY_ENABLED |
| `GROUPS_ENABLED` | project-scoped groups (078) | RBAC_HIERARCHY_ENABLED |
| `INVITES_ENABLED` | generalized team/group/project invites (080) | RBAC_HIERARCHY_ENABLED |
| `USER_PUBKEYS_ENABLED` | member pubkey registry + grant-fulfilment seam (081) | RBAC_HIERARCHY_ENABLED |
| `VAULT42_SCOPE_KEYS_ENABLED` (vault42) | scope-key wrap/get/rotate + env-secret RPCs (082, 084) | — |

Migrations **077–084**. OFF ⇒ the routes are not mounted (404) and no rows are written — byte-identical to today.

---

## The zero-knowledge per-environment secret model

The **environment** is the key-bearing scope (`scope_id = blake3(project_uuid ‖ env_name)[..16]`,
with an `epoch` for forward secrecy). Crypto reuses vault42's existing primitives — **no new
primitive, zero change to the envelope AAD**.

- **Bootstrap** (`42ctl vault env-init`): generate the scope keypair; publish the **public** key to
  the env row (`scope_pubkey`/`scope_epoch`); self-wrap the **private** key to the admin so they can
  recover it later. Secrets are then `seal`-ed to the scope public key.
- **Provision** (`42ctl vault sync-keys`): the admin recovers the scope private key (`GetScopeKey` →
  `open_scope_key`), then for each authorized member lacking a wrap — fetch their published X25519
  pubkey, `grant_scope_key` (wrap the scope key to them, signed by the admin), `WrapScopeKey` to
  vault42, and record the wrap in grobase (`/wraps`). `42ctl vault scope-status` shows
  active / pending-provision / pending-enrollment.
- **Read**: a member fetches their `GrantedScopeKey` (`GetScopeKey`), `open_scope_key` (verify the
  granter signature → unwrap with their X25519 secret) → the scope private key → `open` the secret.
- **Revoke** (`42ctl vault rotate-scope`): rotate the scope keypair (new epoch), re-seal the env's
  secrets to the new public key, re-wrap only to the remaining members. A removed member keeps
  anything already read but cannot read new-epoch revisions (forward-secure).

The **granter signature** binds `scope_id ‖ epoch ‖ member_id ‖ wrapped` with injective framing
(a separate domain tag from the envelope AAD), so the server cannot move a grant to another
scope/epoch/member, and the server verifies it **without ever decrypting**.

---

## Operational runbook (the demo)

```
42ctl org create Univers42                                  # or connect the GitHub org
42ctl team create core --org <org>
42ctl env  create --project app --name prod                 # + dev
42ctl vault env-init --org <org> --project app --env prod   # bootstrap the scope key
42ctl team grant-project --org <org> --team core --project app --env prod --role writer
42ctl team invite --org <org> --team core --email sergio@…  # sergio accepts → joins team+org
42ctl vault sync-keys --org <org> --project app --env prod  # wrap the prod scope key to members
# → sergio reads app/prod secrets; NOT app/dev (env-scoped). On removal: rotate-scope.
```

---

## Proof (gates)

Control plane (isolated, per-PR CI `rbac-gates` + nightly battery): **m162** (RBAC hierarchy),
**m166** (environments + groups + per-env grant isolation + scope-pubkey publish), **m168**
(team/group invites), **m170** (standalone direct invites + 409 org-guard), **m172** (pubkey
registry + grant-fulfilment). Crypto plane (vault42): **40** core tests (round-trip + rejects, AAD
golden vector intact), **27** server tests (wrap/get/list, cross-member-read denied, forged-grant
rejected), plus the scope-key **v14** decryption round-trip + **v15** rotation forward-secrecy
integration tests, and the self-contained live cross-repo demo `scripts/test/e2e-rbac-scope-keys-live.sh`.
Each gate proves the positive path + load-bearing rejects + **flag-OFF parity**.

---

## Security residuals (vault42 `THREAT-MODEL.md` R12–R17)

- **R12 — revocation is forward-secure only.** A removed member keeps already-read plaintext / a
  cached scope key; only post-rotation revisions are protected.
- **R13 — provisioning lag.** A live grant does not decrypt until an admin runs `sync-keys`; surfaced
  as `pending-provision`, never silent.
- **R14 — an admin is the scope's decryption root.** A current scope admin can wrap the key to any
  pubkey. Mitigations: the `pubkey_sig` proof-of-possession on the registry, every wrap audited,
  `scope-status` exposes a rogue granter.
- **R15 — registry TOFU.** The first wrap trusts the member's pubkey from the registry; mitigated by
  the self-signed `pubkey_sig` and auditing pubkey changes (out-of-band anchor is future work).
- **R16 — rotation cost.** `rotate-scope` re-seals every env secret; idempotent + epoch-tagged so a
  partial rotation is detectable and re-runnable.
- **R17 — recovery interaction.** Scope keys are recovery-wrapped only under the same explicit opt-in
  as secrets, and audited.

---

## Control-plane operator API (intentionally NOT in the public SDK spec)

Every route above is served by **tenant-control** (the Go control plane). They are
**operator/admin APIs** driven by **42ctl** — a hand-rolled REST client, not a generated SDK. They
are **not** public data-plane surfaces and a frontend never calls them.

### Why they are absent from the OpenAPI spec

`infra/config/openapi/grobase-public.json` is scoped to the **five Kong-public surfaces** the
`@grobase/js` SDK consumes — `/auth/v1`, `/rest/v1`, `/storage/v1`, `/query/v1`, `/functions/v1`.
Control-plane routes have **no precedent** in that spec: SSO and the `/v1/tenants/me*` self-serve
routes are likewise absent. These RBAC routes follow the same line, so the SDKs are **not**
regenerated for them — 42ctl owns the client, and the spec stays the SDK contract only.

### Route groups (all flag-gated; 404 when the gate is OFF)

```
# teams — internal/teams
POST   /v1/orgs/{orgId}/teams
GET    /v1/orgs/{orgId}/teams
POST   /v1/orgs/{orgId}/teams/{teamId}/members
DELETE /v1/orgs/{orgId}/teams/{teamId}/members/{userId}

# project grants + effective resolver — internal/teams + internal/pubkeys
POST   /v1/orgs/{orgId}/projects/{projectId}/grants
GET    /v1/orgs/{orgId}/projects/{projectId}/grants
DELETE /v1/orgs/{orgId}/projects/{projectId}/grants/{grantId}
GET    /v1/orgs/{orgId}/projects/{projectId}/effective
GET    /v1/orgs/{orgId}/projects/{projectId}/grants/{grantId}/fulfilled
POST   /v1/orgs/{orgId}/projects/{projectId}/grants/{grantId}/wraps

# environments — internal/environments
POST   /v1/projects/{projectId}/environments
GET    /v1/projects/{projectId}/environments
PUT    /v1/projects/{projectId}/environments/{envId}/scopekey
DELETE /v1/projects/{projectId}/environments/{envId}

# groups — internal/groups
POST   /v1/projects/{projectId}/groups
GET    /v1/projects/{projectId}/groups
POST   /v1/groups/{groupId}/members
GET    /v1/groups/{groupId}/members

# invites — internal/invites
POST   /v1/orgs/{orgId}/teams/{teamId}/invites
GET    /v1/orgs/{orgId}/teams/{teamId}/invites
POST   /v1/projects/{projectId}/invites
GET    /v1/projects/{projectId}/invites
POST   /v1/invites/accept
GET    /v1/invites/{inviteId}

# pubkey registry — internal/pubkeys
PUT    /v1/orgs/{orgId}/pubkey
GET    /v1/orgs/{orgId}/users/{userId}/pubkey
```

### Authz granularity (environments)

Env **reads** gate on `CapProjectRead`: any granted org member resolves an env's **name + PUBLIC
scope key**. Env **mutations** gate on `CapProjGrant`. Env metadata leaks nothing — the seal gates
decryption, so read access to an env row is not read access to its secrets (guarded by gate
**m166**).

---

## Storage backend: SQLite vs GrobaseStore (the live-e2e caveat)

vault42-server selects its `SecretStore` at boot: `VAULT42_STORE=sqlite` → the embedded SQLite store
(offline `nano`); otherwise → **GrobaseStore** (the connected production backend). The scope-key
crypto and the orchestration are **identical behind the trait** — only the persistence layer differs.

- **`scripts/test/e2e-rbac-scope-keys-live.sh` runs the SQLite store.** This faithfully exercises the
  new surface end-to-end: env secrets are sealed to the scope public key, stored by
  `(scope_id, epoch, path)`, and `GetEnvSecret` returns the opaque envelope to **any** authenticated
  caller (the seal is the access control). What it does *not* exercise is the data-plane persistence.
- **GrobaseStore is the production path.** vault42-server `POST`s to grobase `/query/v1`, storing
  env-secret rows in the shared `vault42_env_secrets` table (migration **084**) under the stable owner
  `vault42:env-secrets`; the mount's per-request `read_scoped` owner-scoping surfaces the same shared
  rows to every member's minted JWT. The per-user `read_scoped` isolation of vault42 blobs is proven
  independently (the vault42 user-secret store, gates m162–m165).

**To run the live e2e against GrobaseStore** (proven by composition — not run in the SQLite harness):
bring up `EDITION=query` (Postgres + Kong + `data-plane-router` + `tenant-control` + `adapter-registry`),
provision the `vault42-pg` mount with `read_scoped: true` (`infra/config/contracts/vault42.json` +
migration 084), then start vault42-server with the five GrobaseStore vars instead of
`VAULT42_STORE=sqlite`: `GROBASE_QUERY_URL` (Kong), `GROBASE_ANON_KEY`, `GROBASE_APP_KEY`,
`GROBASE_DB_ID` (the mount id), and `JWT_SECRET` (= the shared `GOTRUE_JWT_SECRET`). The same
assertions hold — the store swap changes persistence, not the crypto or the choreography.
