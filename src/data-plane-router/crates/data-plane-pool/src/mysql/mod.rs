/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mod.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:28:39 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:28:41 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! MySQL engine adapter — R7.
//!
//! Mirrors the design of [`crate::postgres`] but for the official
//! `mysql_async` crate. The driver owns a connection pool per
//! [`DatabaseMount::pool_key`] so the hot path never pays the connect cost the
//! legacy `MysqlEngine` TypeScript adapter does on every request
//! (`mysql.createConnection(...)` per call).
//!
//! Tenant isolation:
//!   * MySQL has no GUC equivalent to Postgres `set_config('app.current_*')`,
//!     so this adapter intersects every read filter with `owner_id = ?` server-
//!     side and re-injects `owner_id` into every write payload from the
//!     verified [`RequestIdentity`] before reaching the wire. A forged client
//!     filter or body cannot leak cross-tenant rows.
//!   * Parity contract with the legacy
//!     [`src/apps/query-router/src/engines/mysql.engine.ts`] is preserved:
//!     `owner_id` is the only column the adapter enforces (TS does not write
//!     `tenant_id` either; per-tenant DB isolation lives at the mount layer).
//!
//! Pattern stack:
//!   * Adapter (GoF)       — implements [`EngineAdapter`].
//!   * Object Pool         — `mysql_async::Pool` is already a connection pool.
//!   * Strategy            — operation kind switches the executor branch.
//!   * Template Method     — `build_owner_filter`/`build_owned_columns` shared
//!     across all read/write code paths.
//!
//! Split into concern-scoped submodules (pure file reorganization, byte-identical
//! behavior): [`adapter`] (EngineAdapter + dispatch), [`pool`] (EnginePool/Tx),
//! [`query`] (CRUD/SQL builders + owner scoping sink), [`convert`] (json↔native),
//! [`schema`] (introspection + DDL builders), [`error`] (conflict classify).

// Shared imports re-exported to the submodules (and the test module) via
// `use super::*;` — kept `pub(super)` so nothing widens the crate surface.
pub(super) use crate::ident::quote_mysql_ident;
pub(super) use crate::resolver::MountResolver;
pub(super) use async_trait::async_trait;
pub(super) use data_plane_core::{
    validate_default_expr, AggFunc, Aggregate, BatchItemOutcome, BatchItemStatus, BatchSummary,
    ColumnSchema, DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult,
    DatabaseMount, DdlColumnDef, EngineAdapter, EngineCapabilities, EngineHealth, EnginePool,
    Filter, ForeignKeyRef, MigrationRequest, MigrationResult, MigrationStatus, NormalizedType,
    RawStatement, RequestIdentity, SchemaDdlOp, SchemaDdlRequest, SchemaDdlResult, SchemaDdlStatus,
    SchemaDescriptor, TableSchema, TxBeginRequest, TxHandle,
};
pub(super) use mysql_async::prelude::Queryable;
pub(super) use mysql_async::{Column, Value as MysqlValue};
pub(super) use mysql_async::{
    Conn, Opts, OptsBuilder, Params, Pool, PoolConstraints, PoolOpts, Row, TxOpts,
};
pub(super) use serde_json::{Map as JsonMap, Value};
pub(super) use std::collections::BTreeMap;
pub(super) use std::sync::Arc;
pub(super) use tokio::sync::Mutex;

mod adapter;
mod convert;
mod error;
mod pool;
mod query;
mod schema;
mod scope;

/// Fields the server controls — strip from any client payload before write,
/// re-inject from the verified identity. Same defensive posture as the Mongo
/// adapter's `RESERVED_FIELDS`.
const RESERVED_COLUMNS: [&str; 1] = ["owner_id"];

// ── crate-facing facade ──────────────────────────────────────────────────────
// `MysqlEngineAdapter` is the only item `lib.rs` re-exports — reached as
// `crate::mysql::MysqlEngineAdapter` exactly as before the split.
// `MysqlPool`/`MysqlTxHandle` keep their original `pub` visibility on the struct
// definitions (in `pool`), but were never re-exported by `lib.rs`, so we don't
// surface them here either (a re-export nothing consumes would warn).
pub use adapter::MysqlEngineAdapter;
// `SUPPORTED_OPS` is read by the capability-honesty battery as
// `crate::mysql::SUPPORTED_OPS`.
#[cfg(test)]
pub(crate) use adapter::SUPPORTED_OPS;

// The test module below reaches the security-critical helpers it exercises
// through `super::*`; bring them into this (parent) scope for that purpose.
// They stay `pub(super)` in their defining submodule (narrower than the
// original file-private `fn`, never wider); these re-imports are gated to the
// test build so a non-test compile never sees them as unused.
#[cfg(test)]
use adapter::resolve_namespace;
#[cfg(test)]
use convert::{json_number_from_f64, json_to_mysql_value, mysql_value_to_json};
#[cfg(test)]
use error::{backend, classify_mysql_error, ddl_backend};
#[cfg(test)]
use schema::{build_mysql_ddl, mysql_sql_type, normalize_mysql_type};
#[cfg(test)]
use scope::{build_order_by, build_owned_columns, build_owner_filter, build_safe_columns};

