//! Microsoft SQL Server engine adapter (R-mssql, Phase 3d).
//!
//! Pure-Rust TDS via `tiberius` + a `bb8` pool (async, no spawn_blocking). The
//! dialect diverges from the other SQL engines in four ways handled here:
//!   * parameters are `@P1, @P2, …` (1-indexed), not `?`;
//!   * identifiers quote with `[brackets]`, escaping `]` as `]]`;
//!   * pagination is `OFFSET n ROWS FETCH NEXT m ROWS ONLY` (requires an
//!     ORDER BY — we synthesize `ORDER BY (SELECT NULL)` when none is given);
//!   * upsert is a `MERGE` arbitrated on `(owner_id, key…)`.
//!
//! Owner scoping is server-side (`owner_id` predicate + owner-stamped writes),
//! exactly like MySQL/SQLite — SQL Server's row-level security is not assumed.
//! Honest descriptor (`EngineCapabilities::mssql`): CRUD + upsert + ATOMIC batch
//! (BEGIN TRAN on one pooled connection) + aggregate + introspection.
//! `transactions:false` — no cross-request pinned TxHandle (same call as SQLite).
//!
//! Split into concern-scoped submodules (pure file reorganization, byte-identical
//! behavior): [`adapter`] (EngineAdapter + pool/TLS config), [`pool`]
//! (EnginePool + run_plan/run_batch), [`query`] (plan builders + owner scoping),
//! [`convert`] (json↔native + type normalize), [`error`] (conflict classify).

// Shared imports re-exported to the submodules (and the test module) via
// `use super::*;` — kept `pub(super)` so nothing widens the crate surface.
pub(super) use crate::resolver::MountResolver;
pub(super) use async_trait::async_trait;
pub(super) use bb8::Pool;
pub(super) use bb8_tiberius::ConnectionManager;
pub(super) use data_plane_core::{
    AggFunc, Aggregate, BatchItemOutcome, BatchItemStatus, BatchSummary, ColumnSchema,
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult, DatabaseMount,
    EngineAdapter, EngineCapabilities, EngineHealth, EnginePool, Filter, NormalizedType,
    RawStatement, RequestIdentity, SchemaDescriptor, TableSchema, TxBeginRequest, TxHandle,
};
pub(super) use serde_json::{Map as JsonMap, Value};
pub(super) use std::borrow::Cow;
pub(super) use std::collections::BTreeMap;
pub(super) use std::sync::Arc;
pub(super) use tiberius::{AuthMethod, ColumnData, Config, ToSql};

mod adapter;
mod convert;
mod error;
mod pool;
mod query;

const RESERVED_COLUMNS: &[&str] = &["owner_id", "tenant_id"];

pub(crate) const SUPPORTED_OPS: &[DataOperationKind] = &[
    DataOperationKind::List,
    DataOperationKind::Get,
    DataOperationKind::Insert,
    DataOperationKind::Update,
    DataOperationKind::Delete,
    DataOperationKind::Upsert,
    DataOperationKind::Aggregate,
    DataOperationKind::Batch,
];

// ── crate-facing facade ──────────────────────────────────────────────────────
// `MssqlEngineAdapter` is the only item `lib.rs` re-exports — reached as
// `crate::mssql::MssqlEngineAdapter` exactly as before the split.
pub use adapter::MssqlEngineAdapter;

