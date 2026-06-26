/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   edge_capability.rs                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:34:51 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:34:53 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Edge-case suite for `EngineCapabilities` (capability.rs) + `Isolation` /
//! `safe_schema` (isolation.rs): the advertised op matrix per engine, route-cap
//! isolation from `supports_op`, the strategy × engine-class scope table, and
//! schema-name sanitization.
//!
//! Tests only — no source logic changed. Behavior asserted against the code.

use data_plane_core::capability::{JoinCapability, LatencyClass, PatternSearchCapability};
use data_plane_core::*;
use proptest::prelude::*;

// ════════════════════════════════════════════════════════════════════════════
//  EngineCapabilities::supports_op — the advertised matrix, per engine
// ════════════════════════════════════════════════════════════════════════════

/// Assert supports_op for ALL 8 op kinds against a descriptor's expected vector
/// (order = DataOperationKind::ALL = list,get,insert,update,delete,upsert,batch,aggregate).
fn assert_op_matrix(caps: &EngineCapabilities, expected: [bool; 8]) {
    for (k, want) in DataOperationKind::ALL.iter().zip(expected) {
        assert_eq!(caps.supports_op(k), want, "op {k:?}");
    }
}

#[test]
fn postgresql_serves_every_crud_family_op() {
    // read+write+upsert+batch+aggregate all true.
    assert_op_matrix(
        &EngineCapabilities::postgresql(),
        [true, true, true, true, true, true, true, true],
    );
}

#[test]
fn mongodb_serves_every_crud_family_op() {
    assert_op_matrix(
        &EngineCapabilities::mongodb(),
        [true, true, true, true, true, true, true, true],
    );
}

#[test]
fn mysql_serves_every_crud_family_op() {
    assert_op_matrix(
        &EngineCapabilities::mysql(),
        [true, true, true, true, true, true, true, true],
    );
}

#[test]
fn sqlite_serves_every_crud_family_op() {
    assert_op_matrix(
        &EngineCapabilities::sqlite(),
        [true, true, true, true, true, true, true, true],
    );
}

#[test]
fn mssql_serves_every_crud_family_op() {
    assert_op_matrix(
        &EngineCapabilities::mssql(),
        [true, true, true, true, true, true, true, true],
    );
}

#[test]
fn redis_serves_crud_and_batch_but_not_aggregate() {
    // aggregate is the ONLY excluded op for redis.
    assert_op_matrix(
        &EngineCapabilities::redis(),
        [true, true, true, true, true, true, true, false],
    );
}

#[test]
fn dynamodb_serves_crud_and_batch_but_not_aggregate() {
    // Same op shape as redis — aggregate excluded (OLAP is the bridge).
    assert_op_matrix(
        &EngineCapabilities::dynamodb(),
        [true, true, true, true, true, true, true, false],
    );
}

#[test]
fn http_serves_crud_but_not_batch_or_aggregate() {
    // http: read/write/upsert yes; batch + aggregate no.
    assert_op_matrix(
        &EngineCapabilities::http(),
        [true, true, true, true, true, true, false, false],
    );
}

#[test]
fn list_and_get_track_the_read_flag() {
    let mut caps = EngineCapabilities::postgresql();
    caps.read = false;
    assert!(!caps.supports_op(&DataOperationKind::List));
    assert!(!caps.supports_op(&DataOperationKind::Get));
}

#[test]
fn insert_update_delete_all_track_the_write_flag() {
    let mut caps = EngineCapabilities::postgresql();
    caps.write = false;
    assert!(!caps.supports_op(&DataOperationKind::Insert));
    assert!(!caps.supports_op(&DataOperationKind::Update));
    assert!(!caps.supports_op(&DataOperationKind::Delete));
}

#[test]
fn upsert_tracks_the_upsert_flag() {
    let mut caps = EngineCapabilities::postgresql();
    caps.upsert = false;
    assert!(!caps.supports_op(&DataOperationKind::Upsert));
}

#[test]
fn batch_tracks_the_batch_flag() {
    let mut caps = EngineCapabilities::http();
    assert!(!caps.supports_op(&DataOperationKind::Batch));
    caps.batch = true;
    assert!(caps.supports_op(&DataOperationKind::Batch));
}

