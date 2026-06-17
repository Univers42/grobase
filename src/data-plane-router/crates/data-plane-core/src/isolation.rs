//! Tenant isolation strategy (gap G5).
//!
//! A mount declares how its tenants are kept apart on the wire-stable
//! `isolation` string field. This module parses that string **once** into a
//! typed [`Isolation`] enum and, given a mount + identity, produces an
//! engine-neutral [`ScopeDirective`] that each adapter consumes on its own
//! terms (Postgres `search_path`, Mongo/MySQL database selection, Redis key
//! prefix). No string literal of the strategy escapes this file — every other
//! call site speaks the enum.
//!
//! PARITY INVARIANT: a mount with absent / empty / unknown `isolation`
//! deserialises to [`Isolation::SharedRls`], the historical default, and
//! [`Isolation::scope`] then returns [`ScopeDirective::None`] for every engine
//! — i.e. zero behaviour change for every mount that exists today. Validation
//! of *allowed* values is the Go provisioning plane's job; the hot path here
//! degrades safely rather than erroring, so a typo can never 500 a request.

use crate::{DatabaseMount, RequestIdentity};
use serde::{Deserialize, Serialize};

/// Longest sanitized tenant fragment we embed in a schema / namespace name.
/// PostgreSQL identifiers cap at 63 bytes. The schema is laid out as
/// `tenant_` (7) + fragment (≤40) + `_` (1) + 8 hex hash chars = ≤56 bytes,
/// comfortably under PG's 63 cap. The fragment is capped lower (40, was 50) to
/// make room for the collision-free hash suffix. Shared by `search_path`
/// lowering and provisioning DDL.
const MAX_SCHEMA_FRAGMENT: usize = 40;

/// The selectable per-mount tenant isolation strategy.
///
/// `Copy` + small: it lives by value on the pool and is matched on the hot
/// path with no allocation or dynamic dispatch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Isolation {
    /// One shared schema; rows separated by RLS + `owner_id`. The default and
    /// the only strategy that existed before G5.
    #[default]
    SharedRls,
    /// A distinct schema per tenant (`tenant_<id>`); pin `search_path` to it.
    SchemaPerTenant,
    /// A distinct database/DSN per tenant; the resolver must supply a tenant
    /// DSN (no fall back to a shared one).
    DbPerTenant,
    /// The mount IS one tenant's database (an external client DB the platform
    /// dashboards, e.g. a customer's Supabase project): no per-row
    /// `owner_id` scoping on writes and no `owner_id` DDL synthesis — the
    /// tables belong to the tenant wholesale and predate the platform.
    ///
    /// SAFETY: dropping row-level owner scoping cannot cross tenants by
    /// construction — tenant gating already happened upstream at key→mount
    /// resolution (`mount.tenant_id == caller tenant`); a foreign tenant's
    /// key never resolves this mount at all.
    TenantOwned,
}

impl Isolation {
    /// Parse a mount's wire `isolation` field. NEVER errors: `None`, empty, or
    /// any unrecognised value degrades to [`Isolation::SharedRls`] so an
    /// existing or mistyped mount behaves exactly as it does today. The set of
    /// *accepted* values is enforced upstream in Go provisioning, not here.
    #[must_use]
    pub fn from_mount(isolation: Option<&str>) -> Self {
        match isolation.map(str::trim) {
            Some("schema_per_tenant") => Self::SchemaPerTenant,
            Some("db_per_tenant") => Self::DbPerTenant,
            Some("tenant_owned") => Self::TenantOwned,
            // "shared_rls", "", unknown, None → the safe default.
            _ => Self::SharedRls,
        }
    }

    /// Whether the platform owner-scopes rows on this mount (insert injects
    /// `owner_id`; update/delete filter on it; DDL synthesizes the column).
    /// Everything except [`Isolation::TenantOwned`] — pools gate every
    /// owner-touching site on this single predicate.
    #[must_use]
    pub fn owner_scoped(&self) -> bool {
        !matches!(self, Self::TenantOwned)
    }

