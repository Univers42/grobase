# Operator Guide — Org/Team/Group RBAC + Email Invites + Zero-Knowledge Per-Environment Secrets

Driven by the **42ctl** CLI. You create an org, build a team, give per-environment
access, onboard a member by email, and revoke — without the server ever seeing a
plaintext secret or a private key.

Two planes do two different jobs:

- **grobase (control plane, Go)** authorizes **WHO MAY** access what — a grant is live the
  instant it is written.
- **vault42 (crypto plane, Rust)** delivers **WHO CAN** decrypt — only after a key-holding
  admin provisions the member (`vault sync-keys`).

A grant is therefore **authorized** immediately but **decryptable** later. That gap is
inherent to zero-knowledge and is surfaced explicitly (`pending-provision`), never silently.

Design: [`wiki/architecture/org-team-group-rbac.md`](wiki/architecture/org-team-group-rbac.md).

---

## 1. Prerequisites — flags (all default OFF)

Everything below is **flag-gated OFF by default**. A missing flag means the routes are not
mounted (404) and no rows are written — byte-identical to the OSS edition. Enable on the
grobase control plane (`tenant-control`):

```
ORG_MODEL_ENABLED          # orgs + org invites
RBAC_HIERARCHY_ENABLED     # teams + project grants + effective resolver (needs ORG_MODEL_ENABLED)
ENVIRONMENTS_ENABLED       # per-project environments + scope-pubkey publish
GROUPS_ENABLED             # project-scoped groups
INVITES_ENABLED            # generalized team/group/project invites
USER_PUBKEYS_ENABLED       # member pubkey registry + grant-fulfilment seam
```

And on the vault42 server:

```
VAULT42_SCOPE_KEYS_ENABLED # scope-key wrap/get/rotate RPCs
```

Backing migrations: `077_environments`, `078_groups`, `079_project_grants_ext`,
`080_invites`, `081_user_pubkeys`, `082_vault42_scope_keys`, `083_env_scope_pubkey`,
`084_vault42_env_secrets`.

Point each 42ctl identity at the two planes once:

```sh
42ctl config endpoint \
    --server    https://vault42.fly.dev \      # vault42-server (crypto plane)
    --authority https://grobase-stack.fly.dev \ # grobase (control plane)
    --grobase   https://grobase-stack.fly.dev
42ctl keys init                                 # create the local zero-knowledge identity
```

---

## 2. Standalone vs org-bound projects

A project's `org_id` decides how you invite people to it:

- **Standalone** (`org_id = NULL`) — invite users or groups **directly** to the project.
- **Org-bound** (`org_id` set) — you **must** invite via a **team**. A direct project invite
  to an org-bound project returns:

  ```
  409 "invite via a team"
  ```

(Proven by gate **m170**: standalone direct invites succeed; the org-guard returns 409.)

---

## 3. The full journey — onboard Sergio with per-env access

The exact sequence below is the one driven live by
`scripts/test/e2e-rbac-scope-keys-live.sh` (`admin` provisions, `sergio` is onboarded with
prod-only access, `vadim` stays unprovisioned).

```sh
# admin: create the org
42ctl org create --slug univers42 --name Univers42
#   id   <org-uuid>

# admin: create the team
42ctl team create --org <org> --slug core --name Core
#   id   <team-uuid>

# admin: create two environments under the project (prod + dev)
42ctl env create --project <project> --name prod
42ctl env create --project <project> --name dev
42ctl env list   --project <project>

# admin: bootstrap the scope key for each environment
#   generates the X25519 scope keypair, publishes the PUBLIC key to the env row,
#   and self-wraps the PRIVATE key to the admin
42ctl vault env-init --org <org> --project <project> --env prod
42ctl vault env-init --org <org> --project <project> --env dev

# admin: grant the team WRITER on PROD only (env-scoped — dev is untouched)
42ctl team grant-project --org <org> --team <team> --project <project> --env <prod-env-id> --role writer

# admin: seal a secret into each environment (sealed to that env's scope public key)
printf 'postgres://prod-db' | 42ctl vault set-env --org <org> --project <project> --env prod DATABASE_URL
printf 'postgres://dev-db'  | 42ctl vault set-env --org <org> --project <project> --env dev  DATABASE_URL

# admin: invite Sergio to the team by email (prints a one-time token)
42ctl team invite --org <org> --team <team> --email sergio@example.com
#   token  <one-time-token>

# Sergio: accept the invite (joins the team + org)
42ctl invite accept --token <one-time-token>

# Sergio: publish his public keys so an admin's sync-keys can wrap env keys to him
#   the private key never leaves Sergio's machine
42ctl keys enroll --org <org>

# admin: provision — wrap the prod scope key to every authorized member missing a wrap
42ctl vault sync-keys --org <org> --project <project> --env prod
```

