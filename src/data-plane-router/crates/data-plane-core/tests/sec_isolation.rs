//! Security: per-request tenant isolation. `Isolation::from_mount` must default
//! to the SAFE SharedRls for unknown/empty/None; `safe_schema` must neutralize
//! every injection / unicode / over-long / control-byte identifier (it is
//! interpolated into `SET search_path` / `USE`, which cannot bind params), be
//! collision-free across distinct raw ids, and never exceed PG's 63-byte cap;
//! `ScopeDirective` owner-scoping must hold per strategy × engine class.

use data_plane_core::{
    safe_schema, CredentialRef, DatabaseMount, IdentitySource, Isolation, PoolPolicy,
    RequestIdentity, ScopeDirective,
};

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

// ── from_mount: unknown / empty / None / typo all default to SAFE SharedRls ─

#[test]
fn unknown_empty_and_none_default_to_shared_rls() {
    let safe_default = Isolation::SharedRls;
    let degrade_to_default = [
        None,
        Some(""),
        Some("   "),
        Some("\t"),
        Some("nonsense"),
        Some("SCHEMA_PER_TENANT"), // wrong case is not recognised
        Some("Shared_Rls"),
        Some("schema-per-tenant"), // hyphen, not underscore
        Some("rls"),
        Some("public"),
        Some("'; DROP SCHEMA public; --"),
        Some("schema_per_tenant; evil"),
        Some("db_per_tenant\0"),
    ];
    for v in degrade_to_default {
        assert_eq!(
            Isolation::from_mount(v),
            safe_default,
            "isolation {v:?} must degrade to the safe SharedRls default"
        );
    }
}

#[test]
fn known_strings_map_exactly_and_trim_whitespace() {
    let cases = [
        ("shared_rls", Isolation::SharedRls),
        ("schema_per_tenant", Isolation::SchemaPerTenant),
        (" schema_per_tenant ", Isolation::SchemaPerTenant),
        ("db_per_tenant", Isolation::DbPerTenant),
        ("\tdb_per_tenant\n", Isolation::DbPerTenant),
        ("tenant_owned", Isolation::TenantOwned),
        (" tenant_owned ", Isolation::TenantOwned),
    ];
    for (s, expect) in cases {
        assert_eq!(Isolation::from_mount(Some(s)), expect, "{s:?}");
    }
}

#[test]
fn default_isolation_is_shared_rls() {
    assert_eq!(Isolation::default(), Isolation::SharedRls);
}

// ── owner-scoping invariant: only TenantOwned drops owner_id scoping ────────

#[test]
fn only_tenant_owned_disables_owner_scoping() {
    assert!(
        !Isolation::TenantOwned.owner_scoped(),
        "tenant_owned is the only un-scoped mode"
    );
    for scoped in [
        Isolation::SharedRls,
        Isolation::SchemaPerTenant,
        Isolation::DbPerTenant,
    ] {
        assert!(
            scoped.owner_scoped(),
            "{scoped:?} must owner-scope per request"
        );
    }
}

// ── scope(): strategy × engine-class directive table ────────────────────────

#[test]
fn shared_rls_and_db_per_tenant_never_scope_per_request() {
    let id = identity();
    for engine in [
        "postgresql",
        "mysql",
        "mongodb",
        "redis",
        "http",
        "weirddb",
        "dynamodb",
    ] {
        let m = mount(engine, "acme", None);
        assert_eq!(
            Isolation::SharedRls.scope(&m, &id),
            ScopeDirective::None,
            "shared_rls {engine}"
        );
        assert_eq!(
            Isolation::DbPerTenant.scope(&m, &id),
            ScopeDirective::None,
            "db_per_tenant {engine}"
        );
        assert_eq!(
            Isolation::TenantOwned.scope(&m, &id),
            ScopeDirective::None,
            "tenant_owned {engine}"
        );
    }
}

