//! Edge-case suite for `RequestIdentity` (identity.rs) and `DatabaseMount`
//! (mount.rs): owner-principal resolution, namespace resolution per isolation,
//! and pool-key determinism / collision-resistance.
//!
//! Tests only — no source logic changed. Behavior asserted against the code.

use data_plane_core::*;
use proptest::prelude::*;

// ── builders ──────────────────────────────────────────────────────────────────

fn ident(user: Option<&str>, tenant: &str) -> RequestIdentity {
    RequestIdentity {
        tenant_id: tenant.to_string(),
        project_id: None,
        app_id: None,
        user_id: user.map(str::to_string),
        roles: vec![],
        scopes: vec![],
        source: IdentitySource::Test,
    }
}

fn mount(tenant: &str, engine: &str, isolation: Option<&str>) -> DatabaseMount {
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

// ════════════════════════════════════════════════════════════════════════════
//  RequestIdentity::owner_principal + is_tenant_scoped
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn owner_principal_prefers_present_user() {
    assert_eq!(ident(Some("user-1"), "tenant-1").owner_principal(), "user-1");
}

#[test]
fn owner_principal_falls_back_to_tenant_when_user_absent() {
    assert_eq!(ident(None, "tenant-1").owner_principal(), "tenant-1");
}

#[test]
fn owner_principal_empty_string_user_stays_empty_not_tenant() {
    // Some("") is a PRESENT user — must NOT fall back to tenant.
    assert_eq!(ident(Some(""), "tenant-1").owner_principal(), "");
}

#[test]
fn owner_principal_whitespace_user_is_preserved_verbatim() {
    // A whitespace user is still "present" — no trimming in owner_principal.
    assert_eq!(ident(Some("   "), "tenant-1").owner_principal(), "   ");
}

#[test]
fn owner_principal_unicode_user_is_preserved() {
    assert_eq!(ident(Some("ユーザー"), "t").owner_principal(), "ユーザー");
}

#[test]
fn owner_principal_unicode_tenant_fallback_is_preserved() {
    assert_eq!(ident(None, "テナント").owner_principal(), "テナント");
}

#[test]
fn owner_principal_does_not_allocate_aliases_the_user() {
    // Returned &str borrows the identity's own user_id (same pointer region).
    let id = ident(Some("abc"), "t");
    let p = id.owner_principal();
    assert_eq!(p.as_ptr(), id.user_id.as_ref().unwrap().as_ptr());
}

#[test]
fn owner_principal_fallback_aliases_the_tenant() {
    let id = ident(None, "the-tenant");
    let p = id.owner_principal();
    assert_eq!(p.as_ptr(), id.tenant_id.as_ptr());
}

#[test]
fn is_tenant_scoped_true_for_normal_tenant() {
    assert!(ident(None, "acme").is_tenant_scoped());
}

#[test]
fn is_tenant_scoped_false_for_empty_tenant() {
    assert!(!ident(None, "").is_tenant_scoped());
}

#[test]
fn is_tenant_scoped_false_for_whitespace_only_tenant() {
    // is_tenant_scoped trims; an all-whitespace tenant is NOT scoped.
    assert!(!ident(None, "   ").is_tenant_scoped());
    assert!(!ident(None, "\t\n ").is_tenant_scoped());
}

#[test]
fn is_tenant_scoped_true_for_tenant_with_surrounding_whitespace() {
    // Trimming leaves a non-empty core → scoped.
    assert!(ident(None, "  acme  ").is_tenant_scoped());
}

#[test]
fn is_tenant_scoped_true_for_unicode_tenant() {
    assert!(ident(None, "名前").is_tenant_scoped());
}

#[test]
fn empty_user_with_empty_tenant_yields_empty_principal() {
    // Both empty: principal is the empty user (present) → "".
    assert_eq!(ident(Some(""), "").owner_principal(), "");
}

#[test]
fn absent_user_with_empty_tenant_yields_empty_principal() {
    assert_eq!(ident(None, "").owner_principal(), "");
}

// ════════════════════════════════════════════════════════════════════════════
//  DatabaseMount::isolation() — string → enum mapping
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn mount_isolation_none_is_shared_rls() {
    assert_eq!(mount("t", "postgresql", None).isolation(), Isolation::SharedRls);
}

#[test]
fn mount_isolation_shared_rls_string() {
    assert_eq!(
        mount("t", "postgresql", Some("shared_rls")).isolation(),
        Isolation::SharedRls
    );
}

#[test]
fn mount_isolation_schema_per_tenant_string() {
    assert_eq!(
        mount("t", "postgresql", Some("schema_per_tenant")).isolation(),
        Isolation::SchemaPerTenant
    );
}

#[test]
fn mount_isolation_db_per_tenant_string() {
    assert_eq!(
        mount("t", "postgresql", Some("db_per_tenant")).isolation(),
        Isolation::DbPerTenant
    );
}

#[test]
fn mount_isolation_tenant_owned_string() {
    assert_eq!(
        mount("t", "postgresql", Some("tenant_owned")).isolation(),
        Isolation::TenantOwned
    );
}

#[test]
fn mount_isolation_unknown_string_degrades_to_shared_rls() {
    assert_eq!(
        mount("t", "postgresql", Some("totally_bogus")).isolation(),
        Isolation::SharedRls
    );
}

#[test]
fn mount_isolation_empty_string_degrades_to_shared_rls() {
    assert_eq!(mount("t", "postgresql", Some("")).isolation(), Isolation::SharedRls);
}

#[test]
fn mount_isolation_with_surrounding_whitespace_is_trimmed() {
    assert_eq!(
        mount("t", "postgresql", Some("  schema_per_tenant  ")).isolation(),
        Isolation::SchemaPerTenant
    );
}

// ════════════════════════════════════════════════════════════════════════════
//  DatabaseMount::tenant_schema() — schema_per_tenant only, else None
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn tenant_schema_none_for_shared_rls() {
    assert_eq!(mount("acme", "postgresql", Some("shared_rls")).tenant_schema(), None);
}

#[test]
fn tenant_schema_none_for_db_per_tenant() {
    assert_eq!(mount("acme", "postgresql", Some("db_per_tenant")).tenant_schema(), None);
}

#[test]
fn tenant_schema_none_for_tenant_owned() {
    assert_eq!(mount("acme", "postgresql", Some("tenant_owned")).tenant_schema(), None);
}

#[test]
fn tenant_schema_none_when_isolation_absent() {
    assert_eq!(mount("acme", "postgresql", None).tenant_schema(), None);
}

#[test]
fn tenant_schema_present_for_schema_per_tenant() {
    let s = mount("acme", "postgresql", Some("schema_per_tenant"))
        .tenant_schema()
        .unwrap();
    assert!(s.starts_with("tenant_acme_"), "{s}");
}

#[test]
fn tenant_schema_equals_safe_schema_source_of_truth() {
    assert_eq!(
        mount("widget-co", "postgresql", Some("schema_per_tenant")).tenant_schema(),
        safe_schema("widget-co")
    );
}

#[test]
fn tenant_schema_none_when_id_sanitizes_to_empty() {
    assert_eq!(mount("---", "postgresql", Some("schema_per_tenant")).tenant_schema(), None);
}

#[test]
fn tenant_schema_for_unicode_tenant_strips_to_underscores() {
    // Non-ASCII bytes map to `_`; an all-non-ASCII id sanitizes to empty → None.
    assert_eq!(mount("名前", "postgresql", Some("schema_per_tenant")).tenant_schema(), None);
    // A mixed id keeps the ASCII run.
    let s = mount("café7", "postgresql", Some("schema_per_tenant"))
        .tenant_schema()
        .unwrap();
    assert!(s.starts_with("tenant_caf_7_") || s.starts_with("tenant_caf"), "{s}");
}

#[test]
fn tenant_schema_is_independent_of_engine() {
    // tenant_schema gates only on isolation, not the engine string.
    for engine in ["postgresql", "mysql", "mongodb", "redis", "http", "weirddb"] {
        assert_eq!(
            mount("acme", engine, Some("schema_per_tenant")).tenant_schema(),
            safe_schema("acme"),
            "engine {engine}"
        );
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  DatabaseMount::resolve_namespace() — per isolation × engine class
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn resolve_namespace_none_for_shared_rls_on_all_engines() {
    for engine in ["postgresql", "mysql", "mongodb", "redis", "http"] {
        assert_eq!(
            mount("acme", engine, Some("shared_rls")).resolve_namespace(),
            None,
            "shared_rls/{engine}"
        );
    }
}

#[test]
fn resolve_namespace_none_for_db_per_tenant() {
    for engine in ["postgresql", "mysql", "mongodb", "redis"] {
        assert_eq!(
            mount("acme", engine, Some("db_per_tenant")).resolve_namespace(),
            None,
            "db_per_tenant/{engine}"
        );
    }
}

#[test]
fn resolve_namespace_none_for_tenant_owned() {
    for engine in ["postgresql", "mysql", "mongodb"] {
        assert_eq!(
            mount("acme", engine, Some("tenant_owned")).resolve_namespace(),
            None,
            "tenant_owned/{engine}"
        );
    }
}

#[test]
fn resolve_namespace_none_for_postgresql_schema_per_tenant() {
    // Postgres uses SetSearchPath (not UseNamespace), so resolve_namespace → None.
    assert_eq!(
        mount("acme", "postgresql", Some("schema_per_tenant")).resolve_namespace(),
        None
    );
}

#[test]
fn resolve_namespace_present_for_namespace_engines_schema_per_tenant() {
    let expected = safe_schema("acme");
    for engine in ["mysql", "mongodb", "redis", "dynamodb"] {
        assert_eq!(
            mount("acme", engine, Some("schema_per_tenant")).resolve_namespace(),
            expected,
            "namespace engine {engine}"
        );
    }
}

#[test]
fn resolve_namespace_none_for_unscoped_engines_schema_per_tenant() {
    for engine in ["http", "weirddb", "cassandra"] {
        assert_eq!(
            mount("acme", engine, Some("schema_per_tenant")).resolve_namespace(),
            None,
            "unscoped engine {engine}"
        );
    }
}

#[test]
fn resolve_namespace_none_when_tenant_sanitizes_empty() {
    assert_eq!(mount("___", "mongodb", Some("schema_per_tenant")).resolve_namespace(), None);
}

#[test]
fn resolve_namespace_handles_very_long_tenant_id() {
    let long = "z".repeat(500);
    let ns = mount(&long, "mongodb", Some("schema_per_tenant"))
        .resolve_namespace()
        .unwrap();
    // Must be bounded (PG 63-byte identifier cap shape).
    assert!(ns.len() <= 63, "namespace must stay bounded: {} ({ns})", ns.len());
    assert!(ns.starts_with("tenant_zzz"), "{ns}");
}

#[test]
fn resolve_namespace_neutralizes_special_chars() {
    let ns = mount("a/b\\c:d", "redis", Some("schema_per_tenant"))
        .resolve_namespace()
        .unwrap();
    assert!(ns.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'), "{ns}");
}

// ════════════════════════════════════════════════════════════════════════════
//  DatabaseMount::pool_key() — determinism + structure
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn pool_key_is_deterministic() {
    let m = mount("acme", "postgresql", Some("shared_rls"));
    assert_eq!(m.pool_key(), m.pool_key());
}

#[test]
fn pool_key_embeds_tenant_engine_and_version() {
    let m = mount("acme", "postgresql", None);
    let k = m.pool_key();
    assert!(k.contains("acme"));
    assert!(k.contains("postgresql"));
    assert!(k.ends_with("/1"), "version is the last segment: {k}");
}

#[test]
fn pool_key_uses_default_for_absent_project() {
    let m = mount("acme", "postgresql", None);
    assert!(m.pool_key().contains("/default/"), "{}", m.pool_key());
}

#[test]
fn pool_key_uses_project_id_when_present() {
    let mut m = mount("acme", "postgresql", None);
    m.project_id = Some("proj-9".into());
    assert!(m.pool_key().contains("/proj-9/"), "{}", m.pool_key());
    assert!(!m.pool_key().contains("/default/"));
}

#[test]
fn distinct_tenants_get_distinct_pool_keys() {
    let a = mount("tenant-a", "postgresql", None);
    let b = mount("tenant-b", "postgresql", None);
    assert_ne!(a.pool_key(), b.pool_key());
}

#[test]
fn distinct_engines_get_distinct_pool_keys() {
    let a = mount("acme", "postgresql", None);
    let b = mount("acme", "mysql", None);
    assert_ne!(a.pool_key(), b.pool_key());
}

#[test]
fn distinct_credential_versions_get_distinct_pool_keys() {
    let a = mount("acme", "postgresql", None);
    let mut b = mount("acme", "postgresql", None);
    b.credential_ref.version = "2".into();
    assert_ne!(a.pool_key(), b.pool_key());
}

#[test]
fn pool_key_handles_special_chars_in_tenant() {
    // Special chars do not panic; key is still produced and deterministic.
    let m = mount("a/b/c", "postgresql", None);
    assert_eq!(m.pool_key(), m.pool_key());
}

// ════════════════════════════════════════════════════════════════════════════
//  DatabaseMount::effective_pool_key() — share semantics
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn effective_pool_key_off_equals_pool_key_for_all_isolations() {
    for iso in [None, Some("shared_rls"), Some("schema_per_tenant"), Some("db_per_tenant"), Some("tenant_owned")] {
        let m = mount("acme", "postgresql", iso);
        assert_eq!(m.effective_pool_key(false), m.pool_key(), "iso {iso:?}");
    }
}

#[test]
fn effective_pool_key_shared_rls_collapses_tenants_on_same_credential() {
    let a = mount("tenant-a", "postgresql", Some("shared_rls"));
    let b = mount("tenant-b", "postgresql", Some("shared_rls"));
    assert_ne!(a.pool_key(), b.pool_key());
    assert_eq!(a.effective_pool_key(true), b.effective_pool_key(true));
}

#[test]
fn effective_pool_key_shared_rls_does_not_leak_tenant_into_key() {
    let a = mount("tenant-secret", "postgresql", Some("shared_rls"));
    assert!(!a.effective_pool_key(true).contains("tenant-secret"));
}

#[test]
fn effective_pool_key_shared_rls_inline_dsn_collapses_by_target() {
    let mut a = mount("tenant-a", "postgresql", Some("shared_rls"));
    let mut b = mount("tenant-b", "postgresql", Some("shared_rls"));
    a.inline_dsn = Some("postgres://shared/db".into());
    b.inline_dsn = Some("postgres://shared/db".into());
    assert_eq!(a.effective_pool_key(true), b.effective_pool_key(true));
    // The DSN (a secret) must never appear in the key.
    assert!(!a.effective_pool_key(true).contains("postgres://"));
}

#[test]
fn effective_pool_key_distinct_dsns_fork_distinct_pools() {
    let mut a = mount("t", "postgresql", Some("shared_rls"));
    let mut b = mount("t", "postgresql", Some("shared_rls"));
    a.inline_dsn = Some("postgres://one/db".into());
    b.inline_dsn = Some("postgres://two/db".into());
    assert_ne!(a.effective_pool_key(true), b.effective_pool_key(true));
}

#[test]
fn effective_pool_key_empty_inline_dsn_falls_back_to_cred() {
    // An empty-string inline DSN is treated as absent → cred-based shared key.
    let mut a = mount("t", "postgresql", Some("shared_rls"));
    a.inline_dsn = Some("".into());
    let k = a.effective_pool_key(true);
    assert!(k.contains("cred:"), "empty dsn → cred key: {k}");
    assert!(!k.contains("dsn:"));
}

#[test]
fn effective_pool_key_schema_per_tenant_never_shares() {
    let a = mount("tenant-a", "postgresql", Some("schema_per_tenant"));
    let b = mount("tenant-b", "postgresql", Some("schema_per_tenant"));
    assert_ne!(a.effective_pool_key(true), b.effective_pool_key(true));
    assert_eq!(a.effective_pool_key(true), a.pool_key());
}

#[test]
fn effective_pool_key_db_per_tenant_never_shares() {
    let a = mount("tenant-a", "postgresql", Some("db_per_tenant"));
    let b = mount("tenant-b", "postgresql", Some("db_per_tenant"));
    assert_ne!(a.effective_pool_key(true), b.effective_pool_key(true));
}

#[test]
fn effective_pool_key_tenant_owned_never_shares() {
    let a = mount("tenant-a", "postgresql", Some("tenant_owned"));
    let b = mount("tenant-b", "postgresql", Some("tenant_owned"));
    assert_ne!(a.effective_pool_key(true), b.effective_pool_key(true));
    assert_eq!(a.effective_pool_key(true), a.pool_key());
}

#[test]
fn effective_pool_key_shared_rls_cred_rotation_forks_pool() {
    let a = mount("t-a", "postgresql", Some("shared_rls"));
    let mut b = mount("t-b", "postgresql", Some("shared_rls"));
    b.credential_ref.version = "2".into();
    assert_ne!(a.effective_pool_key(true), b.effective_pool_key(true));
}

#[test]
fn effective_pool_key_shared_rls_includes_engine() {
    // Two shared_rls mounts on different engines must not share a pool.
    let mut a = mount("t-a", "postgresql", Some("shared_rls"));
    let mut b = mount("t-b", "mysql", Some("shared_rls"));
    a.inline_dsn = Some("dsn://same".into());
    b.inline_dsn = Some("dsn://same".into());
    assert_ne!(
        a.effective_pool_key(true),
        b.effective_pool_key(true),
        "different engines on same DSN must not collide"
    );
}

#[test]
fn effective_pool_key_is_deterministic_in_both_modes() {
    let m = mount("acme", "postgresql", Some("shared_rls"));
    assert_eq!(m.effective_pool_key(true), m.effective_pool_key(true));
    assert_eq!(m.effective_pool_key(false), m.effective_pool_key(false));
}

// ════════════════════════════════════════════════════════════════════════════
//  read_replica_variant + replica pool keys
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn read_replica_variant_none_without_dsn() {
    assert_eq!(mount("acme", "postgresql", None).read_replica_variant(), None);
}

#[test]
fn read_replica_variant_none_for_whitespace_dsn() {
    let mut m = mount("acme", "postgresql", None);
    m.replica_inline_dsn = Some("   ".into());
    assert_eq!(m.read_replica_variant(), None);
}

#[test]
fn read_replica_variant_none_for_empty_dsn() {
    let mut m = mount("acme", "postgresql", None);
    m.replica_inline_dsn = Some("".into());
    assert_eq!(m.read_replica_variant(), None);
}

#[test]
fn read_replica_variant_sets_inline_dsn_and_route() {
    let mut m = mount("acme", "postgresql", None);
    m.replica_inline_dsn = Some("postgres://replica/db".into());
    let v = m.read_replica_variant().unwrap();
    assert_eq!(v.inline_dsn.as_deref(), Some("postgres://replica/db"));
    assert!(v.read_replica_route);
}

#[test]
fn read_replica_variant_pool_key_ends_with_ro() {
    for share in [true, false] {
        let mut m = mount("acme", "postgresql", Some("shared_rls"));
        m.replica_inline_dsn = Some("postgres://replica/db".into());
        let v = m.read_replica_variant().unwrap();
        assert!(v.effective_pool_key(share).ends_with("/ro"), "share={share}");
    }
}

#[test]
fn read_replica_variant_pool_key_differs_from_primary() {
    for share in [true, false] {
        let mut primary = mount("acme", "postgresql", Some("shared_rls"));
        primary.inline_dsn = Some("postgres://primary/db".into());
        primary.replica_inline_dsn = Some("postgres://replica/db".into());
        let variant = primary.clone().read_replica_variant().unwrap();
        assert_ne!(primary.effective_pool_key(share), variant.effective_pool_key(share), "share={share}");
    }
}

#[test]
fn read_replica_route_never_serializes() {
    let mut m = mount("acme", "postgresql", Some("shared_rls"));
    m.replica_inline_dsn = Some("postgres://replica/db".into());
    let v = m.read_replica_variant().unwrap();
    let json = serde_json::to_string(&v).unwrap();
    assert!(!json.contains("read_replica_route"), "{json}");
}

// ════════════════════════════════════════════════════════════════════════════
//  serde round-trips
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn mount_round_trips_through_json() {
    let m = mount("acme", "postgresql", Some("schema_per_tenant"));
    let s = serde_json::to_string(&m).unwrap();
    let back: DatabaseMount = serde_json::from_str(&s).unwrap();
    assert_eq!(m, back);
}

#[test]
fn mount_deserializes_with_defaulted_optional_fields() {
    // A minimal payload omitting all #[serde(default)] fields must deserialize.
    let json = serde_json::json!({
        "id": "db1",
        "tenant_id": "acme",
        "engine": "postgresql",
        "name": "n",
        "credential_ref": { "provider": "p", "reference": "r", "version": "1" }
    });
    let m: DatabaseMount = serde_json::from_value(json).unwrap();
    assert_eq!(m.isolation(), Isolation::SharedRls);
    assert_eq!(m.pool_policy, PoolPolicy::default());
    assert!(!m.read_replica_route);
    assert!(m.inline_dsn.is_none());
}

#[test]
fn deserialized_mount_always_has_false_route_marker() {
    let json = serde_json::json!({
        "id": "db1", "tenant_id": "acme", "engine": "postgresql", "name": "n",
        "credential_ref": { "provider": "p", "reference": "r", "version": "1" },
        "read_replica_route": true
    });
    // #[serde(skip)] means the field is ignored on the wire → always false.
    let m: DatabaseMount = serde_json::from_value(json).unwrap();
    assert!(!m.read_replica_route, "skip-field never deserializes from wire");
}

#[test]
fn pool_policy_default_values() {
    let p = PoolPolicy::default();
    assert_eq!(p.min, 0);
    assert_eq!(p.max, 10);
    assert_eq!(p.idle_ttl_ms, 30_000);
    assert_eq!(p.max_lifetime_ms, 1_800_000);
}

#[test]
fn identity_round_trips_through_json() {
    let id = RequestIdentity {
        tenant_id: "t".into(),
        project_id: Some("p".into()),
        app_id: Some("a".into()),
        user_id: Some("u".into()),
        roles: vec!["admin".into()],
        scopes: vec!["read".into(), "write".into()],
        source: IdentitySource::Jwt,
    };
    let s = serde_json::to_string(&id).unwrap();
    let back: RequestIdentity = serde_json::from_str(&s).unwrap();
    assert_eq!(id, back);
}

#[test]
fn identity_deserializes_with_defaulted_roles_and_scopes() {
    let json = serde_json::json!({
        "tenant_id": "t", "source": "test"
    });
    let id: RequestIdentity = serde_json::from_value(json).unwrap();
    assert!(id.roles.is_empty());
    assert!(id.scopes.is_empty());
    assert!(id.user_id.is_none());
}

#[test]
fn identity_source_wire_names_are_snake_case() {
    for (variant, wire) in [
        (IdentitySource::SignedEnvelope, "signed_envelope"),
        (IdentitySource::Jwt, "jwt"),
        (IdentitySource::ServiceToken, "service_token"),
        (IdentitySource::Test, "test"),
    ] {
        assert_eq!(serde_json::to_value(&variant).unwrap(), serde_json::json!(wire));
    }
}

// ── PROPERTY-BASED ────────────────────────────────────────────────────────────

proptest! {
    /// owner_principal: a present (Some) user always wins, regardless of content;
    /// an absent user always yields the tenant. Never panics.
    #[test]
    fn prop_owner_principal_user_wins_when_some(
        user in ".{0,20}", tenant in ".{0,20}", has_user in any::<bool>()
    ) {
        let id = ident(if has_user { Some(&user) } else { None }, &tenant);
        let expected = if has_user { user.as_str() } else { tenant.as_str() };
        prop_assert_eq!(id.owner_principal(), expected);
    }

    /// is_tenant_scoped is true iff the trimmed tenant is non-empty.
    #[test]
    fn prop_is_tenant_scoped_matches_trim(tenant in "\\s{0,5}[a-z]{0,5}\\s{0,5}") {
        let id = ident(None, &tenant);
        prop_assert_eq!(id.is_tenant_scoped(), !tenant.trim().is_empty());
    }

    /// pool_key is fully deterministic for any tenant/engine/version triple.
    #[test]
    fn prop_pool_key_deterministic(
        tenant in "[a-z0-9-]{1,20}", engine in "[a-z]{1,12}", ver in "[0-9]{1,4}"
    ) {
        let mut m = mount(&tenant, &engine, None);
        m.credential_ref.version = ver;
        prop_assert_eq!(m.pool_key(), m.pool_key());
    }

    /// Distinct raw tenant ids → distinct pool keys (the cross-tenant-leak guard),
    /// holding engine + version fixed.
    #[test]
    fn prop_distinct_tenants_distinct_pool_keys(
        a in "[a-z0-9-]{1,20}", b in "[a-z0-9-]{1,20}"
    ) {
        prop_assume!(a != b);
        let ma = mount(&a, "postgresql", None);
        let mb = mount(&b, "postgresql", None);
        prop_assert_ne!(ma.pool_key(), mb.pool_key());
    }

    /// effective_pool_key(false) is ALWAYS byte-identical to pool_key(), for every
    /// isolation and any tenant — the parity invariant.
    #[test]
    fn prop_effective_off_equals_pool_key(
        tenant in "[a-z0-9-]{1,20}",
        iso_idx in 0usize..5
    ) {
        let iso = [None, Some("shared_rls"), Some("schema_per_tenant"), Some("db_per_tenant"), Some("tenant_owned")][iso_idx];
        let m = mount(&tenant, "postgresql", iso);
        prop_assert_eq!(m.effective_pool_key(false), m.pool_key());
    }

    /// shared_rls mounts on the same credential collapse to ONE shared pool key
    /// that contains neither tenant id.
    #[test]
    fn prop_shared_rls_collapses_distinct_tenants(
        a in "[a-z0-9]{3,12}", b in "[a-z0-9]{3,12}"
    ) {
        prop_assume!(a != b);
        let ma = mount(&a, "postgresql", Some("shared_rls"));
        let mb = mount(&b, "postgresql", Some("shared_rls"));
        prop_assert_eq!(ma.effective_pool_key(true), mb.effective_pool_key(true));
        prop_assert!(!ma.effective_pool_key(true).contains(a.as_str()));
        prop_assert!(!mb.effective_pool_key(true).contains(b.as_str()));
    }

    /// A configured replica variant's effective key always ends with `/ro` and
    /// always differs from the primary, in both share modes.
    #[test]
    fn prop_replica_variant_key_distinct(
        tenant in "[a-z0-9]{1,12}", share in any::<bool>()
    ) {
        let mut primary = mount(&tenant, "postgresql", Some("shared_rls"));
        primary.inline_dsn = Some("postgres://primary/db".into());
        primary.replica_inline_dsn = Some("postgres://replica/db".into());
        let variant = primary.clone().read_replica_variant().unwrap();
        let vk = variant.effective_pool_key(share);
        prop_assert!(vk.ends_with("/ro"));
        prop_assert_ne!(primary.effective_pool_key(share), vk);
    }

    /// A mount round-trips through JSON for any tenant/engine/isolation combo.
    #[test]
    fn prop_mount_json_round_trip(
        tenant in "[a-z0-9-]{1,20}", engine in "[a-z]{1,12}", iso_idx in 0usize..5
    ) {
        let iso = [None, Some("shared_rls"), Some("schema_per_tenant"), Some("db_per_tenant"), Some("tenant_owned")][iso_idx];
        let m = mount(&tenant, &engine, iso);
        let s = serde_json::to_string(&m).unwrap();
        let back: DatabaseMount = serde_json::from_str(&s).unwrap();
        prop_assert_eq!(m, back);
    }
}