#[test]
fn aggregate_tracks_the_aggregate_flag() {
    let mut caps = EngineCapabilities::redis();
    assert!(!caps.supports_op(&DataOperationKind::Aggregate));
    caps.aggregate = true;
    assert!(caps.supports_op(&DataOperationKind::Aggregate));
}

// ── route caps (introspect/schema_ddl/ddl) never leak into supports_op ─────────

#[test]
fn introspect_flag_does_not_affect_supports_op() {
    let mut caps = EngineCapabilities::redis();
    let before: Vec<_> = DataOperationKind::ALL
        .iter()
        .map(|k| caps.supports_op(k))
        .collect();
    caps.introspect = !caps.introspect;
    let after: Vec<_> = DataOperationKind::ALL
        .iter()
        .map(|k| caps.supports_op(k))
        .collect();
    assert_eq!(before, after);
}

#[test]
fn schema_ddl_flag_does_not_affect_supports_op() {
    let mut caps = EngineCapabilities::mongodb();
    let before: Vec<_> = DataOperationKind::ALL
        .iter()
        .map(|k| caps.supports_op(k))
        .collect();
    caps.schema_ddl = !caps.schema_ddl;
    let after: Vec<_> = DataOperationKind::ALL
        .iter()
        .map(|k| caps.supports_op(k))
        .collect();
    assert_eq!(before, after);
}

#[test]
fn ddl_flag_does_not_affect_supports_op() {
    let mut caps = EngineCapabilities::postgresql();
    let before: Vec<_> = DataOperationKind::ALL
        .iter()
        .map(|k| caps.supports_op(k))
        .collect();
    caps.ddl = !caps.ddl;
    let after: Vec<_> = DataOperationKind::ALL
        .iter()
        .map(|k| caps.supports_op(k))
        .collect();
    assert_eq!(before, after);
}

// ── per-engine descriptor flag truth (the advertised matrix) ──────────────────

#[test]
fn introspect_matches_each_engine_surface() {
    assert!(EngineCapabilities::postgresql().introspect);
    assert!(EngineCapabilities::mysql().introspect);
    assert!(EngineCapabilities::mongodb().introspect);
    assert!(EngineCapabilities::sqlite().introspect);
    assert!(EngineCapabilities::mssql().introspect);
    assert!(EngineCapabilities::dynamodb().introspect);
    assert!(!EngineCapabilities::redis().introspect);
    assert!(!EngineCapabilities::http().introspect);
}

#[test]
fn schema_ddl_matches_each_engine_surface() {
    assert!(EngineCapabilities::postgresql().schema_ddl);
    assert!(EngineCapabilities::mysql().schema_ddl);
    assert!(EngineCapabilities::mongodb().schema_ddl);
    assert!(EngineCapabilities::sqlite().schema_ddl);
    assert!(!EngineCapabilities::mssql().schema_ddl);
    assert!(!EngineCapabilities::redis().schema_ddl);
    assert!(!EngineCapabilities::http().schema_ddl);
    assert!(!EngineCapabilities::dynamodb().schema_ddl);
}

#[test]
fn ddl_migration_flag_matches_each_engine() {
    // apply_migration: postgres + mysql yes; mongo/sqlite/mssql/redis/http/dynamo no.
    assert!(EngineCapabilities::postgresql().ddl);
    assert!(EngineCapabilities::mysql().ddl);
    assert!(!EngineCapabilities::mongodb().ddl);
    assert!(!EngineCapabilities::sqlite().ddl);
    assert!(!EngineCapabilities::mssql().ddl);
    assert!(!EngineCapabilities::redis().ddl);
    assert!(!EngineCapabilities::http().ddl);
    assert!(!EngineCapabilities::dynamodb().ddl);
}

#[test]
fn mongo_schema_ddl_and_migrate_flags_are_independent() {
    // The honesty invariant: mongo advertises schema_ddl (validator surface) but
    // NOT ddl (apply_migration is NotImplemented).
    let m = EngineCapabilities::mongodb();
    assert!(m.schema_ddl);
    assert!(!m.ddl);
}