    /// The engine-neutral per-request scoping instruction for this strategy,
    /// given the mount + verified identity. A branchless `match` (no heap, no
    /// `Box<dyn>`): the only allocation is the schema/namespace string, and
    /// only for the strategies that actually need one.
    ///
    /// * [`Isolation::SharedRls`] → always [`ScopeDirective::None`] (parity).
    /// * [`Isolation::SchemaPerTenant`] →
    ///   - PostgreSQL: [`ScopeDirective::SetSearchPath`] — Postgres is the only
    ///     engine with a true `search_path`, set per transaction.
    ///   - MySQL / MongoDB / Redis: [`ScopeDirective::UseNamespace`] — a
    ///     per-tenant database (`USE`/`client.database`) or key-prefix segment.
    ///   - HTTP / unknown: [`ScopeDirective::None`] (no schema concept).
    /// * [`Isolation::DbPerTenant`] → [`ScopeDirective::None`]: the per-tenant
    ///   separation is the DSN itself, resolved before the pool is opened, so
    ///   no per-request scoping is needed.
    ///
    /// If the tenant id sanitizes to empty we fall back to `None` rather than
    /// pinning a bogus schema — the shared-schema behaviour, which is safe.
    #[must_use]
    pub fn scope(&self, mount: &DatabaseMount, _identity: &RequestIdentity) -> ScopeDirective {
        match self {
            Self::SharedRls | Self::DbPerTenant | Self::TenantOwned => ScopeDirective::None,
            Self::SchemaPerTenant => match EngineClass::of(&mount.engine) {
                EngineClass::SearchPath => match safe_schema(&mount.tenant_id) {
                    Some(schema) => ScopeDirective::SetSearchPath { schema },
                    None => ScopeDirective::None,
                },
                EngineClass::Namespace => match safe_schema(&mount.tenant_id) {
                    Some(namespace) => ScopeDirective::UseNamespace { namespace },
                    None => ScopeDirective::None,
                },
                EngineClass::Unscoped => ScopeDirective::None,
            },
        }
    }
}

/// Engine-neutral per-request scoping instruction produced by
/// [`Isolation::scope`] and consumed by each adapter on its own terms.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScopeDirective {
    /// No per-request scoping (shared schema / db-per-tenant / unscoped engine).
    None,
    /// Relational engines: pin the connection `search_path` to `schema`
    /// (Postgres). The schema name is pre-sanitized to `[a-z0-9_]`.
    SetSearchPath { schema: String },
    /// Document / KV engines: select the per-tenant `namespace` (a Mongo
    /// database, or a Redis key-prefix segment). Pre-sanitized to `[a-z0-9_]`.
    UseNamespace { namespace: String },
}

/// How an engine realises per-tenant schema isolation, derived once from the
/// mount's `engine` string, so the scope `match` stays branchless and no engine
/// name literal leaks elsewhere. Named after the *directive* it produces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EngineClass {
    /// Postgres: a true `search_path` set per transaction.
    SearchPath,
    /// MySQL (`USE db`), MongoDB (`client.database`), Redis (key prefix): a
    /// per-tenant namespace selection.
    Namespace,
    /// HTTP / unknown: no schema concept, no per-request scoping.
    Unscoped,
}

impl EngineClass {
    fn of(engine: &str) -> Self {
        match engine {
            "postgresql" => Self::SearchPath,
            // DynamoDB joins the Namespace family (same owner/key-prefix model as
            // redis): schema_per_tenant produces a UseNamespace the adapter
            // consumes as a partition-key prefix segment `<namespace>:<owner>`.
            // PARITY: the `_ => Unscoped` arm means an unknown engine already
            // degrades to a no-op, so adding "dynamodb" changes behaviour ONLY
            // for a mount whose engine is literally "dynamodb" AND isolation is
            // schema_per_tenant — which cannot exist until the dynamodb feature
            // is built and such a mount is provisioned. Every mount today is
            // byte-identical.
            "mysql" | "mongodb" | "redis" | "dynamodb" => Self::Namespace,
            // Unknown engines (and http) get no per-request scoping, which is
            // the safe (no-op) behaviour.
            _ => Self::Unscoped,
        }
    }
}