#[test]
fn schema_per_tenant_routes_by_engine_class() {
    let id = identity();
    let expected = safe_schema("acme").unwrap();
    // postgres → SetSearchPath (the only engine with a true search_path)
    let pg = mount("postgresql", "acme", Some("schema_per_tenant"));
    assert_eq!(
        Isolation::SchemaPerTenant.scope(&pg, &id),
        ScopeDirective::SetSearchPath {
            schema: expected.clone()
        }
    );
    // mysql / mongodb / redis / dynamodb → UseNamespace
    for engine in ["mysql", "mongodb", "redis", "dynamodb"] {
        let m = mount(engine, "acme", Some("schema_per_tenant"));
        assert_eq!(
            Isolation::SchemaPerTenant.scope(&m, &id),
            ScopeDirective::UseNamespace {
                namespace: expected.clone()
            },
            "{engine}"
        );
    }
    // http / unknown → None (no schema concept)
    for engine in ["http", "weirddb", "trino"] {
        let m = mount(engine, "acme", Some("schema_per_tenant"));
        assert_eq!(
            Isolation::SchemaPerTenant.scope(&m, &id),
            ScopeDirective::None,
            "{engine}"
        );
    }
}

#[test]
fn schema_per_tenant_empty_tenant_degrades_to_none() {
    let id = identity();
    // Ids that sanitize to empty → no scoping (shared behaviour), never a bogus schema.
    for tenant in ["---", "___", "...", "   ", "!!!", "\0\0", "－－"] {
        for engine in ["postgresql", "mongodb", "redis"] {
            let m = mount(engine, tenant, Some("schema_per_tenant"));
            assert_eq!(
                Isolation::SchemaPerTenant.scope(&m, &id),
                ScopeDirective::None,
                "empty-after-sanitize tenant {tenant:?} on {engine}"
            );
        }
    }
}

// ── safe_schema: REJECT (→ None) for empty-sanitizing; NEUTRALIZE the rest ──

#[test]
fn safe_schema_returns_none_for_ids_that_sanitize_empty() {
    for id in [
        "",
        "---",
        "___",
        "...",
        "  ",
        "@#$%",
        "\0",
        "\t\n",
        "－－－",
    ] {
        assert_eq!(safe_schema(id), None, "{id:?} sanitizes to empty → None");
    }
}

/// The derived schema is ALWAYS `[a-z0-9_]` only — no quotes, semicolons,
/// spaces, dashes/comment markers, dots, backslashes, null bytes, or unicode
/// can survive into a `SET search_path` / `USE` string.
#[test]
fn safe_schema_neutralizes_every_injection_and_unicode_trick() {
    let dangerous = [
        "a; DROP SCHEMA public; --",
        "x' OR '1'='1",
        "a\"b",
        "a`b",
        "a/*c*/d",
        "a--b",
        "a.b.c",
        "a\\b",
        "a\0b",
        "tab\tsep",
        "new\nline",
        "space sep",
        "a/b/c",
        "../../etc/passwd",
        "schema$(whoami)",
        "用户表",     // CJK
        "naïve_café", // accented latin
        "emoji🔥name",
        "\u{202e}rtl", // RTL override
        "ＤＲＯＰ",    // fullwidth
        "a%27b",
        "${jndi}",
        "{{tpl}}",
    ];
    // Every dangerous id here keeps at least one ASCII alnum, so it MUST produce
    // a neutralized Some(...) (exercising the sanitize path, not just the None
    // fallback) — and that output must be strictly `[a-z0-9_]`.
    for id in [
        "a; DROP SCHEMA public; --",
        "x' OR '1'='1",
        "a\0b",
        "../../etc/passwd",
        "emoji🔥name",
        "a%27b",
    ] {
        let s = safe_schema(id).expect("an id with ASCII alnum must neutralize, not vanish");
        assert!(
            s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
            "safe_schema({id:?}) = {s:?} leaked a forbidden char"
        );
    }
    for id in dangerous {
        // Either the id sanitizes to nothing (→ None, the safe shared default)
        // OR it produces a strictly `[a-z0-9_]` identifier — never a leaked byte.
        match safe_schema(id) {
            None => { /* fully neutralized to the shared-schema fallback — safe */ }
            Some(s) => {
                assert!(
                    s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
                    "safe_schema({id:?}) = {s:?} leaked a non-[a-z0-9_] char"
                );
                assert!(s.starts_with("tenant_"), "{s:?}");
                // No uppercase: everything lower-cased.
                assert_eq!(s, s.to_ascii_lowercase(), "{s:?} must be lower-cased");
            }
        }
    }
}