#[test]
fn streaming_flag_matches_each_engine() {
    assert!(EngineCapabilities::postgresql().stream);
    assert!(EngineCapabilities::mongodb().stream);
    assert!(!EngineCapabilities::mysql().stream);
    assert!(!EngineCapabilities::sqlite().stream);
    assert!(!EngineCapabilities::mssql().stream);
    assert!(!EngineCapabilities::redis().stream);
    assert!(!EngineCapabilities::http().stream);
    assert!(!EngineCapabilities::dynamodb().stream);
}

#[test]
fn transactions_flag_matches_each_engine() {
    assert!(EngineCapabilities::postgresql().transactions);
    assert!(EngineCapabilities::mysql().transactions);
    assert!(EngineCapabilities::dynamodb().transactions);
    assert!(!EngineCapabilities::mongodb().transactions);
    assert!(!EngineCapabilities::sqlite().transactions);
    assert!(!EngineCapabilities::mssql().transactions);
    assert!(!EngineCapabilities::redis().transactions);
    assert!(!EngineCapabilities::http().transactions);
}

#[test]
fn savepoints_flag_matches_each_engine() {
    assert!(EngineCapabilities::postgresql().savepoints);
    assert!(EngineCapabilities::mysql().savepoints);
    assert!(!EngineCapabilities::mongodb().savepoints);
    assert!(!EngineCapabilities::dynamodb().savepoints);
    assert!(!EngineCapabilities::sqlite().savepoints);
}

#[test]
fn native_idempotency_only_dynamodb() {
    // DynamoDB is the only adapter that can honestly set native_idempotency.
    assert!(EngineCapabilities::dynamodb().native_idempotency);
    for caps in [
        EngineCapabilities::postgresql(),
        EngineCapabilities::mysql(),
        EngineCapabilities::mongodb(),
        EngineCapabilities::sqlite(),
        EngineCapabilities::mssql(),
        EngineCapabilities::redis(),
        EngineCapabilities::http(),
    ] {
        assert!(!caps.native_idempotency, "{}", caps.max_batch_size);
    }
}

#[test]
fn two_phase_commit_only_dynamodb() {
    assert!(EngineCapabilities::dynamodb().two_phase_commit);
    assert!(!EngineCapabilities::postgresql().two_phase_commit);
    assert!(!EngineCapabilities::mysql().two_phase_commit);
    assert!(!EngineCapabilities::mongodb().two_phase_commit);
}

#[test]
fn max_batch_sizes_are_the_documented_values() {
    assert_eq!(EngineCapabilities::postgresql().max_batch_size, 1000);
    assert_eq!(EngineCapabilities::mongodb().max_batch_size, 1000);
    assert_eq!(EngineCapabilities::mysql().max_batch_size, 1000);
    assert_eq!(EngineCapabilities::sqlite().max_batch_size, 1000);
    assert_eq!(EngineCapabilities::mssql().max_batch_size, 1000);
    assert_eq!(EngineCapabilities::redis().max_batch_size, 100);
    assert_eq!(EngineCapabilities::http().max_batch_size, 50);
    assert_eq!(EngineCapabilities::dynamodb().max_batch_size, 25);
}

#[test]
fn isolation_levels_per_engine() {
    use IsolationLevel::*;
    assert_eq!(
        EngineCapabilities::postgresql().isolation_levels,
        vec![ReadCommitted, RepeatableRead, Serializable]
    );
    assert_eq!(
        EngineCapabilities::mongodb().isolation_levels,
        vec![Snapshot]
    );
    assert_eq!(
        EngineCapabilities::dynamodb().isolation_levels,
        vec![Serializable]
    );
    assert!(EngineCapabilities::sqlite().isolation_levels.is_empty());
    assert!(EngineCapabilities::redis().isolation_levels.is_empty());
    assert!(EngineCapabilities::http().isolation_levels.is_empty());
}