/// Derive the safe per-tenant schema / namespace identifier from a tenant id.
///
/// Layout: `tenant_<fragment>_<hash8>`, where
///   * `<fragment>` is the *human-readable* part: the id lower-cased, every byte
///     outside `[a-z0-9_]` replaced with `_`, leading/trailing `_` trimmed, then
///     capped at [`MAX_SCHEMA_FRAGMENT`] chars; and
///   * `<hash8>` is the first 8 hex chars of a stable hash of the **raw** (un-
///     sanitized) tenant id ([`tenant_hash8`]).
///
/// The hash suffix makes the mapping **collision-free**: the fragment alone is
/// lossy (sanitization folds `t-acme`/`t.acme`/`T-ACME` together, and the cap
/// folds ids that share a 40-char prefix), so two DISTINCT raw ids could map to
/// the SAME fragment. Because `pool_key` keys on the RAW tenant id, those two
/// tenants would get separate pools pointing at the SAME schema — a cross-tenant
/// leak. Suffixing the hash of the raw id guarantees distinct raw ids → distinct
/// schemas, ALWAYS, while keeping the fragment for human/operator readability.
///
/// The result is a fixed, safe identifier — callers may interpolate it into a
/// `SET search_path` or `USE` statement (which cannot bind parameters) without
/// injection risk. Truncation of the fragment is byte-safe ONLY because the
/// char→`_`/lowercase mapping runs *before* the `.take(...)`, so every retained
/// byte is already in `[a-z0-9_]` (single-byte ASCII).
///
/// Returns `None` if the id sanitizes to empty, signalling the caller to leave
/// the connection on its default schema (the safe, shared behaviour).
///
/// This is the single source of truth shared by the PG `search_path` lowering,
/// the Mongo/Redis namespace selection, and provisioning DDL.
#[must_use]
pub fn safe_schema(tenant_id: &str) -> Option<String> {
    let mapped: String = tenant_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect();
    let trimmed = mapped.trim_matches('_');
    if trimmed.is_empty() {
        return None;
    }
    // Mapping precedes truncation, so each retained char is ASCII → byte-safe.
    let fragment: String = trimmed.chars().take(MAX_SCHEMA_FRAGMENT).collect();
    let hash8 = tenant_hash8(tenant_id);
    Some(format!("tenant_{fragment}_{hash8}"))
}