// The test module below reaches the helpers it exercises through `super::*`;
// bring them into this (parent) scope for that purpose. They stay `pub(super)`
// in their defining submodule (never wider than the original file-private
// `fn`), and the re-imports are gated to the test build so a non-test compile
// never sees them as unused.
#[cfg(test)]
use convert::{f64_to_json, json_to_param, normalize_mssql_type};
#[cfg(test)]
use error::backend;
#[cfg(test)]
use query::{build_list, quote_ident, Binder, P};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ident_quoting_brackets_and_escapes() {
        assert_eq!(quote_ident("name").unwrap(), "[name]");
        assert_eq!(quote_ident("a]b").unwrap(), "[a]]b]");
        assert!(quote_ident("").is_err());
    }

    #[test]
    fn binder_emits_sequential_placeholders() {
        let mut b = Binder::default();
        assert_eq!(b.bind_value(&serde_json::json!("x")), "@P1");
        assert_eq!(b.bind_value(&serde_json::json!(2)), "@P2");
        assert_eq!(b.params.len(), 2);
    }

    #[test]
    fn list_synthesizes_order_by_for_offset_fetch() {
        let op = DataOperation {
            op: DataOperationKind::List,
            resource: "t".into(),
            data: None,
            filter: None,
            sort: None,
            limit: Some(10),
            offset: Some(0),
            idempotency_key: None,
            expected_version: None,
            returning: None,
            aggregate: None,
            fields: None,
            search: None,
            vector: None,
        };
        let plan = build_list(&op, Some("u1")).unwrap();
        assert!(plan.sql.contains("ORDER BY (SELECT NULL)"), "{}", plan.sql);
        assert!(plan.sql.contains("OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY"), "{}", plan.sql);
        assert!(plan.sql.contains("[owner_id] = @P1"), "{}", plan.sql);
    }

    // ── value conversion: json_to_param (shape per JSON type) ────────────────
    //
    // `P` derives neither Debug nor PartialEq, so each case matches the variant
    // explicitly and inspects the payload.

    use serde_json::json;

    #[test]
    fn json_to_param_null_and_bool() {
        assert!(matches!(json_to_param(&Value::Null), P::Null));
        assert!(matches!(json_to_param(&json!(true)), P::Bool(true)));
        assert!(matches!(json_to_param(&json!(false)), P::Bool(false)));
    }

    #[test]
    fn json_to_param_integers_use_int_arm() {
        for (v, want) in [
            (json!(0), 0_i64),
            (json!(-1), -1),
            (json!(42), 42),
            (json!(i64::MAX), i64::MAX),
            (json!(i64::MIN), i64::MIN),
        ] {
            match json_to_param(&v) {
                P::Int(i) => assert_eq!(i, want, "value {v}"),
                _ => panic!("expected Int for {v}"),
            }
        }
    }

    #[test]
    fn json_to_param_u64_above_i64_max_falls_to_real() {
        // u64::MAX has no i64 form, so it takes the f64 (Real) arm.
        match json_to_param(&json!(u64::MAX)) {
            P::Real(f) => assert!(f > 0.0),
            _ => panic!("expected Real for u64::MAX"),
        }
    }

    #[test]
    fn json_to_param_floats_use_real_arm() {
        for (v, want) in [(json!(3.5), 3.5_f64), (json!(-2.5e9), -2.5e9), (json!(0.0), 0.0)] {
            match json_to_param(&v) {
                P::Real(f) => assert_eq!(f, want, "value {v}"),
                _ => panic!("expected Real for {v}"),
            }
        }
    }

    #[test]
    fn json_to_param_strings_including_empty_and_unicode() {
        for s in ["", "hello", "emoji-🦀-世界", "with 'quote' and ]bracket["] {
            match json_to_param(&json!(s)) {
                P::Text(t) => assert_eq!(t, s, "string {s:?}"),
                _ => panic!("expected Text for {s:?}"),
            }
        }
    }

    #[test]
    fn json_to_param_arrays_and_objects_stringify_to_text() {
        match json_to_param(&json!([1, 2, 3])) {
            P::Text(t) => assert_eq!(t, "[1,2,3]"),
            _ => panic!("expected Text for array"),
        }
        match json_to_param(&json!({ "k": 1 })) {
            P::Text(t) => assert_eq!(t, r#"{"k":1}"#),
            _ => panic!("expected Text for object"),
        }
    }

    // ── identifier quoting: [bracket] escaping + injection ───────────────────

    #[test]
    fn quote_ident_brackets_and_doubles_closing_bracket() {
        assert_eq!(quote_ident("col").unwrap(), "[col]");
        assert_eq!(quote_ident("a]b").unwrap(), "[a]]b]");
        assert_eq!(quote_ident("]]").unwrap(), "[]]]]]");
        // Other "dangerous" SQL chars are SAFE inside a bracket-quoted ident —
        // only `]` needs escaping; the rest are just literal name bytes.
        assert_eq!(quote_ident("a;b--c").unwrap(), "[a;b--c]");
        assert_eq!(quote_ident("a b").unwrap(), "[a b]");
        assert_eq!(quote_ident("a\"b`c").unwrap(), "[a\"b`c]");
    }

    #[test]
    fn quote_ident_rejects_empty_nul_control_and_overlong() {
        assert!(quote_ident("").is_err());
        assert!(quote_ident("a\0b").is_err());
        assert!(quote_ident("a\tb").is_err());
        assert!(quote_ident("a\nb").is_err());
        assert!(quote_ident(&"a".repeat(129)).is_err());
        assert!(quote_ident(&"a".repeat(128)).is_ok());
    }

    #[test]
    fn quote_ident_accepts_unicode_letters() {
        // Unicode is not control/NUL, so a non-ASCII name is bracketed verbatim.
        assert_eq!(quote_ident("café").unwrap(), "[café]");
    }

    // ── conflict classification: backend ─────────────────────────────────────

    #[test]
    fn backend_maps_constraint_messages_to_conflict() {
        for msg in [
            "Violation of UNIQUE KEY constraint 'UX_email'",
            "Cannot insert duplicate key row",
            "Violation of PRIMARY KEY constraint",
            "The INSERT statement conflicted with the FOREIGN KEY constraint",
            "Cannot insert the value NULL into column 'name'",
            "The DELETE statement conflicted with the REFERENCE constraint",
        ] {
            let e = backend(msg);
            assert!(matches!(e, DataPlaneError::Conflict { .. }), "{msg:?} → {e:?}");
        }
    }

    #[test]
    fn backend_maps_generic_messages_to_backend() {
        for msg in [
            "Login failed for user 'sa'",
            "A network-related or instance-specific error occurred",
            "Timeout expired",
        ] {
            let e = backend(msg);
            assert!(matches!(e, DataPlaneError::Backend { .. }), "{msg:?} → {e:?}");
        }
    }

    #[test]
    fn backend_classification_is_case_insensitive() {
        let e = backend("violation of unique key constraint");
        assert!(matches!(e, DataPlaneError::Conflict { .. }), "{e:?}");
    }

    // ── f64_to_json: finite vs non-finite ────────────────────────────────────

    #[test]
    fn f64_to_json_finite_and_non_finite() {
        assert_eq!(f64_to_json(2.5), json!(2.5));
        assert_eq!(f64_to_json(0.0), json!(0.0));
        assert_eq!(f64_to_json(-7.25), json!(-7.25));
        // NaN/Inf are not representable as JSON numbers → Null (never panic).
        assert_eq!(f64_to_json(f64::NAN), Value::Null);
        assert_eq!(f64_to_json(f64::INFINITY), Value::Null);
        assert_eq!(f64_to_json(f64::NEG_INFINITY), Value::Null);
    }

    // ── normalize_mssql_type: native type-name mapping ───────────────────────

    #[test]
    fn normalize_mssql_type_maps_native_names() {
        use NormalizedType::*;
        let cases = [
            ("int", Integer),
            ("bigint", Integer),
            ("smallint", Integer),
            ("varchar(50)", Text),
            ("nvarchar(max)", Text),
            ("text", Text),
            ("real", Float),
            ("float", Float),
            ("decimal(10,2)", Decimal),
            ("numeric", Decimal),
            ("money", Decimal),
            ("bit", Boolean),
            ("date", Datetime),
            ("datetime2", Datetime),
            ("time", Datetime),
            ("uniqueidentifier", Uuid),
            ("varbinary", Unknown),
        ];
        for (native, want) in cases {
            assert_eq!(normalize_mssql_type(native), want, "native {native}");
        }
    }

    #[test]
    fn normalize_mssql_type_is_case_insensitive() {
        assert_eq!(normalize_mssql_type("INT"), NormalizedType::Integer);
        assert_eq!(normalize_mssql_type("UNIQUEIDENTIFIER"), NormalizedType::Uuid);
    }
}