Result, asserted by the live harness:

```sh
# Sergio reads the prod secret he was granted
42ctl vault get-env --org <org> --project <project> --env prod DATABASE_URL
#   postgres://prod-db

# Sergio is DENIED the dev secret — his grant is env-scoped to prod only
42ctl vault get-env --org <org> --project <project> --env dev DATABASE_URL
#   denied   (per-environment isolation holds)

# Vadim was never provisioned — deny-by-default
42ctl vault get-env --org <org> --project <project> --env prod DATABASE_URL
#   denied   (deny-by-default + provisioning gate)
```

(Per-env isolation + scope-pubkey publish proven by **m166**; invites by **m168**;
pubkey registry + grant-fulfilment by **m172**.)

---

## 4. The grant ≠ instant-decryption gap

A grant is authorized the instant `team grant-project` writes it — but it does **not**
decrypt until a key-holding admin runs `vault sync-keys` (only a key-holder can wrap the
scope key to a member; the server cannot grant decryption). Inspect the gap with
`vault scope-status`:

```sh
42ctl vault scope-status --org <org> --project <project> --env prod
```

The three states per authorized member:

| State | Meaning |
|---|---|
| `active` | the member has a wrapped scope key — they can decrypt now |
| `pending-provision` | authorized + has an enrolled pubkey, but no wrap yet — run `vault sync-keys` |
| `pending-enrollment` | authorized but no registered pubkey — the member must run `keys enroll` first |

`sync-keys` is the bridge: it recovers the scope private key, then for each authorized
member lacking a wrap, fetches their published pubkey and wraps the scope key to them.

---

## 5. Revocation (forward-secure)

Revocation is two steps — drop the membership/grant in the control plane, then rotate the
scope in the crypto plane:

```sh
# control plane: remove the member from the team (the grant flows through team membership)
# (drop team_members, or revoke the specific grant)

# crypto plane: rotate the scope keypair to a new epoch, re-seal every env secret to the
#   new public key, and re-wrap ONLY to the remaining authorized members
42ctl vault rotate-scope --org <org> --project <project> --env prod

# write the next revision under the new epoch
printf 'postgres://prod-db-ROTATED' | 42ctl vault set-env --org <org> --project <project> --env prod DATABASE_URL
```

Forward-secure semantics, asserted by the live harness and by vault42 gate **v15**:

- A removed member **keeps** anything they already read (or a cached scope key) — this
  cannot be undone (`THREAT-MODEL.md` R12).
- A removed member is **blocked on the new revision** — they cannot read post-rotation
  (new-epoch) secrets.

---

## 6. Troubleshooting

- **`env-init` refuses to re-init an environment** — an already-bootstrapped env has a
  scope key. Re-bootstrapping would orphan the existing wraps and secrets; to roll the key
  use `vault rotate-scope`, not `env-init`.
- **`sync-keys` did not wrap to a member** — it **skips** any authorized member with no
  enrolled pubkey. They show as `pending-enrollment` in `scope-status`; have them run
  `42ctl keys enroll --org <org>`, then re-run `sync-keys`.
- **`get-env` returns "denied"** — either the member is **not provisioned** for that env
  (no wrap yet — check `scope-status`, run `sync-keys`) or they are reading the **wrong
  env** (a prod-only grant cannot read dev).
- **A direct project invite returns `409 "invite via a team"`** — the project is org-bound;
  invite via a team (section 2).
- **Authorized but still cannot decrypt** — remember the two-plane model: grobase
  authorizes **WHO MAY**, vault42 delivers **WHO CAN** decrypt. A live grant with no wrap is
  `pending-provision`, not a bug.

---

Design: [`wiki/architecture/org-team-group-rbac.md`](wiki/architecture/org-team-group-rbac.md).
Proof: control-plane gates **m162** (RBAC hierarchy), **m166** (environments + groups +
per-env grants + scope-pubkey publish), **m168** (invites), **m170** (standalone + 409
org-guard), **m172** (pubkey registry); vault42 **v14** (decryption round-trip), **v15**
(rotation forward-secrecy); plus the live cross-repo end-to-end
`scripts/test/e2e-rbac-scope-keys-live.sh`.