/// First 8 hex chars of a stable 64-bit FNV-1a hash of the **raw** tenant id.
///
/// FNV-1a is chosen over a crypto hash deliberately: this is a *collision-
/// avoidance* tag for namespacing, NOT a security primitive, so we want a fixed,
/// dependency-free, allocation-free function with good dispersion over short
/// ids. (No `sha2`/`blake` dependency is pulled into `data-plane-core` for this.)
/// The constant is the published 64-bit FNV offset basis / prime, so the value
/// is stable across builds and machines — the same id always hashes the same.
fn tenant_hash8(raw: &str) -> String {
    const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut hash = FNV_OFFSET;
    for byte in raw.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    // 32 high bits → exactly 8 lowercase hex chars, zero-padded.
    format!("{:08x}", (hash >> 32) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CredentialRef, IdentitySource, PoolPolicy};

    fn mount(engine: &str, tenant: &str, isolation: Option<&str>) -> DatabaseMount {
        DatabaseMount {
            id: "db1".into(),
            tenant_id: tenant.into(),
            project_id: None,
            engine: engine.into(),
            name: "n".into(),
            credential_ref: CredentialRef {
                provider: "adapter-registry".into(),
                reference: "r".into(),
                version: "1".into(),
            },
            pool_policy: PoolPolicy::default(),
            capability_overrides: None,
            inline_dsn: None,
            isolation: isolation.map(str::to_string),
            replica_inline_dsn: None,
            read_replica_route: false,
        }
    }

    fn identity() -> RequestIdentity {
        RequestIdentity {
            tenant_id: "acme".into(),
            project_id: None,
            app_id: None,
            user_id: None,
            roles: vec![],
            scopes: vec![],
            source: IdentitySource::Test,
        }
    }

    // ── from_mount: the parse-once contract ──────────────────────────────────

    #[test]
    fn from_mount_defaults_safely() {
        // None / empty / whitespace / unknown all degrade to SharedRls.
        assert_eq!(Isolation::from_mount(None), Isolation::SharedRls);
        assert_eq!(Isolation::from_mount(Some("")), Isolation::SharedRls);
        assert_eq!(Isolation::from_mount(Some("   ")), Isolation::SharedRls);
        assert_eq!(
            Isolation::from_mount(Some("nonsense")),
            Isolation::SharedRls
        );
        assert_eq!(
            Isolation::from_mount(Some("SCHEMA_PER_TENANT")),
            Isolation::SharedRls
        );
    }

    #[test]
    fn tenant_owned_parses_scopes_none_and_disables_owner_scoping() {
        // The 4th mode: an external client DB wholly owned by one tenant.
        assert_eq!(
            Isolation::from_mount(Some("tenant_owned")),
            Isolation::TenantOwned
        );
        assert_eq!(
            Isolation::from_mount(Some(" tenant_owned ")),
            Isolation::TenantOwned
        );
        let m = mount("postgresql", "gourmand", Some("tenant_owned"));
        assert_eq!(
            Isolation::TenantOwned.scope(&m, &identity()),
            ScopeDirective::None
        );
        assert!(!Isolation::TenantOwned.owner_scoped());
        // Every pre-existing mode keeps owner scoping (parity invariant).
        for scoped in [
            Isolation::SharedRls,
            Isolation::SchemaPerTenant,
            Isolation::DbPerTenant,
        ] {
            assert!(scoped.owner_scoped(), "{scoped:?}");
        }
    }

    #[test]
    fn from_mount_parses_known_values() {
        assert_eq!(
            Isolation::from_mount(Some("shared_rls")),
            Isolation::SharedRls
        );
        assert_eq!(
            Isolation::from_mount(Some("schema_per_tenant")),
            Isolation::SchemaPerTenant
        );
        assert_eq!(
            Isolation::from_mount(Some(" schema_per_tenant ")),
            Isolation::SchemaPerTenant
        );
        assert_eq!(
            Isolation::from_mount(Some("db_per_tenant")),
            Isolation::DbPerTenant
        );
    }

    #[test]
    fn default_is_shared_rls() {
        assert_eq!(Isolation::default(), Isolation::SharedRls);
    }

    // ── scope: the strategy × engine-class table ─────────────────────────────

    #[test]
    fn shared_rls_never_scopes() {
        let id = identity();
        for engine in ["postgresql", "mysql", "mongodb", "redis", "http", "weirddb"] {
            let m = mount(engine, "acme", Some("shared_rls"));
            assert_eq!(
                Isolation::SharedRls.scope(&m, &id),
                ScopeDirective::None,
                "shared_rls must be a no-op for engine {engine}"
            );
        }
    }

    #[test]
    fn db_per_tenant_never_scopes() {
        let id = identity();
        for engine in ["postgresql", "mysql", "mongodb", "redis", "http"] {
            let m = mount(engine, "acme", Some("db_per_tenant"));
            assert_eq!(
                Isolation::DbPerTenant.scope(&m, &id),
                ScopeDirective::None,
                "db_per_tenant scoping lives in the DSN, not per-request ({engine})"
            );
        }
    }

    #[test]
    fn schema_per_tenant_scope_table() {
        let id = identity();
        // The derived schema name carries the collision-free hash suffix; assert
        // against `safe_schema` (the single source of truth) rather than a brittle
        // literal so the engine-class routing — not the hash format — is the test.
        let expected = safe_schema("acme").unwrap();
        // postgres → SetSearchPath (the only engine with a true search_path)
        let pg = mount("postgresql", "acme", Some("schema_per_tenant"));
        assert_eq!(
            Isolation::SchemaPerTenant.scope(&pg, &id),
            ScopeDirective::SetSearchPath {
                schema: expected.clone()
            },
            "postgresql"
        );
        // mysql + mongodb + redis + dynamodb → UseNamespace (per-tenant
        // database / key-prefix segment)
        for engine in ["mysql", "mongodb", "redis", "dynamodb"] {
            let m = mount(engine, "acme", Some("schema_per_tenant"));
            assert_eq!(
                Isolation::SchemaPerTenant.scope(&m, &id),
                ScopeDirective::UseNamespace {
                    namespace: expected.clone()
                },
                "namespace engine {engine}"
            );
        }
        // http (and unknown) → None
        for engine in ["http", "weirddb"] {
            let m = mount(engine, "acme", Some("schema_per_tenant"));
            assert_eq!(
                Isolation::SchemaPerTenant.scope(&m, &id),
                ScopeDirective::None,
                "unscoped engine {engine}"
            );
        }
    }

    #[test]
    fn schema_per_tenant_empty_tenant_degrades_to_none() {
        let id = identity();
        // A tenant id that sanitizes to empty → no scoping (shared behaviour),
        // never a bogus schema, on every engine class.
        for engine in ["postgresql", "mongodb", "redis"] {
            let m = mount(engine, "---", Some("schema_per_tenant"));
            assert_eq!(
                Isolation::SchemaPerTenant.scope(&m, &id),
                ScopeDirective::None,
                "empty-after-sanitize tenant on {engine}"
            );
        }
    }

    // ── safe_schema: derivation, neutralization, truncation, empty ───────────

    #[test]
    fn safe_schema_derives_prefixed_name() {
        // `tenant_<fragment>_<hash8>`: assert the human-readable prefix and the
        // 8-hex-char suffix shape, not a brittle full literal (the hash value is
        // covered by the stability + collision-free tests below).
        let s = safe_schema("acme").unwrap();
        assert!(s.starts_with("tenant_acme_"), "{s}");
        assert_suffix_is_hash8(&s);
        // slugs / uuids with separators sanitize to underscores + lower-case.
        let s = safe_schema("t-Acme_2").unwrap();
        assert!(s.starts_with("tenant_t_acme_2_"), "{s}");
        assert_suffix_is_hash8(&s);
        let s = safe_schema("00000000-0000-4000-8000-000000000003").unwrap();
        assert!(
            s.starts_with("tenant_00000000_0000_4000_8000_000000000003_"),
            "{s}"
        );
        assert_suffix_is_hash8(&s);
    }

    /// Every derived schema ends with `_` + 8 lowercase hex chars (the hash tag).
    fn assert_suffix_is_hash8(s: &str) {
        let hash = s.rsplit('_').next().unwrap();
        assert_eq!(hash.len(), 8, "hash suffix is 8 chars: {s}");
        assert!(
            hash.chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "hash suffix is lowercase hex: {s}"
        );
    }

    #[test]
    fn safe_schema_neutralizes_injection() {
        let s = safe_schema("a; DROP SCHEMA public; --").unwrap();
        assert!(
            s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
            "{s}"
        );
        assert!(s.starts_with("tenant_a"), "{s}");
    }

    #[test]
    fn safe_schema_truncates_long_fragment() {
        let long = "a".repeat(200);
        let s = safe_schema(&long).unwrap();
        // tenant_ (7) + fragment (≤40) + '_' (1) + hash8 (8) = ≤56, under PG's 63 cap.
        assert_eq!(s.len(), "tenant_".len() + MAX_SCHEMA_FRAGMENT + 1 + 8);
        assert!(
            s.len() <= 63,
            "must fit PG's 63-byte identifier cap: {} ({s})",
            s.len()
        );
        assert!(s.starts_with("tenant_aaaa"));
        assert_suffix_is_hash8(&s);
    }

    #[test]
    fn safe_schema_is_collision_free_for_previously_colliding_ids() {
        // Before the hash suffix these all sanitized to the SAME `tenant_t_acme`,
        // letting two DISTINCT tenants share one schema (cross-tenant leak). They
        // must now produce DIFFERENT schema names.
        let a = safe_schema("t-acme").unwrap();
        let b = safe_schema("t.acme").unwrap();
        let c = safe_schema("T-ACME").unwrap();
        assert_ne!(a, b, "t-acme vs t.acme must not collide");
        assert_ne!(a, c, "t-acme vs T-ACME must not collide");
        assert_ne!(b, c, "t.acme vs T-ACME must not collide");
        // Two ids sharing a >40-char prefix (folded together by truncation pre-hash)
        // must also stay distinct via the suffix.
        let long_a = format!("{}-A", "x".repeat(60));
        let long_b = format!("{}-B", "x".repeat(60));
        assert_ne!(
            safe_schema(&long_a).unwrap(),
            safe_schema(&long_b).unwrap(),
            "long ids sharing a 40-char prefix must not collide"
        );
    }

    #[test]
    fn safe_schema_is_stable_across_calls() {
        // The same raw id always maps to the same schema (no nondeterminism).
        assert_eq!(safe_schema("acme"), safe_schema("acme"));
        assert_eq!(
            safe_schema("00000000-0000-4000-8000-000000000003"),
            safe_schema("00000000-0000-4000-8000-000000000003")
        );
    }

    #[test]
    fn safe_schema_empty_is_none() {
        assert_eq!(safe_schema(""), None);
        assert_eq!(safe_schema("---"), None);
        assert_eq!(safe_schema("___"), None);
    }
}