#[test]
fn cockroachdb_matches_postgres_ops_but_diverges_on_stream_and_isolation() {
    let cr = EngineCapabilities::cockroachdb();
    // Same op surface as postgres.
    assert_op_matrix(&cr, [true, true, true, true, true, true, true, true]);
    // But honest divergences:
    assert!(!cr.stream, "no LISTEN/NOTIFY");
    assert_eq!(cr.isolation_levels, vec![IsolationLevel::Serializable]);
}

#[test]
fn mariadb_is_identical_to_mysql() {
    assert_eq!(EngineCapabilities::mariadb(), EngineCapabilities::mysql());
}

#[test]
fn cost_latency_class_per_engine() {
    assert_eq!(
        EngineCapabilities::postgresql().cost.latency_class,
        LatencyClass::Native
    );
    assert_eq!(
        EngineCapabilities::dynamodb().cost.latency_class,
        LatencyClass::Native
    );
    assert_eq!(
        EngineCapabilities::http().cost.latency_class,
        LatencyClass::Remote
    );
}

#[test]
fn cost_pattern_search_per_engine() {
    assert_eq!(
        EngineCapabilities::postgresql().cost.pattern_search,
        PatternSearchCapability::Native
    );
    assert_eq!(
        EngineCapabilities::mysql().cost.pattern_search,
        PatternSearchCapability::Indexed
    );
    assert_eq!(
        EngineCapabilities::redis().cost.pattern_search,
        PatternSearchCapability::Scan
    );
    assert_eq!(
        EngineCapabilities::http().cost.pattern_search,
        PatternSearchCapability::Remote
    );
}

#[test]
fn cost_joins_per_engine() {
    assert_eq!(
        EngineCapabilities::postgresql().cost.joins,
        JoinCapability::Native
    );
    assert_eq!(
        EngineCapabilities::mongodb().cost.joins,
        JoinCapability::Limited
    );
    assert_eq!(EngineCapabilities::redis().cost.joins, JoinCapability::None);
    assert_eq!(
        EngineCapabilities::dynamodb().cost.joins,
        JoinCapability::None
    );
}

// ── serde wire back-compat ────────────────────────────────────────────────────

#[test]
fn capabilities_payload_without_introspect_defaults_false() {
    let mut payload = serde_json::to_value(EngineCapabilities::postgresql()).unwrap();
    payload.as_object_mut().unwrap().remove("introspect");
    let parsed: EngineCapabilities = serde_json::from_value(payload).unwrap();
    assert!(!parsed.introspect);
}

#[test]
fn capabilities_payload_without_batch_defaults_false() {
    let mut payload = serde_json::to_value(EngineCapabilities::postgresql()).unwrap();
    payload.as_object_mut().unwrap().remove("batch");
    let parsed: EngineCapabilities = serde_json::from_value(payload).unwrap();
    assert!(!parsed.batch);
}

#[test]
fn capabilities_payload_without_aggregate_defaults_false() {
    let mut payload = serde_json::to_value(EngineCapabilities::postgresql()).unwrap();
    payload.as_object_mut().unwrap().remove("aggregate");
    let parsed: EngineCapabilities = serde_json::from_value(payload).unwrap();
    assert!(!parsed.aggregate);
}

#[test]
fn capabilities_payload_without_schema_ddl_defaults_false() {
    let mut payload = serde_json::to_value(EngineCapabilities::postgresql()).unwrap();
    payload.as_object_mut().unwrap().remove("schema_ddl");
    let parsed: EngineCapabilities = serde_json::from_value(payload).unwrap();
    assert!(!parsed.schema_ddl);
}