// ── unit tests (security-critical bits) ─────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;
    use data_plane_core::IdentitySource;
    use serde_json::json;

    fn identity_with(user: Option<&str>) -> RequestIdentity {
        RequestIdentity {
            tenant_id: "t-1".to_string(),
            project_id: None,
            app_id: None,
            user_id: user.map(str::to_string),
            roles: vec![],
            scopes: vec![],
            source: IdentitySource::Test,
        }
    }

    #[test]
    fn ddl_errors_classify_schema_shape_mistakes_as_client_errors() {
        // Deterministic user errors must be 4xx — a 5xx makes outbox clients
        // retry a doomed request forever (poison-pill).
        let dup = classify_mysql_error("Duplicate column name 'status'".into(), true);
        assert!(matches!(dup, DataPlaneError::Conflict { .. }), "{dup:?}");
        let missing = classify_mysql_error(
            "Can't DROP 'ghost'; check that column/key exists".into(),
            true,
        );
        assert!(
            matches!(missing, DataPlaneError::InvalidRequest { .. }),
            "{missing:?}"
        );
        let no_table = classify_mysql_error("Table 'ops.ghost' doesn't exist".into(), true);
        assert!(
            matches!(no_table, DataPlaneError::InvalidRequest { .. }),
            "{no_table:?}"
        );
        // The query (non-DDL) path keeps its existing Backend mapping.
        let query_path = classify_mysql_error("Unknown column 'x' in 'field list'".into(), false);
        assert!(
            matches!(query_path, DataPlaneError::Backend { .. }),
            "{query_path:?}"
        );
    }

    #[test]
    fn owner_filter_always_injects_owner_predicate() {
        let id = identity_with(Some("u-1"));
        let (sql, params) = build_owner_filter(None, &id, true).unwrap();
        assert_eq!(sql, " WHERE `owner_id` = ?");
        assert_eq!(params.len(), 1);
        assert!(matches!(&params[0], MysqlValue::Bytes(b) if b == b"u-1"));
    }

    #[test]
    fn shared_table_skips_owner_scoping_but_still_strips_reserved() {
        // F1: a NAMED shared table (`scoped = false`) reads ACROSS owners — no
        // `owner_id = ?` predicate is appended, so an empty client filter yields
        // NO `WHERE` clause and binds NO params.
        let id = identity_with(Some("u-1"));
        let (sql, params) = build_owner_filter(None, &id, false).unwrap();
        assert_eq!(sql, "");
        assert!(params.is_empty());

        // A client filter on a shared read is honored WITHOUT the owner predicate,
        // yet a forged `owner_id` in the client filter is STILL stripped (a shared
        // read can't be tricked into self-scoping or forging a different owner).
        let filter = json!({ "owner_id": "u-attacker", "region": "eu" });
        let (sql, params) = build_owner_filter(Some(&filter), &id, false).unwrap();
        assert_eq!(sql, " WHERE (`region` = ?)");
        assert!(!sql.contains("owner_id"));
        assert_eq!(params.len(), 1);
        assert!(matches!(&params[0], MysqlValue::Bytes(b) if b == b"eu"));

        // A write to a shared table carries NO trusted owner_id stamp.
        let data = json!({ "owner_id": "u-attacker", "name": "ok" });
        let cols = build_owned_columns(Some(&data), &id, false).unwrap();
        assert!(!cols.iter().any(|(c, _)| c == "owner_id"));
        assert_eq!(cols.len(), 1);
        assert_eq!(cols[0].0, "name");
    }

    #[test]
    fn shared_pool_scopes_each_request_by_its_own_owner() {
        // SHARE_POOLS isolation proof: a pool shared across tenants holds NO
        // tenant state — the owner predicate is bound from THIS request's
        // identity, so two tenants sharing one pool get two different owner
        // filters and can never read each other's rows. This is what makes
        // skipping the single-owner `check_tenant` guard safe on MySQL.
        let (_, pa) = build_owner_filter(None, &identity_with(Some("api-key:a")), true).unwrap();
        let (_, pb) = build_owner_filter(None, &identity_with(Some("api-key:b")), true).unwrap();
        assert!(matches!(&pa[0], MysqlValue::Bytes(b) if b == b"api-key:a"));
        assert!(matches!(&pb[0], MysqlValue::Bytes(b) if b == b"api-key:b"));
    }

    #[test]
    fn owner_filter_lowers_operators_not_just_equality() {
        // THE bug fix: an operator object is now a real predicate, not silently
        // bound as a literal value (which matched zero rows).
        let id = identity_with(Some("u-1"));
        // The client filter is always parenthesized so the trusted `owner_id`
        // AND scopes the WHOLE predicate (the `$or` case is the security proof).
        let cases = [
            (
                json!({ "age": { "$gte": 18 } }),
                " WHERE (`age` >= ?) AND `owner_id` = ?",
            ),
            (
                json!({ "status": { "$in": ["a", "b"] } }),
                " WHERE (`status` IN (?, ?)) AND `owner_id` = ?",
            ),
            (
                json!({ "n": { "$between": [1, 9] } }),
                " WHERE (`n` BETWEEN ? AND ?) AND `owner_id` = ?",
            ),
            (
                json!({ "x": { "$null": true } }),
                " WHERE (`x` IS NULL) AND `owner_id` = ?",
            ),
            (
                json!({ "name": { "$ilike": "a%" } }),
                " WHERE (LOWER(`name`) LIKE LOWER(?)) AND `owner_id` = ?",
            ),
            (
                json!({ "$or": [{ "a": 1 }, { "b": { "$lt": 5 } }] }),
                " WHERE ((`a` = ?) OR (`b` < ?)) AND `owner_id` = ?",
            ),
            (
                json!({ "name": "x" }),
                " WHERE (`name` = ?) AND `owner_id` = ?",
            ), // equality still works
        ];
        for (filter, expected) in cases {
            let (sql, _) = build_owner_filter(Some(&filter), &id, true).unwrap();
            assert_eq!(sql, expected, "filter {filter}");
        }
    }

    #[test]
    fn owner_filter_rejects_unknown_operator() {
        let id = identity_with(Some("u-1"));
        let err = build_owner_filter(Some(&json!({ "a": { "$drop": 1 } })), &id, true).unwrap_err();
        assert!(
            matches!(err, DataPlaneError::InvalidRequest { .. }),
            "{err:?}"
        );
    }

    #[test]
    fn update_delete_refuse_unconstrained_filter() {
        // No empty/tautology full-table mutation (parity with the Postgres guard).
        let unconstrained = [
            None,
            Some(json!({})),
            Some(json!({ "$not": { "$or": [] } })),
            Some(json!({ "owner_id": "x" })), // only a reserved key → empty after strip
        ];
        for filter in unconstrained {
            let err =
                crate::sql_scope::guard_constraining_filter(filter.as_ref(), &RESERVED_COLUMNS)
                    .unwrap_err();
            assert!(
                matches!(err, DataPlaneError::InvalidRequest { .. }),
                "{filter:?}: {err:?}"
            );
        }
        assert!(crate::sql_scope::guard_constraining_filter(
            Some(&json!({ "id": 1 })),
            &RESERVED_COLUMNS
        )
        .is_ok());
    }

    #[test]
    fn owner_filter_drops_client_owner_id_override() {
        let id = identity_with(Some("u-trusted"));
        let filter = json!({"owner_id": "u-attacker", "name": "needle"});
        let (sql, params) = build_owner_filter(Some(&filter), &id, true).unwrap();
        // Client `owner_id` is dropped, only the trusted one is appended at the end.
        assert!(sql.contains("`name` = ?"));
        assert!(sql.ends_with("`owner_id` = ?"));
        // Last param is always the trusted owner_id.
        assert!(matches!(params.last(), Some(MysqlValue::Bytes(b)) if b == b"u-trusted"));
    }

    #[test]
    fn owner_filter_falls_back_to_tenant_id() {
        let id = identity_with(None);
        let (_, params) = build_owner_filter(None, &id, true).unwrap();
        assert!(matches!(&params[0], MysqlValue::Bytes(b) if b == b"t-1"));
    }

    #[test]
    fn owner_filter_rejects_non_object_filter() {
        let id = identity_with(Some("u-1"));
        let bad = json!("just a string");
        let err = build_owner_filter(Some(&bad), &id, true).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }));
    }

    #[test]
    fn owner_filter_rejects_injection_via_column_name() {
        let id = identity_with(Some("u-1"));
        let bad = json!({"name; DROP TABLE users;--": "x"});
        let err = build_owner_filter(Some(&bad), &id, true).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidIdentifier { .. }));
    }

    #[test]
    fn owned_columns_strips_client_owner_id_and_appends_trusted_one() {
        let id = identity_with(Some("u-trusted"));
        let data = json!({"owner_id": "u-attacker", "name": "ok"});
        let cols = build_owned_columns(Some(&data), &id, true).unwrap();
        let names: Vec<&str> = cols.iter().map(|(c, _)| c.as_str()).collect();
        assert!(!names.contains(&"owner_id") || names.last().copied() == Some("owner_id"));
        // owner_id must appear exactly once and be the trusted value.
        let owner_occurrences: Vec<&Value> = cols
            .iter()
            .filter(|(c, _)| c == "owner_id")
            .map(|(_, v)| v)
            .collect();
        assert_eq!(owner_occurrences.len(), 1);
        assert_eq!(
            owner_occurrences[0],
            &Value::String("u-trusted".to_string())
        );
    }

    #[test]
    fn owned_columns_rejects_missing_data() {
        let id = identity_with(Some("u-1"));
        let err = build_owned_columns(None, &id, true).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }));
    }

    #[test]
    fn safe_columns_strips_owner_id() {
        let data = json!({"owner_id": "u-attacker", "name": "ok"});
        let cols = build_safe_columns(Some(&data)).unwrap();
        for (c, _) in &cols {
            assert_ne!(c, "owner_id");
        }
        assert_eq!(cols.len(), 1);
    }

    #[test]
    fn order_by_quotes_identifiers_and_caps_direction() {
        let mut sort = BTreeMap::new();
        sort.insert("created_at".to_string(), "desc".to_string());
        sort.insert("name".to_string(), "asc".to_string());
        let sql = build_order_by(Some(&sort)).unwrap();
        assert!(sql.contains("`created_at` DESC"));
        assert!(sql.contains("`name` ASC"));
    }

    #[test]
    fn order_by_rejects_injection_via_column() {
        let mut sort = BTreeMap::new();
        sort.insert("name; DROP".to_string(), "asc".to_string());
        assert!(build_order_by(Some(&sort)).is_err());
    }

    #[test]
    fn json_to_mysql_value_handles_scalars() {
        assert!(matches!(
            json_to_mysql_value(&Value::Null),
            MysqlValue::NULL
        ));
        assert!(matches!(
            json_to_mysql_value(&json!(42)),
            MysqlValue::Int(42)
        ));
        assert!(matches!(
            json_to_mysql_value(&json!(true)),
            MysqlValue::Int(1)
        ));
        assert!(matches!(
            json_to_mysql_value(&json!("hi")),
            MysqlValue::Bytes(b) if b == b"hi"
        ));
    }

    #[test]
    fn json_to_mysql_value_encodes_objects_as_json_string() {
        let v = json!({"k": 1});
        let MysqlValue::Bytes(bytes) = json_to_mysql_value(&v) else {
            panic!("expected Bytes");
        };
        let as_str = String::from_utf8(bytes).unwrap();
        assert_eq!(as_str, r#"{"k":1}"#);
    }

    #[test]
    fn mysql_value_to_json_roundtrips_int_string_null() {
        assert_eq!(mysql_value_to_json(MysqlValue::NULL), Value::Null);
        assert_eq!(
            mysql_value_to_json(MysqlValue::Int(7)),
            Value::Number(7i64.into())
        );
        assert_eq!(
            mysql_value_to_json(MysqlValue::Bytes(b"hello".to_vec())),
            Value::String("hello".to_string())
        );
    }

    #[test]
    fn resolve_namespace_only_for_schema_per_tenant() {
        // Parity with redis's resolve_namespace test: the per-tenant database is
        // selected ONLY for `schema_per_tenant`; every other strategy → None
        // (DSN-default db, byte-identical to before G5). The schema_per_tenant
        // name carries the collision-free `_<hash8>` suffix, so match the prefix.
        use data_plane_core::{CredentialRef, DatabaseMount, PoolPolicy};
        let mk = |iso: Option<&str>| DatabaseMount {
            id: "db1".into(),
            tenant_id: "t-1".into(),
            project_id: None,
            engine: "mysql".into(),
            name: "n".into(),
            credential_ref: CredentialRef {
                provider: "adapter-registry".into(),
                reference: "r".into(),
                version: "1".into(),
            },
            pool_policy: PoolPolicy::default(),
            capability_overrides: None,
            inline_dsn: None,
            isolation: iso.map(str::to_string),
            replica_inline_dsn: None,
            read_replica_route: false,
        };
        assert_eq!(resolve_namespace(&mk(None)), None);
        assert_eq!(resolve_namespace(&mk(Some("shared_rls"))), None);
        assert_eq!(resolve_namespace(&mk(Some("db_per_tenant"))), None);
        let ns = resolve_namespace(&mk(Some("schema_per_tenant"))).unwrap();
        assert!(ns.starts_with("tenant_t_1_"), "{ns}");
    }

    // --- M22 schema introspection: pure type normalizer (golden table) ---

    #[test]
    fn normalize_mysql_type_golden_table() {
        use NormalizedType as N;
        for (native, expected) in [
            ("int", N::Integer),
            ("int(11)", N::Integer),
            ("bigint(20) unsigned", N::Integer),
            ("smallint", N::Integer),
            ("tinyint(4)", N::Integer),
            ("tinyint(1)", N::Boolean), // the MySQL boolean convention
            ("tinyint(1) unsigned", N::Boolean),
            ("float", N::Float),
            ("double", N::Float),
            ("decimal(10,2)", N::Decimal),
            ("date", N::Date),
            ("datetime", N::Datetime),
            ("timestamp", N::Datetime),
            ("json", N::Json),
            ("char(36)", N::Text),
            ("varchar(255)", N::Text),
            ("text", N::Text),
            ("blob", N::Unknown),
            ("geometry", N::Unknown),
        ] {
            let (ty, values) = normalize_mysql_type(native);
            assert_eq!(ty, expected, "COLUMN_TYPE {native}");
            assert_eq!(values, None, "{native} carries no enum values");
        }
    }

    #[test]
    fn normalize_mysql_type_parses_enum_values() {
        let (ty, values) = normalize_mysql_type("enum('pending','paid','shipped','cancelled')");
        assert_eq!(ty, NormalizedType::Enum);
        assert_eq!(
            values,
            Some(vec![
                "pending".to_string(),
                "paid".to_string(),
                "shipped".to_string(),
                "cancelled".to_string(),
            ])
        );
        // Quote escaping (`''` → literal quote) and case-insensitive keyword.
        let (ty, values) = normalize_mysql_type("ENUM('it''s','b')");
        assert_eq!(ty, NormalizedType::Enum);
        assert_eq!(values, Some(vec!["it's".to_string(), "b".to_string()]));
        // Single value, no trailing garbage.
        let (_, values) = normalize_mysql_type("enum('only')");
        assert_eq!(values, Some(vec!["only".to_string()]));
    }

    // --- M22 step 2: schema DDL — pure SQL builders (golden tables) ---

    use data_plane_core::{DdlColumnDef, SchemaDdlOp, SchemaDdlRequest};

    fn col(name: &str, ty: NormalizedType) -> DdlColumnDef {
        DdlColumnDef {
            name: name.to_string(),
            normalized_type: ty,
            nullable: true,
            default: None,
            enum_values: None,
        }
    }

    fn ddl(op: SchemaDdlOp, table: &str) -> SchemaDdlRequest {
        SchemaDdlRequest {
            op,
            table: table.to_string(),
            column: None,
            column_name: None,
            columns: None,
            primary_key: None,
        }
    }

    #[test]
    fn mysql_sql_type_golden_table() {
        use NormalizedType as N;
        for (ty, expected) in [
            (N::Text, "TEXT"),
            (N::Integer, "BIGINT"),
            (N::Float, "DOUBLE"),
            (N::Decimal, "DECIMAL(18,6)"),
            (N::Boolean, "TINYINT(1)"),
            (N::Date, "DATE"),
            (N::Datetime, "DATETIME"),
            (N::Json, "JSON"),
            (N::Uuid, "CHAR(36)"),
            (N::Array, "JSON"),
        ] {
            assert_eq!(
                mysql_sql_type(&col("c", ty), false).unwrap(),
                expected,
                "{ty:?}"
            );
        }
        // text inside a PRIMARY KEY needs a bounded type.
        assert_eq!(
            mysql_sql_type(&col("c", N::Text), true).unwrap(),
            "VARCHAR(255)"
        );
        // enum values are escaped literals (quote doubled, backslash escaped).
        let mut status = col("status", N::Enum);
        status.enum_values = Some(vec!["pending".into(), "it's".into(), "a\\b".into()]);
        assert_eq!(
            mysql_sql_type(&status, false).unwrap(),
            "ENUM('pending', 'it''s', 'a\\\\b')"
        );
        // enum without values, and describe-only types, are client errors.
        assert!(mysql_sql_type(&col("c", N::Enum), false).is_err());
        for ty in [N::Objectid, N::Unknown] {
            assert!(matches!(
                mysql_sql_type(&col("c", ty), false).unwrap_err(),
                DataPlaneError::InvalidRequest { .. }
            ));
        }
    }

    #[test]
    fn mysql_ddl_statements_golden() {
        // add_column with full attributes
        let mut add = ddl(SchemaDdlOp::AddColumn, "orders");
        add.column = Some(DdlColumnDef {
            name: "qty".into(),
            normalized_type: NormalizedType::Integer,
            nullable: false,
            default: Some("0".into()),
            enum_values: None,
        });
        assert_eq!(
            build_mysql_ddl(&add).unwrap(),
            "ALTER TABLE `orders` ADD COLUMN `qty` BIGINT NOT NULL DEFAULT 0"
        );
        // drop_column
        let mut drop_col = ddl(SchemaDdlOp::DropColumn, "orders");
        drop_col.column_name = Some("qty".into());
        assert_eq!(
            build_mysql_ddl(&drop_col).unwrap(),
            "ALTER TABLE `orders` DROP COLUMN `qty`"
        );
        // alter_column_type → MODIFY with the FULL def (nullability explicit,
        // because MODIFY resets attributes).
        let mut alter = ddl(SchemaDdlOp::AlterColumnType, "orders");
        alter.column = Some(col("note", NormalizedType::Text));
        assert_eq!(
            build_mysql_ddl(&alter).unwrap(),
            "ALTER TABLE `orders` MODIFY COLUMN `note` TEXT NULL"
        );
        // drop_table
        assert_eq!(
            build_mysql_ddl(&ddl(SchemaDdlOp::DropTable, "orders")).unwrap(),
            "DROP TABLE `orders`"
        );
    }

    #[test]
    fn mysql_ddl_create_table_appends_owner_and_uses_varchar_pk() {
        let mut create = ddl(SchemaDdlOp::CreateTable, "orders");
        create.columns = Some(vec![
            DdlColumnDef {
                name: "sku".into(),
                normalized_type: NormalizedType::Text,
                nullable: false,
                default: None,
                enum_values: None,
            },
            col("note", NormalizedType::Text),
        ]);
        create.primary_key = Some(vec!["sku".into()]);
        assert_eq!(
            build_mysql_ddl(&create).unwrap(),
            "CREATE TABLE `orders` (`sku` VARCHAR(255) NOT NULL, `note` TEXT NULL, \
             `owner_id` VARCHAR(64), PRIMARY KEY (`sku`))"
        );
        // explicit owner_id is respected, not duplicated.
        let mut explicit = ddl(SchemaDdlOp::CreateTable, "orders");
        explicit.columns = Some(vec![
            DdlColumnDef {
                name: "id".into(),
                normalized_type: NormalizedType::Integer,
                nullable: false,
                default: None,
                enum_values: None,
            },
            col("owner_id", NormalizedType::Uuid),
        ]);
        explicit.primary_key = Some(vec!["id".into()]);
        let sql = build_mysql_ddl(&explicit).unwrap();
        assert_eq!(sql.matches("owner_id").count(), 1, "{sql}");
    }

    #[test]
    fn mysql_ddl_rejects_injection_and_unsafe_defaults() {
        assert!(matches!(
            build_mysql_ddl(&ddl(SchemaDdlOp::DropTable, "orders`; DROP TABLE x")).unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
        let mut bad_default = ddl(SchemaDdlOp::AddColumn, "orders");
        bad_default.column = Some(DdlColumnDef {
            name: "c".into(),
            normalized_type: NormalizedType::Text,
            nullable: true,
            default: Some("'x'; DROP TABLE orders".into()),
            enum_values: None,
        });
        assert!(matches!(
            build_mysql_ddl(&bad_default).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
    }

    #[test]
    fn mysql_error_classifier_maps_ddl_cast_errors_to_conflict() {
        // Truncation / incorrect-value (1264/1265/1292/1366: bad enum value,
        // unparseable date, overflow) → Conflict on BOTH paths now: on writes
        // they mean the caller's VALUE doesn't fit the column — a 5xx made
        // the live UI outbox retry a doomed write forever (M23 battery pin).
        for msg in [
            "Server error: `ERROR 1265 (01000): Data truncated for column 'n' at row 1'",
            "Server error: `ERROR 1292 (22007): Truncated incorrect DOUBLE value: 'abc'",
            "Server error: `ERROR 1366 (HY000): Incorrect integer value: 'abc' for column 'n' at row 1",
            "Server error: `ERROR 1264 (22003): Out of range value for column 'total' at row 1",
        ] {
            assert!(
                matches!(ddl_backend(msg), DataPlaneError::Conflict { .. }),
                "{msg}"
            );
            assert!(
                matches!(backend(msg), DataPlaneError::Conflict { .. }),
                "{msg}"
            );
        }
        // Integrity violations stay Conflict on BOTH paths (pre-existing).
        for msg in [
            "Duplicate entry 'x' for key 'PRIMARY'",
            "a foreign key constraint fails",
        ] {
            assert!(
                matches!(backend(msg), DataPlaneError::Conflict { .. }),
                "{msg}"
            );
            assert!(
                matches!(ddl_backend(msg), DataPlaneError::Conflict { .. }),
                "{msg}"
            );
        }
        // Anything else is a Backend error on both paths.
        assert!(matches!(
            ddl_backend("connection reset"),
            DataPlaneError::Backend { .. }
        ));
    }

    // ── value conversion: json_to_mysql_value (every JSON type) ──────────────

    #[test]
    fn json_to_mysql_value_null_bool_int() {
        assert!(matches!(
            json_to_mysql_value(&Value::Null),
            MysqlValue::NULL
        ));
        assert!(matches!(
            json_to_mysql_value(&json!(true)),
            MysqlValue::Int(1)
        ));
        assert!(matches!(
            json_to_mysql_value(&json!(false)),
            MysqlValue::Int(0)
        ));
        assert!(matches!(json_to_mysql_value(&json!(0)), MysqlValue::Int(0)));
        assert!(matches!(
            json_to_mysql_value(&json!(-99)),
            MysqlValue::Int(-99)
        ));
    }

    #[test]
    fn json_to_mysql_value_i64_extremes_use_int() {
        assert!(matches!(
            json_to_mysql_value(&json!(i64::MAX)),
            MysqlValue::Int(i) if i == i64::MAX
        ));
        assert!(matches!(
            json_to_mysql_value(&json!(i64::MIN)),
            MysqlValue::Int(i) if i == i64::MIN
        ));
    }

    #[test]
    fn json_to_mysql_value_u64_above_i64_max_uses_uint() {
        // u64::MAX has no i64 form, so it takes the UInt arm (NOT the float arm
        // — MySQL preserves the full unsigned 64-bit value).
        assert!(matches!(
            json_to_mysql_value(&json!(u64::MAX)),
            MysqlValue::UInt(u) if u == u64::MAX
        ));
        // A value just above i64::MAX still goes UInt.
        let just_over = (i64::MAX as u64) + 1;
        assert!(matches!(
            json_to_mysql_value(&json!(just_over)),
            MysqlValue::UInt(u) if u == just_over
        ));
    }

    #[test]
    fn json_to_mysql_value_floats_use_double() {
        for (v, want) in [
            (json!(3.5), 3.5_f64),
            (json!(-2.5e9), -2.5e9),
            (json!(0.5), 0.5),
        ] {
            assert!(
                matches!(json_to_mysql_value(&v), MysqlValue::Double(d) if d == want),
                "value {v}"
            );
        }
    }

    #[test]
    fn json_to_mysql_value_empty_and_unicode_strings() {
        assert!(matches!(
            json_to_mysql_value(&json!("")),
            MysqlValue::Bytes(b) if b.is_empty()
        ));
        let MysqlValue::Bytes(b) = json_to_mysql_value(&json!("héllo-🦀")) else {
            panic!("expected Bytes");
        };
        assert_eq!(b, "héllo-🦀".as_bytes());
    }

    #[test]
    fn json_to_mysql_value_arrays_become_json_bytes() {
        let MysqlValue::Bytes(b) = json_to_mysql_value(&json!([1, 2, 3])) else {
            panic!("expected Bytes for array");
        };
        assert_eq!(String::from_utf8(b).unwrap(), "[1,2,3]");
        let MysqlValue::Bytes(nested) = json_to_mysql_value(&json!({ "a": [true, null] })) else {
            panic!("expected Bytes for object");
        };
        assert_eq!(String::from_utf8(nested).unwrap(), r#"{"a":[true,null]}"#);
    }

    // ── value conversion: mysql_value_to_json (round-trip & edge) ────────────

    #[test]
    fn mysql_value_to_json_scalars_and_uint() {
        assert_eq!(mysql_value_to_json(MysqlValue::NULL), Value::Null);
        assert_eq!(mysql_value_to_json(MysqlValue::Int(7)), json!(7));
        assert_eq!(mysql_value_to_json(MysqlValue::Int(-3)), json!(-3));
        assert_eq!(
            mysql_value_to_json(MysqlValue::UInt(u64::MAX)),
            Value::Number(serde_json::Number::from(u64::MAX))
        );
    }

    #[test]
    fn mysql_value_to_json_float_and_double() {
        assert_eq!(mysql_value_to_json(MysqlValue::Double(2.5)), json!(2.5));
        assert_eq!(mysql_value_to_json(MysqlValue::Float(1.5_f32)), json!(1.5));
    }

    #[test]
    fn mysql_value_to_json_bytes_utf8_and_non_utf8() {
        assert_eq!(
            mysql_value_to_json(MysqlValue::Bytes(b"hello".to_vec())),
            json!("hello")
        );
        assert_eq!(
            mysql_value_to_json(MysqlValue::Bytes(Vec::new())),
            json!("")
        );
        // Invalid UTF-8 surfaces as Null rather than panicking.
        assert_eq!(
            mysql_value_to_json(MysqlValue::Bytes(vec![0xff, 0xfe, 0x00])),
            Value::Null
        );
    }

    #[test]
    fn mysql_value_to_json_date_and_time_format() {
        assert_eq!(
            mysql_value_to_json(MysqlValue::Date(2026, 6, 17, 12, 30, 45, 123456)),
            json!("2026-06-17T12:30:45.123456Z")
        );
        assert_eq!(
            mysql_value_to_json(MysqlValue::Time(false, 1, 2, 3, 4, 5)),
            json!("26:03:04.000005") // 1 day + 2h = 26h
        );
        assert_eq!(
            mysql_value_to_json(MysqlValue::Time(true, 0, 5, 6, 7, 8)),
            json!("-05:06:07.000008")
        );
    }

    #[test]
    fn mysql_value_round_trips_scalars_through_both_directions() {
        for v in [json!(42), json!("text"), Value::Null] {
            let back = mysql_value_to_json(json_to_mysql_value(&v));
            assert_eq!(back, v, "round-trip {v}");
        }
        // bool → Int(1) → number 1 (MySQL has no native bool).
        assert_eq!(
            mysql_value_to_json(json_to_mysql_value(&json!(true))),
            json!(1)
        );
    }

    // ── json_number_from_f64: finite vs non-finite ───────────────────────────

    #[test]
    fn json_number_from_f64_handles_finite_and_non_finite() {
        assert_eq!(json_number_from_f64(2.5), json!(2.5));
        assert_eq!(json_number_from_f64(-7.0), json!(-7.0));
        assert_eq!(json_number_from_f64(f64::NAN), Value::Null);
        assert_eq!(json_number_from_f64(f64::INFINITY), Value::Null);
        assert_eq!(json_number_from_f64(f64::NEG_INFINITY), Value::Null);
    }

    // ── identifier quoting: backticks + injection ────────────────────────────

    #[test]
    fn quote_mysql_ident_backticks_plain_and_schema_qualified() {
        assert_eq!(quote_mysql_ident("users").unwrap(), "`users`");
        assert_eq!(quote_mysql_ident("ops.orders").unwrap(), "`ops`.`orders`");
        assert_eq!(quote_mysql_ident("_underscore1").unwrap(), "`_underscore1`");
    }

    #[test]
    fn quote_mysql_ident_rejects_injection_and_bad_shapes() {
        for bad in [
            "",
            "users; DROP TABLE x",
            "a.b.c", // > 1 qualifier
            "1abc",  // leading digit
            "us`er", // embedded backtick
            "u-v",   // hyphen
            "a b",   // space
            "tbl;--",
            "naïve",         // non-ASCII (the ident allowlist is ASCII-only)
            &"a".repeat(64), // segment over 63 chars
        ] {
            assert!(quote_mysql_ident(bad).is_err(), "should reject {bad:?}");
        }
        // exactly 63 chars is the boundary that IS accepted.
        assert!(quote_mysql_ident(&"a".repeat(63)).is_ok());
    }

    // ── classify_mysql_error: full matrix (query path vs DDL path) ───────────

    #[test]
    fn classify_integrity_violations_are_conflict_on_both_paths() {
        for msg in [
            "Duplicate entry 'a@b.c' for key 'users.email'",
            "Cannot add or update a child row: a foreign key constraint fails",
        ] {
            assert!(matches!(
                classify_mysql_error(msg.into(), false),
                DataPlaneError::Conflict { .. }
            ));
            assert!(matches!(
                classify_mysql_error(msg.into(), true),
                DataPlaneError::Conflict { .. }
            ));
        }
    }

    #[test]
    fn classify_truncation_and_range_errors_are_conflict_on_both_paths() {
        for msg in [
            "Data truncated for column 'status' at row 1",
            "Truncated incorrect DECIMAL value: 'x'",
            "Out of range value for column 'qty' at row 1",
            "Incorrect integer value: 'abc' for column 'n'",
        ] {
            assert!(
                matches!(
                    classify_mysql_error(msg.into(), false),
                    DataPlaneError::Conflict { .. }
                ),
                "query path: {msg}"
            );
            assert!(
                matches!(
                    classify_mysql_error(msg.into(), true),
                    DataPlaneError::Conflict { .. }
                ),
                "ddl path: {msg}"
            );
        }
    }

    #[test]
    fn classify_ddl_only_shape_errors_split_by_path() {
        // "duplicate column name" / "already exists" → Conflict, but ONLY on the
        // DDL path; the query path falls through to Backend.
        for msg in [
            "Duplicate column name 'status'",
            "Table 'ops.t' already exists",
        ] {
            assert!(matches!(
                classify_mysql_error(msg.into(), true),
                DataPlaneError::Conflict { .. }
            ));
            assert!(matches!(
                classify_mysql_error(msg.into(), false),
                DataPlaneError::Backend { .. }
            ));
        }
        // "unknown column" / "doesn't exist" / "check that column/key exists"
        // → InvalidRequest on DDL, Backend on the query path.
        for msg in [
            "Unknown column 'ghost' in 'field list'",
            "Table 'ops.ghost' doesn't exist",
            "Can't DROP 'ghost'; check that column/key exists",
        ] {
            assert!(matches!(
                classify_mysql_error(msg.into(), true),
                DataPlaneError::InvalidRequest { .. }
            ));
            assert!(matches!(
                classify_mysql_error(msg.into(), false),
                DataPlaneError::Backend { .. }
            ));
        }
    }

    #[test]
    fn classify_unknown_error_is_backend_on_both_paths() {
        for msg in ["Lost connection to MySQL server", "Access denied for user"] {
            assert!(matches!(
                classify_mysql_error(msg.into(), false),
                DataPlaneError::Backend { .. }
            ));
            assert!(matches!(
                classify_mysql_error(msg.into(), true),
                DataPlaneError::Backend { .. }
            ));
        }
    }

    #[test]
    fn classify_is_case_insensitive() {
        assert!(matches!(
            classify_mysql_error("DUPLICATE ENTRY 'x' FOR KEY 'PRIMARY'".into(), false),
            DataPlaneError::Conflict { .. }
        ));
    }

    #[test]
    fn backend_and_ddl_backend_prefix_the_message() {
        // Both wrappers embed "mysql backend: " before classifying.
        let e = backend("Duplicate entry 'z' for key 'u'");
        if let DataPlaneError::Conflict { message } = e {
            assert!(message.contains("mysql backend:"), "{message}");
        } else {
            panic!("expected Conflict");
        }
    }
}
