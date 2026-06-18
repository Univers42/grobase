# Design D1 — Organizations / Teams / Members / Invites / RBAC

> **Status:** DESIGN-ONLY (no code written). The keystone of Track-D (enterprise layer) in
> [`.claude/plans/managed-cloud-enterprise.md`](../../../.claude/plans/managed-cloud-enterprise.md) §D1
> (slices D1.1–D1.7b). Authored grounded in the live control-plane source; every claim cites a file
> read at design time. Implements decision **D-026** ("org-scoping stays control-plane to preserve
> SHARE_POOLS").
>
> **The whole design exists to add a multi-user layer BETWEEN a human and a project — without ever
> touching the request identity or the RLS GUCs.** Flag-gated-OFF = byte-parity is the law; this
> design preserves it by construction (§1, §7).

Legend: ⬜ to-do · 🟡 in-progress · ✅ done · ⛔ blocked

| Slice | What | Migration / file | Flag | Status |
|---|---|---|---|---|
| D1.1 | Org data model + service CRUD | `043_orgs.sql`, `internal/orgs/{models,service,handler}.go` | `ORG_MODEL_ENABLED` | ⬜ |
| D1.2 | Membership + RBAC capability matrix | `043_orgs.sql` (org_members), `internal/orgs/rbac.go` | `ORG_MODEL_ENABLED` | ⬜ |
| D1.3 | Invite → accept (sha256-hashed token) | `043_orgs.sql` (org_invites), `internal/orgs/invite.go` | `ORG_MODEL_ENABLED` | ⬜ |
| D1.4 | Org-scoped project provisioning (wraps reconciler) | `internal/orgs/provision.go` | `ORG_MODEL_ENABLED` | ⬜ |
| D1.5 | Per-org billing rollup | `044_org_billing.sql`, `internal/orgs/rollup.go` | `ORG_BILLING_ROLLUP_ENABLED` | ⬜ |
| GATE | m92 — positive + load-bearing reject + flag-OFF parity | `scripts/verify/m92-org-rbac.sh` | — | ⬜ |

---

## 1. The load-bearing constraint (read this first — everything obeys it)

**Org-scoping lives ENTIRELY in the control plane. It NEVER enters `RequestIdentity`, the RLS GUCs,
or the data-plane pool key.** This is not a convenience — it is the load-bearing decision that keeps
the proven 24,887-tenant → 1-pool (`SHARE_POOLS`) result byte-untouched
([memory `project-baas-scale-program`]; gate `scripts/verify/m46-share-pools-isolation.sh`).

### 1.1 What the data plane sees today (and must keep seeing, identically)

The Rust data plane's per-request identity is `RequestIdentity`
(`docker/services/data-plane-router/crates/data-plane-core/src/identity.rs:13-23`):

```rust
pub struct RequestIdentity {
    pub tenant_id: String,            // the project = the only isolation key
    pub project_id: Option<String>,
    pub app_id: Option<String>,
    pub user_id: Option<String>,
    pub roles: Vec<String>,
    pub scopes: Vec<String>,
    pub source: IdentitySource,
}
```

There is **no `org_id` field** and this design **adds none**. Per-request RLS in Postgres derives
the isolation key from exactly three sources (`scripts/migrations/postgresql/016_unify_rls.sql:34-42`):

```sql
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS UUID ... AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id',
    NULLIF(current_setting('app.current_tenant_id', true), ''),
    auth.current_user_id()::text
  )::uuid;
$$;
```

None of those three is org-derived. **The org never appears in the JWT claims, never in the
`app.current_tenant_id` GUC, never in the pool key.** Pools are keyed by `(engine, tenant, isolation)`
and `SHARE_POOLS` collapses single-owner `shared_rls` mounts onto one pool regardless of tenant count
([memory `project-baas-scale-program` FIX 2/3]; `crate::pools_shared()`). **Adding rows to three new
control-plane tables changes none of those inputs**, so a data-plane request is byte-identical with
`ORG_MODEL_ENABLED` ON or OFF. The m92 gate proves this directly (§5, arm C2).

### 1.2 The layering — orgs sit ABOVE tenants, not inside the request

```
 ┌──────────────────────────────────────────────────────────────────┐
 │  CONTROL PLANE  (Go, tenant-control)  — where ALL org logic lives  │
 │                                                                    │
 │   orgs ──< org_members >── (human users, GoTrue uuid)              │
 │     │         (role: owner/admin/developer/billing/viewer)          │
 │     │                                                              │
 │     └──< org_id FK ──┐                                             │
 │                      ▼                                             │
 │            public.tenants  (= "projects" — UNCHANGED model)        │
 │                      │  slug, owner_user_id, plan, status, metadata │
 └──────────────────────┼─────────────────────────────────────────────┘
                        │  org membership → RBAC capability → gates a
                        │  CONTROL-PLANE route. The CALL it authorizes is
                        │  the EXISTING reconciler (Reconcile(StackSpec)).
                        ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │  DATA PLANE (Rust)  — sees ONLY tenant_id (a project slug).        │
 │  RequestIdentity unchanged. RLS GUC unchanged. Pool key unchanged. │
 │  It has no idea an org exists. THAT is the parity guarantee.       │
 └──────────────────────────────────────────────────────────────────┘
```

A "project" in product language **is** a `public.tenants` row (slug = `tenant_id`), confirmed by the
tenants model (`internal/tenants/models.go:18-34`, "the SLUG is the tenant identifier across the
product surface"). The org is the *new* parent. The relationship is **one nullable FK column added
to `tenants` (`org_id`)** — additive, default NULL, so every existing tenant is "org-less" exactly as
today. **No existing column is renamed, dropped, or read differently.**

### 1.3 Authorization is a control-plane gate, never a data-plane PDP change

Org RBAC decides **"may user U perform control-plane action A in org O?"** (e.g. provision a project,
invite a member, change the org plan). It is enforced in the Go HTTP layer, exactly where the
service-token guard and the self-serve scope guard already live
(`internal/tenants/handler.go:70-78` `requireServiceToken`; `internal/tenants/selfserve.go:177-184`
`requireScope`). It **does not touch the data-plane ABAC PDP** (`internal/provision/permission_engine.go`,
the per-mount owner-scoped role/policy seam) — that PDP keeps governing *data* access per request,
unchanged. Org RBAC governs *who may ask the control plane to act*; the ABAC PDP governs *what the
resulting project's data requests may do*. Two different planes, two different questions, no overlap.

---

## 2. Data model

Two additive migrations, both following the **exact** house pattern of `040_tenant_usage.sql` /
`041_tenant_billing.sql` / `042_tenant_backups.sql` / `045_tenant_safety.sql`:
`schema_migrations` version guard, `CREATE TABLE IF NOT EXISTS`, RLS enabled, per-tenant/per-org
isolation policy, explicit grants, idempotent, manual gated DOWN block. **Migration 043 and 044 are
the next free numbers** — `045_tenant_safety.sql:22-24` explicitly reserves them: *"Migration number
045 is deliberately chosen to leave 043/044 free for the planned D1 org model (043 org data model,
044 per-org billing rollup)."*

### 2.1 Migration `043_orgs.sql` — orgs, members, invites

```sql
-- ADDITIVE ONLY. With ORG_MODEL_ENABLED OFF (default) the /v1/orgs routes are
-- never mounted, so nothing writes these tables → they stay empty = byte-parity
-- (same story as 040/041/042/045). The ONE change to an existing object is an
-- ADD COLUMN IF NOT EXISTS tenants.org_id (nullable, default NULL) — additive,
-- back-compatible, read by NOTHING on the request path.

-- ── orgs: the new root entity above tenants(=projects) ──────────────────────
CREATE TABLE IF NOT EXISTS public.orgs (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          TEXT        NOT NULL UNIQUE
                CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{1,62}$'),   -- same charset as tenants.slug
  name          TEXT        NOT NULL,
  plan          TEXT        NOT NULL DEFAULT 'free',           -- org-level tier (rolls down to projects)
  status        TEXT        NOT NULL DEFAULT 'active'
                CHECK (status IN ('active','suspended','deleted')),
  metadata      JSONB       NOT NULL DEFAULT '{}'::jsonb,
  created_by    TEXT,                                          -- GoTrue user uuid of the creator
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── org_members: a human user's role within an org ──────────────────────────
-- user_id is the GoTrue user uuid (the SAME id space as tenants.owner_user_id).
-- role is the RBAC role (§3). UNIQUE(org_id,user_id) = one role per user per org.
CREATE TABLE IF NOT EXISTS public.org_members (
  org_id        UUID        NOT NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
  user_id       TEXT        NOT NULL,
  role          TEXT        NOT NULL DEFAULT 'viewer'
                CHECK (role IN ('owner','admin','developer','billing','viewer')),
  invited_by    TEXT,                                          -- user_id of the inviter (audit)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, user_id)
);
CREATE INDEX IF NOT EXISTS org_members_user_idx ON public.org_members (user_id);

-- ── org_invites: an outstanding email invitation, token sha256-hashed ───────
-- token_hash stores ONLY lower-hex sha256(cleartext_token) — the cleartext is
-- returned ONCE at issue time and emailed, NEVER persisted (same discipline as
-- tenant_api_keys.key_hash, internal/tenants/service.go:236-291). A high-entropy
-- token → fast hash (SHA-256), per kernel rule #7 / D-026.
CREATE TABLE IF NOT EXISTS public.org_invites (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        UUID        NOT NULL REFERENCES public.orgs(id) ON DELETE CASCADE,
  email         TEXT        NOT NULL,
  role          TEXT        NOT NULL DEFAULT 'viewer'
                CHECK (role IN ('owner','admin','developer','billing','viewer')),
  token_hash    TEXT        NOT NULL,                          -- lower-hex sha256(token); UNIQUE
  invited_by    TEXT        NOT NULL,                          -- user_id of the inviter
  status        TEXT        NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','accepted','revoked','expired')),
  expires_at    TIMESTAMPTZ NOT NULL,
  accepted_by   TEXT,                                          -- user_id who accepted (audit)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  accepted_at   TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS org_invites_token_hash_key ON public.org_invites (token_hash);
CREATE INDEX IF NOT EXISTS org_invites_org_pending_idx
  ON public.org_invites (org_id) WHERE status = 'pending';
-- prevent two live invites for the same (org,email): partial unique on pending.
CREATE UNIQUE INDEX IF NOT EXISTS org_invites_org_email_pending_key
  ON public.org_invites (org_id, lower(email)) WHERE status = 'pending';

-- ── the ONE existing-object change: link tenants(=projects) to an org ────────
-- Nullable, default NULL → every existing tenant stays org-less = today's shape.
-- Read by NO request-path code (the data plane never selects it). ON DELETE SET
-- NULL so deleting an org orphans projects to org-less rather than destroying data.
ALTER TABLE public.tenants
  ADD COLUMN IF NOT EXISTS org_id UUID REFERENCES public.orgs(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS tenants_org_idx ON public.tenants (org_id) WHERE org_id IS NOT NULL;
```

**RLS (house pattern, mirrors 040–045).** Orgs are NOT `tenant_id`-keyed, so the policy keys on the
caller's **user_id** (the GUC `auth.current_user_id()`, already defined and granted in
`016_unify_rls.sql:50`), scoped through membership. The control-plane service runs as the BYPASSRLS
`service_role` (the same writer role the abuse/backup/billing services use,
`041_tenant_billing.sql:64-65`), so service writes are unaffected; the RLS is the second wall behind
the Go capability check for any future tenant-facing direct read:

```sql
ALTER TABLE public.orgs        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.org_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.org_invites ENABLE ROW LEVEL SECURITY;

-- a user may see orgs they are a member of
CREATE POLICY orgs_member_visibility ON public.orgs FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.org_members m
           WHERE m.org_id = orgs.id AND m.user_id = auth.current_user_id()::text));
-- a user may see the membership + invites of orgs they belong to
CREATE POLICY org_members_self_org ON public.org_members FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.org_members m2
           WHERE m2.org_id = org_members.org_id AND m2.user_id = auth.current_user_id()::text));
CREATE POLICY org_invites_self_org ON public.org_invites FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.org_members m
           WHERE m.org_id = org_invites.org_id AND m.user_id = auth.current_user_id()::text));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.orgs        TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.org_members TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.org_invites TO authenticated, service_role;
```

> **Note on the org RLS GUC:** it reads `auth.current_user_id()` — a *user* identity that already
> exists (`016_unify_rls.sql:50`). It does **not** introduce any org concept into
> `auth.current_tenant_id()`, so the per-request tenant isolation function is byte-unchanged. This is
> the SQL-level proof of §1.1.

### 2.2 Migration `044_org_billing.sql` — per-org billing rollup

Mirrors `041_tenant_billing.sql` exactly (one Stripe identity per org; usage rolls UP from the
project rows, **per-project qty preserved**, never re-metered):

```sql
-- ADDITIVE ONLY. Flag ORG_BILLING_ROLLUP_ENABLED OFF (default) → no writer runs
-- → table empty = byte-parity. The org rollup READS public.tenant_usage (040,
-- per-project, the SINGLE source of usage truth) for every project where
-- tenants.org_id = this org, SUMs by metric, and maps the ORG (not each project)
-- to a single Stripe customer. Per-project tenant_usage rows are NEVER mutated —
-- the rollup is a read-only aggregation, so B1 metering parity is untouched.
CREATE TABLE IF NOT EXISTS public.org_billing (
  org_id                 UUID        PRIMARY KEY REFERENCES public.orgs(id) ON DELETE CASCADE,
  stripe_customer_id     TEXT        NOT NULL DEFAULT '',
  stripe_subscription_id TEXT        NOT NULL DEFAULT '',
  plan                   TEXT        NOT NULL DEFAULT '',
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- one row per (org, metric, window) already reported to Stripe → idempotent
-- re-tick (mirrors billing_reported, 041_tenant_billing.sql:48-54).
CREATE TABLE IF NOT EXISTS public.org_billing_reported (
  idempotency_key TEXT        PRIMARY KEY,   -- sha256("<org_id>|<metric>|<window_ms>")
  org_id          UUID        NOT NULL,
  metric          TEXT        NOT NULL,
  qty             BIGINT      NOT NULL DEFAULT 0,
  reported_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS org_billing_reported_org_idx
  ON public.org_billing_reported (org_id, reported_at);

ALTER TABLE public.org_billing          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.org_billing_reported ENABLE ROW LEVEL SECURITY;
-- visible to org members (billing/admin/owner gate enforced in Go; RLS = 2nd wall)
CREATE POLICY org_billing_member_visibility ON public.org_billing FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.org_members m
           WHERE m.org_id = org_billing.org_id AND m.user_id = auth.current_user_id()::text));
GRANT SELECT, INSERT, UPDATE ON public.org_billing          TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON public.org_billing_reported TO authenticated, service_role;
```

**Coexistence with B3 per-tenant billing:** the two are mutually exclusive per project by construction
— a project with `org_id IS NOT NULL` is billed via its org's `org_billing`; a project with
`org_id IS NULL` keeps the existing per-tenant `tenant_billing` path (B3). The rollup writer skips
org-less projects; the B3 reporter skips org-owned projects (one extra `WHERE org_id IS NULL` join
predicate). Neither path double-bills, and the per-project `tenant_usage` numbers stay the single
source of truth.

---

## 3. RBAC capability matrix

Five org roles, gating **control-plane routes only**. The matrix is a static table in
`internal/orgs/rbac.go` (one source of truth — kernel rule #8), checked by a `requireCapability`
guard that mirrors `requireServiceToken` (`internal/tenants/handler.go:70-78`) and `requireScope`
(`internal/tenants/selfserve.go:177-184`).

| Capability (control-plane action) | owner | admin | developer | billing | viewer |
|---|:--:|:--:|:--:|:--:|:--:|
| `org:read` (view org, members, projects) | ✅ | ✅ | ✅ | ✅ | ✅ |
| `org:update` (rename, metadata) | ✅ | ✅ | — | — | — |
| `org:delete` | ✅ | — | — | — | — |
| `member:invite` | ✅ | ✅ | — | — | — |
| `member:remove` | ✅ | ✅ | — | — | — |
| `member:role:set` | ✅ | ✅¹ | — | — | — |
| `project:create` (provision a project) | ✅ | ✅ | ✅ | — | — |
| `project:read` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `project:delete` | ✅ | ✅ | — | — | — |
| `project:keys` (issue/revoke project API keys) | ✅ | ✅ | ✅ | — | — |
| `billing:read` (usage rollup, invoices) | ✅ | ✅ | — | ✅ | — |
| `billing:manage` (change org plan, payment method) | ✅ | — | — | ✅ | — |

¹ `admin` may set roles **up to admin** but may not create/demote another `owner` (the owner is the
break-glass anchor — see D1.7b). `owner` has every capability unconditionally.

**How it gates a route — without touching the data-plane ABAC PDP.** Each org handler resolves the
caller's user_id (from the GoTrue JWT, via the existing `JWTVerifier`,
`internal/tenants/handler.go:220` / `internal/tenants/selfserve.go:91`), looks up `org_members.role`
for `(org_id, user_id)`, and checks the matrix. A miss → **403** (the load-bearing reject). This is a
pure control-plane decision: the matrix is consulted **before** the handler ever calls the reconciler
or the tenant service, and the call it ultimately authorizes (`Reconcile(StackSpec)`) is byte-identical
to the call `/v1/provision` makes today (`internal/tenants/handler.go:178-189`). The data-plane PDP
(`internal/provision/permission_engine.go`) is never consulted for an org decision and is never
modified — it continues to seed/own the per-mount owner-scoped role+policy on the provisioned project,
exactly as it does now (`internal/tenants/service.go:660-686` `seedDefaultRole`).

```go
// internal/orgs/rbac.go — the SINGLE source of truth for the matrix.
var capabilities = map[string]map[Role]bool{
    "project:create": {RoleOwner: true, RoleAdmin: true, RoleDeveloper: true},
    "member:invite":  {RoleOwner: true, RoleAdmin: true},
    "billing:manage": {RoleOwner: true, RoleBilling: true},
    // … one entry per capability above …
}
func Can(role Role, cap string) bool { return capabilities[cap][role] }
```

---

## 4. Routes

A new package `internal/orgs/` owning `/v1/orgs*`, mounted from `cmd/tenant-control/main.go`
**exactly the way `abuseguard.Mount` / `backup.Mount` are** — gated on `ORG_MODEL_ENABLED`, default
OFF → never mounted → 404 → byte-parity (`cmd/tenant-control/main.go:159-208`).

### 4.1 The mount (composition root)

```go
// cmd/tenant-control/main.go — added alongside the other flag-gated mounts.
// FLAG-GATED OFF = PARITY: orgs.Mount is called ONLY when ORG_MODEL_ENABLED is
// truthy. When OFF (default) Mount is never called, none of the /v1/orgs* routes
// exist, no orgs/org_members/org_invites row is ever written — byte-identical to
// today (same discipline as TENANT_SELFSERVE_ENABLED / TENANT_BACKUP_ENABLED /
// ABUSE_GUARD_ENABLED). The org handlers REUSE the existing reconciler + tenant
// service + jwtVerifier — no new data path, just a new authorization gate above
// the existing provision call.
if envBool("ORG_MODEL_ENABLED") {
    osvc := orgs.NewService(db, log)
    orgs.Mount(mux, osvc, svc, reconciler, jwtVerifier, cfg.ServiceToken)
    log.Info("organizations API enabled (/v1/orgs*)")
} else {
    log.Info("organizations API disabled (ORG_MODEL_ENABLED off) — /v1/orgs* not mounted")
}
```

### 4.2 Route table

| Method + path | Capability | Auth | Notes |
|---|---|---|---|
| `POST /v1/orgs` | (creates) | JWT | creator becomes `owner` member atomically |
| `GET /v1/orgs` | `org:read` | JWT | orgs the caller is a member of |
| `GET /v1/orgs/{orgId}` | `org:read` | JWT | |
| `PATCH /v1/orgs/{orgId}` | `org:update` | JWT | name/metadata |
| `DELETE /v1/orgs/{orgId}` | `org:delete` | JWT | soft-delete (status=deleted); projects → org_id SET NULL |
| `GET /v1/orgs/{orgId}/members` | `org:read` | JWT | |
| `POST /v1/orgs/{orgId}/invites` | `member:invite` | JWT | issues sha256-token, returns cleartext ONCE |
| `GET /v1/orgs/{orgId}/invites` | `org:read` | JWT | pending invites (redacted; no token) |
| `DELETE /v1/orgs/{orgId}/invites/{inviteId}` | `member:invite` | JWT | revoke a pending invite |
| `POST /v1/orgs/invites/accept` | (token) | JWT | body `{token}`; resolves org+role, adds membership |
| `PATCH /v1/orgs/{orgId}/members/{userId}` | `member:role:set` | JWT | change a member's role |
| `DELETE /v1/orgs/{orgId}/members/{userId}` | `member:remove` | JWT | (never the last owner — 409) |
| `POST /v1/orgs/{orgId}/projects` | `project:create` | JWT | **org-scoped provision (wraps reconciler)** |
| `GET /v1/orgs/{orgId}/projects` | `project:read` | JWT | tenants WHERE org_id = {orgId} |
| `GET /v1/orgs/{orgId}/usage` | `billing:read` | JWT | rollup over member projects (D1.5) |

> **Route disjointness:** `net/http`'s most-specific-pattern precedence keeps the static
> `/v1/orgs/invites/accept` literal disjoint from the `/v1/orgs/{orgId}` wildcard (the SAME mechanism
> that keeps `/v1/tenants/me*` disjoint from `/v1/tenants/{id}`,
> `internal/tenants/handler.go:49-52`).

### 4.3 Org-scoped project provisioning (D1.4) — wraps the existing reconciler verbatim

`POST /v1/orgs/{orgId}/projects` is the heart of the no-rewrite discipline. It does NOT reimplement
provisioning; it **authorizes, then delegates to the EXISTING reconciler**:

```go
// internal/orgs/provision.go (handler body, abridged)
func (rt *orgRoutes) createProject(w http.ResponseWriter, r *http.Request) {
    userID, ok := rt.authJWT(w, r)                          // existing JWTVerifier
    if !ok { return }
    orgID := r.PathValue("orgId")
    role, ok := rt.svc.MemberRole(r.Context(), orgID, userID)  // org_members lookup
    if !ok || !rbac.Can(role, "project:create") {
        shared.WriteError(w, http.StatusForbidden, "forbidden",
            "your org role may not create projects"); return   // ← LOAD-BEARING REJECT
    }
    var req tenants.ProvisionRequest
    json.NewDecoder(http.MaxBytesReader(w, r.Body, provision.MaxRequestBodyBytes)).Decode(&req)
    if err := req.Validate(); err != nil { /* 400 */ }
    spec := req.Compile()                                   // EXISTING compile, unchanged
    out, err := rt.reconciler.Reconcile(r.Context(), spec)  // EXISTING reconciler, unchanged
    // … then ONE extra control-plane write: stamp tenants.org_id = orgID …
    rt.svc.AttachProjectToOrg(r.Context(), out.Tenant.Slug, orgID)
    shared.WriteJSON(w, provision.HTTPStatus(out.Outcome, out.APIKey != nil), out)
}
```

The only difference from the existing `/v1/provision` path
(`internal/tenants/handler.go:161-198`) is: (1) the capability gate **before** the call, and (2) one
additive `UPDATE public.tenants SET org_id = $1 WHERE slug = $2` **after** it. The reconciler, the
`StackSpec`, the mount registration, the per-mount ABAC seeding, the `RequestIdentity` the resulting
project's data requests carry — all unchanged. **The provisioned project is an ordinary tenant; the
data plane cannot tell it belongs to an org.**

---

## 5. Gate m92 — `scripts/verify/m92-org-rbac.sh`

Follows the m83/m87 three-arm structure (`scripts/verify/m83-selfserve.sh`,
`scripts/verify/m87-per-tenant-backup.sh`): boot a tenant-control built FROM CURRENT source,
`ORG_MODEL_ENABLED=1` on one instance and unset on a second; exercise positive, **load-bearing
reject**, and **flag-OFF parity** arms; every arm `fail`s loudly with a body excerpt. The gate must
**not pass vacuously** (kernel `/baas-wave` discipline) — each reject arm asserts a *specific* status
on a *real* request.

### Arm A — POSITIVE (the full org lifecycle → org-scoped project)

1. `POST /v1/orgs` as user **U1** (JWT) → 201, U1 is `owner`. Assert membership row.
2. `POST /v1/orgs/{org}/invites` `{email:U2, role:developer}` → 201; capture the **cleartext token
   ONCE**; assert the DB stores only `token_hash = sha256(token)` (query `org_invites`, assert the
   cleartext is absent and the hash matches `printf %s "$token" | sha256sum`).
3. `POST /v1/orgs/invites/accept` `{token}` as **U2** (JWT) → 200; assert `org_members` now has U2 as
   `developer`; assert the invite row flips `status=accepted`.
4. `POST /v1/orgs/{org}/projects` as U2 (developer, has `project:create`) → 201; assert a new
   `public.tenants` row exists with `org_id = {org}`; assert the returned tenant provisions a real
   mount through the reconciler (status `created`/`complete`, an API key minted ONCE).

### Arm B — LOAD-BEARING REJECT (three distinct denials, each a specific status on a real request)

- **B1 · viewer cannot create a project.** Invite+accept **U3** as `viewer`; `POST
  /v1/orgs/{org}/projects` as U3 → **403** `forbidden`. Assert NO new `tenants` row appeared (count
  before == count after). *(Proves the RBAC matrix gates `project:create`.)*
- **B2 · cross-org isolation.** Create a second org **OrgB** owned by **U4** (U1/U2/U3 are NOT
  members). `GET /v1/orgs/{OrgB}` as U2 → **403/404** (member visibility miss). `POST
  /v1/orgs/{OrgB}/projects` as U2 → **403**. `GET /v1/orgs/{OrgB}/members` as U2 → **403/404**.
  Assert U2 can still operate fully in its OWN org (positive control). *(Proves a member of org A can
  never touch org B — by membership lookup, not by guessable id.)*
- **B3 · last-owner protection.** `DELETE /v1/orgs/{org}/members/{U1}` (the sole owner) → **409**
  `cannot remove the last owner`. *(Proves break-glass anchoring, D1.7b precondition.)*
- **B4 · token integrity.** `POST /v1/orgs/invites/accept` with a **wrong/replayed/expired** token →
  **401/410**; accepting an already-accepted token a second time → **409**. *(Proves the sha256 token
  is single-use and unforgeable.)*

### Arm C — FLAG-OFF PARITY (the CRITICAL data-plane byte-parity probe)

- **C1 · routes absent when OFF.** On a SECOND tenant-control with `ORG_MODEL_ENABLED` **unset**,
  every `/v1/orgs*` route → **404** (route not mounted), while the pre-existing admin routes
  (`POST /v1/tenants`, `GET /v1/tenants/{id}` with service token, `POST /v1/provision`) **still 200**
  — byte-identical to today. *(Same assertion shape as m83 arm C,
  `scripts/verify/m83-selfserve.sh:359-365`.)*
- **C2 · DATA-PLANE REQUEST IDENTITY + POOL-SHARING IS BYTE-UNCHANGED ON vs OFF.** This is the arm
  the load-bearing constraint lives or dies on:
  1. Provision the SAME project two ways: once via `POST /v1/provision` on the OFF instance
     (org-less), once via `POST /v1/orgs/{org}/projects` on the ON instance (org-owned). Both go
     through the identical reconciler.
  2. Issue an API key for each; drive an identical data-plane CRUD request (`/v1/{mount}/{table}`)
     through each project's key against the Rust data plane.
  3. Assert the **`RequestIdentity` the data plane resolves is field-for-field identical** — capture
     the data plane's identity echo / debug log; assert it carries `tenant_id` (the project slug),
     and **no `org_id` field exists** (it is not in the struct, `identity.rs:13-23`).
  4. Assert the **RLS GUC** the request sets (`app.current_tenant_id` / the `request.jwt.claims
     tenant_id`) is the project slug in BOTH cases — never the org id (`016_unify_rls.sql:34-42`).
  5. Assert **pool count is identical** ON vs OFF: with `SHARE_POOLS=1`, both org-owned and org-less
     shared_rls projects collapse onto the same single pool (reuse the pool-count probe from
     `scripts/verify/m46-share-pools-isolation.sh`). *(Proves orgs add ZERO pools — the 24,887→1
     result is untouched.)*
  6. Optional belt-and-braces: a `pg_dump --schema-only` (or `\d+` of `public.tenants`) on a stack
     with `ORG_MODEL_ENABLED` OFF but migration 043 applied shows `org_id` exists but is NULL for
     every row, and `auth.current_tenant_id()`'s body is unchanged → the schema addition is inert on
     the request path.

**Gate exit:** all three arms green → emit the JSONL receipt via `lib/log.sh` (kernel rule #11) with
a message stating: positive lifecycle works; viewer-reject + cross-org-reject + last-owner + token
integrity all enforced; and **`ORG_MODEL_ENABLED` ON vs OFF yields byte-identical RequestIdentity +
RLS GUC + pool count** (the load-bearing parity claim, measured not asserted — kernel rule #4).

---

## 6. Human / $$ atoms

**None.** This slice is pure code + SQL migration + a bash gate, all runnable on the local Docker
stack with no external account, credential, or spend:

- The org model (043) and rollup (044) are local Postgres migrations.
- Invite tokens are generated + hashed in-process (SHA-256, `crypto/sha256` — same as
  `internal/tenants/service.go` key hashing); **no email provider is required for the gate** — m92
  accepts the cleartext token returned by the issue call directly (the actual email *delivery* is the
  EXISTING Mailpit/SMTP path, already wired, not new infrastructure).
- Per-org billing **rollup** (044) is a read-only local aggregation over `tenant_usage`; the LIVE
  Stripe push is explicitly **out of scope** for D1 (it is B7.4/B7.5 / D4.9, which carry their own
  Stripe human-atom). D1.5 only writes the local `org_billing` map, exactly as B4a's
  `updateBillingPlan` writes the local `tenant_billing` map without calling Stripe
  (`internal/tenants/selfserve.go:518-530`).

The standing human atoms from the plan (Stripe live account, domain/TLS, SOC2 auditor) are **not**
touched by D1 and are listed in `.claude/plans/managed-cloud-enterprise.md` §"Human / $$ atoms".

---

## 7. Why this is byte-parity (the closing argument)

1. **Three new tables + one nullable column.** Migrations 043/044 are `CREATE TABLE IF NOT EXISTS` +
   one `ADD COLUMN IF NOT EXISTS tenants.org_id` (nullable, default NULL). No existing object is
   dropped/renamed; no existing column is read differently. Identical additive discipline to
   040/041/042/045 (each of which states "changes NO existing behavior").
2. **OFF = no routes.** `ORG_MODEL_ENABLED` default OFF → `orgs.Mount` never called → `/v1/orgs*`
   404 → no org row ever written. Identical to the `TENANT_SELFSERVE_ENABLED` / `TENANT_BACKUP_ENABLED`
   / `ABUSE_GUARD_ENABLED` gates (`cmd/tenant-control/main.go:133-208`).
3. **The data plane never learns about orgs.** `RequestIdentity` gains no field
   (`identity.rs:13-23`); `auth.current_tenant_id()` reads no org input
   (`016_unify_rls.sql:34-42`); the pool key (`engine,tenant,isolation`) is unchanged →
   `SHARE_POOLS` collapse is unchanged. m92 arm C2 proves this by measurement.
4. **Provisioning is delegation, not reimplementation.** Org-scoped project creation calls the
   EXISTING `Reconcile(StackSpec)` (`internal/tenants/handler.go:178-189`) with the EXISTING
   `Compile()` mapping; the only additions are a capability gate before and an `org_id` stamp after.
5. **Authorization is a control-plane gate, not a PDP change.** The RBAC matrix gates Go HTTP
   handlers (like `requireServiceToken` / `requireScope`); the data-plane ABAC PDP
   (`permission_engine.go`) is never consulted for an org decision and never modified.

The result: with the flag OFF (and even with 043/044 applied), the entire stack — control plane API
surface, data-plane request path, RLS, pool topology — is byte-identical to the pre-D1 baseline. The
org layer is *purely additive context above the project*, exactly as decision D-026 requires.