#[test]
fn capabilities_round_trip_for_every_engine() {
    let all = [
        EngineCapabilities::postgresql(),
        EngineCapabilities::cockroachdb(),
        EngineCapabilities::mysql(),
        EngineCapabilities::mariadb(),
        EngineCapabilities::mongodb(),
        EngineCapabilities::sqlite(),
        EngineCapabilities::mssql(),
        EngineCapabilities::redis(),
        EngineCapabilities::dynamodb(),
        EngineCapabilities::http(),
    ];
    for caps in all {
        let s = serde_json::to_string(&caps).unwrap();
        let back: EngineCapabilities = serde_json::from_str(&s).unwrap();
        assert_eq!(caps, back);
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  Isolation: from_mount, owner_scoped, scope
// ════════════════════════════════════════════════════════════════════════════

fn test_identity() -> RequestIdentity {
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

fn iso_mount(engine: &str, tenant: &str, iso: Option<&str>) -> DatabaseMount {
    DatabaseMount {
        id: "db1".into(),
        tenant_id: tenant.into(),
        project_id: None,
        engine: engine.into(),
        name: "n".into(),
        credential_ref: CredentialRef {
            provider: "p".into(),
            reference: "r".into(),
            version: "1".into(),
        },
        pool_policy: PoolPolicy::default(),
        capability_overrides: None,
        inline_dsn: None,
        isolation: iso.map(str::to_string),
        replica_inline_dsn: None,
        read_replica_route: false,
    }
}

#[test]
fn from_mount_known_values() {
    assert_eq!(
        Isolation::from_mount(Some("shared_rls")),
        Isolation::SharedRls
    );
    assert_eq!(
        Isolation::from_mount(Some("schema_per_tenant")),
        Isolation::SchemaPerTenant
    );
    assert_eq!(
        Isolation::from_mount(Some("db_per_tenant")),
        Isolation::DbPerTenant
    );
    assert_eq!(
        Isolation::from_mount(Some("tenant_owned")),
        Isolation::TenantOwned
    );
}

#[test]
fn from_mount_none_and_empty_and_unknown_all_shared_rls() {
    assert_eq!(Isolation::from_mount(None), Isolation::SharedRls);
    assert_eq!(Isolation::from_mount(Some("")), Isolation::SharedRls);
    assert_eq!(Isolation::from_mount(Some("   ")), Isolation::SharedRls);
    assert_eq!(
        Isolation::from_mount(Some("nonsense")),
        Isolation::SharedRls
    );
}

#[test]
fn from_mount_is_case_sensitive() {
    // Uppercase variants are NOT recognized → degrade to default.
    assert_eq!(
        Isolation::from_mount(Some("SCHEMA_PER_TENANT")),
        Isolation::SharedRls
    );
    assert_eq!(
        Isolation::from_mount(Some("Tenant_Owned")),
        Isolation::SharedRls
    );
}

#[test]
fn from_mount_trims_whitespace_around_known_values() {
    assert_eq!(
        Isolation::from_mount(Some(" schema_per_tenant ")),
        Isolation::SchemaPerTenant
    );
    assert_eq!(
        Isolation::from_mount(Some("\tdb_per_tenant\n")),
        Isolation::DbPerTenant
    );
    assert_eq!(
        Isolation::from_mount(Some(" tenant_owned ")),
        Isolation::TenantOwned
    );
}

#[test]
fn default_isolation_is_shared_rls() {
    assert_eq!(Isolation::default(), Isolation::SharedRls);
}

#[test]
fn owner_scoped_true_for_all_but_tenant_owned() {
    assert!(Isolation::SharedRls.owner_scoped());
    assert!(Isolation::SchemaPerTenant.owner_scoped());
    assert!(Isolation::DbPerTenant.owner_scoped());
    assert!(!Isolation::TenantOwned.owner_scoped());
}

#[test]
fn scope_shared_rls_is_none_on_every_engine() {
    let id = test_identity();
    for engine in [
        "postgresql",
        "mysql",
        "mongodb",
        "redis",
        "http",
        "dynamodb",
        "weird",
    ] {
        let m = iso_mount(engine, "acme", Some("shared_rls"));
        assert_eq!(
            Isolation::SharedRls.scope(&m, &id),
            ScopeDirective::None,
            "{engine}"
        );
    }
}

#[test]
fn scope_db_per_tenant_is_none_on_every_engine() {
    let id = test_identity();
    for engine in ["postgresql", "mysql", "mongodb", "redis", "http"] {
        let m = iso_mount(engine, "acme", Some("db_per_tenant"));
        assert_eq!(
            Isolation::DbPerTenant.scope(&m, &id),
            ScopeDirective::None,
            "{engine}"
        );
    }
}

#[test]
fn scope_tenant_owned_is_none_on_every_engine() {
    let id = test_identity();
    for engine in ["postgresql", "mysql", "mongodb"] {
        let m = iso_mount(engine, "acme", Some("tenant_owned"));
        assert_eq!(
            Isolation::TenantOwned.scope(&m, &id),
            ScopeDirective::None,
            "{engine}"
        );
    }
}

#[test]
fn scope_schema_per_tenant_postgres_is_set_search_path() {
    let id = test_identity();
    let m = iso_mount("postgresql", "acme", Some("schema_per_tenant"));
    let expected = safe_schema("acme").unwrap();
    assert_eq!(
        Isolation::SchemaPerTenant.scope(&m, &id),
        ScopeDirective::SetSearchPath { schema: expected }
    );
}

#[test]
fn scope_schema_per_tenant_namespace_engines_use_namespace() {
    let id = test_identity();
    let expected = safe_schema("acme").unwrap();
    for engine in ["mysql", "mongodb", "redis", "dynamodb"] {
        let m = iso_mount(engine, "acme", Some("schema_per_tenant"));
        assert_eq!(
            Isolation::SchemaPerTenant.scope(&m, &id),
            ScopeDirective::UseNamespace {
                namespace: expected.clone()
            },
            "{engine}"
        );
    }
}

#[test]
fn scope_schema_per_tenant_unscoped_engines_are_none() {
    let id = test_identity();
    for engine in ["http", "weirddb", "cassandra", ""] {
        let m = iso_mount(engine, "acme", Some("schema_per_tenant"));
        assert_eq!(
            Isolation::SchemaPerTenant.scope(&m, &id),
            ScopeDirective::None,
            "{engine}"
        );
    }
}

#[test]
fn scope_schema_per_tenant_empty_tenant_degrades_to_none() {
    let id = test_identity();
    for engine in ["postgresql", "mongodb", "redis"] {
        let m = iso_mount(engine, "---", Some("schema_per_tenant"));
        assert_eq!(
            Isolation::SchemaPerTenant.scope(&m, &id),
            ScopeDirective::None,
            "{engine}"
        );
    }
}

#[test]
fn scope_does_not_consume_identity_content() {
    // scope ignores identity content entirely (the mount's tenant_id is used);
    // even an identity with a different tenant gives the same directive.
    let m = iso_mount("postgresql", "acme", Some("schema_per_tenant"));
    let mut id = test_identity();
    id.tenant_id = "someone-else".into();
    assert_eq!(
        Isolation::SchemaPerTenant.scope(&m, &id),
        ScopeDirective::SetSearchPath {
            schema: safe_schema("acme").unwrap()
        }
    );
}

// ════════════════════════════════════════════════════════════════════════════
//  safe_schema — sanitization, truncation, collision-freedom, empty
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn safe_schema_basic_lowercase_id() {
    let s = safe_schema("acme").unwrap();
    assert!(s.starts_with("tenant_acme_"), "{s}");
    assert_hash8_suffix(&s);
}

#[test]
fn safe_schema_uppercase_is_lowercased() {
    let s = safe_schema("ACME").unwrap();
    assert!(s.starts_with("tenant_acme_"), "{s}");
}

#[test]
fn safe_schema_separators_become_underscores() {
    let s = safe_schema("t-Acme.2").unwrap();
    assert!(s.starts_with("tenant_t_acme_2_"), "{s}");
}

#[test]
fn safe_schema_uuid_form() {
    let s = safe_schema("00000000-0000-4000-8000-000000000003").unwrap();
    assert!(
        s.starts_with("tenant_00000000_0000_4000_8000_000000000003_"),
        "{s}"
    );
    assert_hash8_suffix(&s);
}

#[test]
fn safe_schema_only_alnum_and_underscore_in_output() {
    for raw in [
        "a; DROP SCHEMA public; --",
        "user@host:5432/db?x=1",
        "../../etc/passwd",
        "tab\tnewline\n",
    ] {
        if let Some(s) = safe_schema(raw) {
            assert!(
                s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
                "raw={raw:?} -> {s}"
            );
        }
    }
}

#[test]
fn safe_schema_empty_inputs_are_none() {
    assert_eq!(safe_schema(""), None);
    assert_eq!(safe_schema("---"), None);
    assert_eq!(safe_schema("___"), None);
    assert_eq!(safe_schema("...."), None);
    assert_eq!(safe_schema("   "), None);
}

#[test]
fn safe_schema_all_non_ascii_is_none() {
    // Every byte maps to `_`, trimmed to empty → None.
    assert_eq!(safe_schema("名前"), None);
    assert_eq!(
        safe_schema("émojî"),
        Some("tenant_moj_".to_string() + &hash_of("émojî"))
    );
}

#[test]
fn safe_schema_truncates_long_fragment_to_fit_pg_cap() {
    let long = "a".repeat(200);
    let s = safe_schema(&long).unwrap();
    // tenant_ (7) + 40 fragment + _ (1) + 8 hash = 56.
    assert_eq!(s.len(), 7 + 40 + 1 + 8);
    assert!(s.len() <= 63, "must fit PG 63-byte cap: {} ({s})", s.len());
}

#[test]
fn safe_schema_is_stable_across_calls() {
    assert_eq!(safe_schema("acme"), safe_schema("acme"));
    assert_eq!(safe_schema("Mixed-Case_ID"), safe_schema("Mixed-Case_ID"));
}

#[test]
fn safe_schema_previously_colliding_ids_now_distinct() {
    let a = safe_schema("t-acme").unwrap();
    let b = safe_schema("t.acme").unwrap();
    let c = safe_schema("T-ACME").unwrap();
    assert_ne!(a, b);
    assert_ne!(a, c);
    assert_ne!(b, c);
}

#[test]
fn safe_schema_long_ids_sharing_40char_prefix_stay_distinct() {
    let a = format!("{}-A", "x".repeat(60));
    let b = format!("{}-B", "x".repeat(60));
    assert_ne!(safe_schema(&a).unwrap(), safe_schema(&b).unwrap());
}

#[test]
fn safe_schema_leading_trailing_underscores_trimmed() {
    let s = safe_schema("__acme__").unwrap();
    // Interior content kept; leading/trailing `_` trimmed before prefixing.
    assert!(s.starts_with("tenant_acme_"), "{s}");
}

#[test]
fn safe_schema_single_alnum_char() {
    let s = safe_schema("x").unwrap();
    assert!(s.starts_with("tenant_x_"), "{s}");
    assert_hash8_suffix(&s);
}

#[test]
fn safe_schema_numeric_only_id() {
    let s = safe_schema("12345").unwrap();
    assert!(s.starts_with("tenant_12345_"), "{s}");
}

// helper: the 8 hex chars FNV-1a hash suffix that safe_schema appends.
fn hash_of(raw: &str) -> String {
    const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut h = FNV_OFFSET;
    for b in raw.as_bytes() {
        h ^= u64::from(*b);
        h = h.wrapping_mul(FNV_PRIME);
    }
    format!("{:08x}", (h >> 32) as u32)
}

fn assert_hash8_suffix(s: &str) {
    let hash = s.rsplit('_').next().unwrap();
    assert_eq!(hash.len(), 8, "hash suffix is 8 chars: {s}");
    assert!(
        hash.chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
        "lowercase hex suffix: {s}"
    );
}

// ── PROPERTY-BASED ────────────────────────────────────────────────────────────

proptest! {
    /// supports_op is consistent with the raw flags for an arbitrary descriptor
    /// (built by mutating postgres' flags), and never panics.
    #[test]
    fn prop_supports_op_consistent_with_flags(
        read in any::<bool>(), write in any::<bool>(),
        upsert in any::<bool>(), batch in any::<bool>(), aggregate in any::<bool>()
    ) {
        let mut caps = EngineCapabilities::postgresql();
        caps.read = read; caps.write = write; caps.upsert = upsert;
        caps.batch = batch; caps.aggregate = aggregate;
        prop_assert_eq!(caps.supports_op(&DataOperationKind::List), read);
        prop_assert_eq!(caps.supports_op(&DataOperationKind::Get), read);
        prop_assert_eq!(caps.supports_op(&DataOperationKind::Insert), write);
        prop_assert_eq!(caps.supports_op(&DataOperationKind::Update), write);
        prop_assert_eq!(caps.supports_op(&DataOperationKind::Delete), write);
        prop_assert_eq!(caps.supports_op(&DataOperationKind::Upsert), upsert);
        prop_assert_eq!(caps.supports_op(&DataOperationKind::Batch), batch);
        prop_assert_eq!(caps.supports_op(&DataOperationKind::Aggregate), aggregate);
    }

    /// Flipping ANY route capability (introspect/schema_ddl/ddl) never changes a
    /// supports_op answer.
    #[test]
    fn prop_route_caps_never_change_supports_op(
        introspect in any::<bool>(), schema_ddl in any::<bool>(), ddl in any::<bool>()
    ) {
        let base = EngineCapabilities::mongodb();
        let before: Vec<_> = DataOperationKind::ALL.iter().map(|k| base.supports_op(k)).collect();
        let mut caps = base.clone();
        caps.introspect = introspect; caps.schema_ddl = schema_ddl; caps.ddl = ddl;
        let after: Vec<_> = DataOperationKind::ALL.iter().map(|k| caps.supports_op(k)).collect();
        prop_assert_eq!(before, after);
    }

    /// from_mount never panics and only ever produces one of the four variants;
    /// any string outside the four known tokens (after trim) degrades to SharedRls.
    #[test]
    fn prop_from_mount_total(s in ".{0,30}") {
        let iso = Isolation::from_mount(Some(&s));
        let known = matches!(
            s.trim(),
            "schema_per_tenant" | "db_per_tenant" | "tenant_owned" | "shared_rls"
        );
        if !known {
            prop_assert_eq!(iso, Isolation::SharedRls);
        }
        prop_assert!(matches!(
            iso,
            Isolation::SharedRls | Isolation::SchemaPerTenant | Isolation::DbPerTenant | Isolation::TenantOwned
        ));
    }

    /// safe_schema output, when Some, is always all-`[a-z0-9_]`, prefixed
    /// `tenant_`, ends in an 8-hex hash, and never exceeds 56 chars.
    #[test]
    fn prop_safe_schema_shape(raw in ".{0,80}") {
        if let Some(s) = safe_schema(&raw) {
            prop_assert!(s.starts_with("tenant_"));
            prop_assert!(s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'));
            prop_assert!(s.len() <= 7 + 40 + 1 + 8);
            let hash = s.rsplit('_').next().unwrap();
            prop_assert_eq!(hash.len(), 8);
            prop_assert!(hash.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        }
    }

    /// safe_schema is deterministic for any input.
    #[test]
    fn prop_safe_schema_stable(raw in ".{0,40}") {
        prop_assert_eq!(safe_schema(&raw), safe_schema(&raw));
    }

    /// The documented collision-fold guarantee: a base id and its
    /// case/separator-folded twins (which share the SAME sanitized fragment)
    /// get DISTINCT schemas via the raw-id hash suffix. (A universal
    /// distinct-raw→distinct-schema claim is NOT made here: the suffix is a
    /// 32-bit tag, so the design pins the fold classes, not every possible
    /// raw pair — see the source's colliding-pair tests.)
    #[test]
    fn prop_case_separator_folds_stay_distinct(core in "[a-z]{2,10}") {
        // `core`, `CORE`, and `co-re`/`co.re` all fold to the same fragment.
        let lower = safe_schema(&core).unwrap();
        let upper = safe_schema(&core.to_uppercase()).unwrap();
        prop_assert_ne!(&lower, &upper, "case fold must not collide: {}", core);
        if core.len() >= 2 {
            // Insert a separator that sanitizes away, making a distinct raw id
            // with the same fragment.
            let dotted = format!("{}.{}", &core[..1], &core[1..]);
            let s = safe_schema(&dotted).unwrap();
            prop_assert_ne!(lower, s, "separator fold must not collide: {} vs {}", core, dotted);
        }
    }
}