#[test]
fn safe_schema_never_exceeds_pg_63_byte_cap() {
    // Even a 1000-char id (and a 1000-char id full of dangerous bytes) fits.
    for id in [
        "a".repeat(1000),
        "x_".repeat(500),
        "'; DROP; --".repeat(100),
        "用".repeat(300), // all non-ascii → sanitizes to empty → None (still safe)
    ] {
        // Whenever a schema is produced at all, it fits PG's 63-byte cap; an
        // empty-sanitizing id yields None, which is also safe (shared default).
        if let Some(s) = safe_schema(&id) {
            assert!(
                s.len() <= 63,
                "safe_schema len {} > 63 for id of len {}",
                s.len(),
                id.len()
            );
        }
    }
    // A long ASCII id always produces a (capped) schema, never None.
    let long = "a".repeat(1000);
    let s = safe_schema(&long).expect("long ascii id produces a schema");
    assert!(s.len() <= 63, "{} must fit the 63-byte cap", s.len());
}

#[test]
fn safe_schema_is_stable_and_collision_free_across_distinct_ids() {
    // Stable: same raw id → same schema (deterministic, no nondeterminism).
    assert_eq!(safe_schema("acme"), safe_schema("acme"));
    assert_eq!(
        safe_schema("00000000-0000-4000-8000-000000000003"),
        safe_schema("00000000-0000-4000-8000-000000000003")
    );

    // Collision-free: ids that sanitize to the SAME fragment must still differ
    // (the hash-of-raw-id suffix guarantees it — else a cross-tenant leak).
    let folding_groups = [
        vec!["t-acme", "t.acme", "T-ACME", "t/acme", "t acme"],
        vec!["a@b", "a#b", "a%b", "a&b"],
    ];
    for group in folding_groups {
        let schemas: Vec<String> = group.iter().map(|id| safe_schema(id).unwrap()).collect();
        for i in 0..schemas.len() {
            for j in (i + 1)..schemas.len() {
                assert_ne!(
                    schemas[i], schemas[j],
                    "{:?} and {:?} must map to distinct schemas",
                    group[i], group[j]
                );
            }
        }
    }

    // Long ids that share a >40-char prefix (folded by truncation) stay distinct.
    let a = format!("{}-A", "x".repeat(60));
    let b = format!("{}-B", "x".repeat(60));
    assert_ne!(safe_schema(&a).unwrap(), safe_schema(&b).unwrap());
}

#[test]
fn safe_schema_accepts_plain_identifiers_with_readable_fragment() {
    // Plain ids keep a human-readable fragment + an 8-hex hash suffix.
    let cases = ["acme", "tenant42", "my_app", "a1b2c3", "UUID-like_id"];
    for id in cases {
        let s = safe_schema(id).unwrap();
        assert!(s.starts_with("tenant_"), "{s}");
        // suffix is `_` + 8 lowercase hex chars
        let tail = s.rsplit('_').next().unwrap();
        assert_eq!(tail.len(), 8, "hash suffix length: {s}");
        assert!(
            tail.chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "hash suffix lowercase hex: {s}"
        );
    }
}

#[test]
fn identical_tenant_distinct_engine_classes_produce_consistent_namespace() {
    // The SAME tenant under schema_per_tenant must produce the SAME identifier
    // whether realised as a search_path (pg) or a namespace (mysql/mongo/redis):
    // one tenant, one schema name across engines.
    let id = identity();
    let pg = mount("postgresql", "team_seven", Some("schema_per_tenant"));
    let mongo = mount("mongodb", "team_seven", Some("schema_per_tenant"));
    let pg_schema = match Isolation::SchemaPerTenant.scope(&pg, &id) {
        ScopeDirective::SetSearchPath { schema } => schema,
        other => panic!("expected SetSearchPath, got {other:?}"),
    };
    let mongo_ns = match Isolation::SchemaPerTenant.scope(&mongo, &id) {
        ScopeDirective::UseNamespace { namespace } => namespace,
        other => panic!("expected UseNamespace, got {other:?}"),
    };
    assert_eq!(
        pg_schema, mongo_ns,
        "one tenant → one stable schema/namespace name"
    );
}
