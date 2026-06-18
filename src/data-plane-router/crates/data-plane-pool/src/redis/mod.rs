//! Redis engine adapter — R8.
//!
//! Mirrors the legacy `src/apps/query-router/src/engines/redis.engine.ts`:
//! each record is stored as a Hash at key `{owner}:{resource}:{id}`. The
//! `owner` segment is taken from the verified [`RequestIdentity`] (user_id,
//! fallback tenant_id), so a forged `id` cannot read into another tenant's
//! keyspace — tenant isolation lives in the key prefix itself.
//!
//! Pattern stack:
//!   * Adapter (GoF)   — implements [`EngineAdapter`].
//!   * Object Pool     — `redis::aio::ConnectionManager` is an Arc-cheap
//!     auto-reconnecting pool, kept per mount.
//!   * Strategy        — operation kind switches the executor branch.
//!
//! [`RequestIdentity`]: data_plane_core::RequestIdentity
//! [`EngineAdapter`]: data_plane_core::EngineAdapter

mod adapter;
mod convert;
mod pool;
mod query;
mod validate;

use data_plane_core::DataOperationKind;

pub use adapter::RedisEngineAdapter;

/// The operation kinds the Redis adapter dispatches — the single source of
/// truth shared by `execute`'s gate, the capability descriptor, and the
/// honesty test.
pub(crate) const SUPPORTED_OPS: &[DataOperationKind] = &[
    DataOperationKind::List,
    DataOperationKind::Get,
    DataOperationKind::Insert,
    DataOperationKind::Update,
    DataOperationKind::Delete,
    DataOperationKind::Upsert,
    DataOperationKind::Batch,
];

// ── unit tests ──────────────────────────────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::convert::{
        backend, build_key_prefix, generate_id, hash_to_row, resolve_namespace, split_id_data,
        value_to_hash_string,
    };
    use super::pool::RedisPool;
    use super::validate::{is_valid_segment, validate_id, validate_resource};
    use data_plane_core::{
        DataOperation, DataOperationKind, DataPlaneError, IdentitySource, RequestIdentity,
    };
    use serde_json::{json, Value};

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
    fn key_prefix_uses_user_id_when_present() {
        let id = identity_with(Some("u-1"));
        // shared_rls (namespace None) → historical <owner>:<resource> shape.
        assert_eq!(
            build_key_prefix(None, &RedisPool::owner(&id), "users"),
            "u-1:users"
        );
    }

    #[test]
    fn key_prefix_falls_back_to_tenant_id() {
        let id = identity_with(None);
        assert_eq!(
            build_key_prefix(None, &RedisPool::owner(&id), "users"),
            "t-1:users"
        );
    }

    #[test]
    fn key_prefix_prepends_namespace_for_schema_per_tenant() {
        let id = identity_with(Some("u-1"));
        // schema_per_tenant → <namespace>:<owner>:<resource>.
        assert_eq!(
            build_key_prefix(Some("tenant_t_1"), &RedisPool::owner(&id), "users"),
            "tenant_t_1:u-1:users"
        );
    }

    #[test]
    fn resolve_namespace_only_for_schema_per_tenant() {
        use data_plane_core::{CredentialRef, DatabaseMount, PoolPolicy};
        let mk = |iso: Option<&str>| DatabaseMount {
            id: "db1".into(),
            tenant_id: "t-1".into(),
            project_id: None,
            engine: "redis".into(),
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
        // schema_per_tenant derives `tenant_<id>_<hash8>` (collision-free); match
        // the human-readable prefix, not the hash-suffixed literal.
        let ns = resolve_namespace(&mk(Some("schema_per_tenant"))).unwrap();
        assert!(ns.starts_with("tenant_t_1_"), "{ns}");
    }

    #[test]
    fn validate_resource_rejects_injection() {
        for bad in ["", "users*", "users:", "users\nDEL", "a b", "x/y", "name?q"] {
            assert!(validate_resource(bad).is_err(), "should reject {bad:?}");
        }
        for good in ["users", "users-2024", "users:archive", "u_table"] {
            assert!(validate_resource(good).is_ok(), "should accept {good:?}");
        }
    }

    #[test]
    fn split_id_data_pulls_id_from_filter_first() {
        let op = DataOperation {
            op: DataOperationKind::Update,
            resource: "users".into(),
            data: Some(json!({"id": "data-id", "name": "x"})),
            filter: Some(json!({"id": "filter-id"})),
            sort: None,
            limit: None,
            offset: None,
            idempotency_key: None,
            expected_version: None,
            returning: None,
            aggregate: None,
            fields: None,
            search: None,
            vector: None,
        };
        let (id, rest) = split_id_data(&op, false).unwrap();
        assert_eq!(id, "filter-id");
        assert!(!rest.contains_key("id"));
        assert_eq!(rest.get("name"), Some(&json!("x")));
    }

    #[test]
    fn split_id_data_generates_when_allowed() {
        let op = DataOperation {
            op: DataOperationKind::Insert,
            resource: "users".into(),
            data: Some(json!({"name": "x"})),
            filter: None,
            sort: None,
            limit: None,
            offset: None,
            idempotency_key: None,
            expected_version: None,
            returning: None,
            aggregate: None,
            fields: None,
            search: None,
            vector: None,
        };
        let (id, _) = split_id_data(&op, true).unwrap();
        assert!(!id.is_empty());
    }

    #[test]
    fn split_id_data_rejects_missing_when_not_allowed() {
        let op = DataOperation {
            op: DataOperationKind::Update,
            resource: "users".into(),
            data: Some(json!({"name": "x"})),
            filter: None,
            sort: None,
            limit: None,
            offset: None,
            idempotency_key: None,
            expected_version: None,
            returning: None,
            aggregate: None,
            fields: None,
            search: None,
            vector: None,
        };
        assert!(split_id_data(&op, false).is_err());
    }

    #[test]
    fn value_to_hash_string_passes_through_strings() {
        assert_eq!(value_to_hash_string(&json!("hi")), "hi");
        assert_eq!(value_to_hash_string(&json!(42)), "42");
        assert_eq!(value_to_hash_string(&json!({"k":1})), r#"{"k":1}"#);
    }

    #[test]
    fn hash_to_row_parses_json_values_back() {
        let mut h = std::collections::HashMap::new();
        h.insert("name".to_string(), "Alice".to_string());
        h.insert("scores".to_string(), "[1,2,3]".to_string());
        let row = hash_to_row("id-1".to_string(), h);
        let Value::Object(m) = row else { panic!() };
        assert_eq!(m.get("id"), Some(&json!("id-1")));
        // Plain string stays string (parsing fails — JSON parse of "Alice" errors).
        assert_eq!(m.get("name"), Some(&json!("Alice")));
        // Numeric array parses back.
        assert_eq!(m.get("scores"), Some(&json!([1, 2, 3])));
    }

    // ── is_valid_segment: the shared resource/id character rule ───────────────

    #[test]
    fn is_valid_segment_enforces_charset_and_length() {
        assert!(is_valid_segment("abc", 10, b""));
        assert!(is_valid_segment("ABC_123", 10, b""));
        assert!(!is_valid_segment("", 10, b""), "empty rejected");
        assert!(!is_valid_segment("abc", 2, b""), "over max_len rejected");
        assert!(is_valid_segment("abc", 3, b""), "exactly max_len ok");
        // extra-allowed bytes broaden the set.
        assert!(
            !is_valid_segment("a-b", 10, b""),
            "hyphen not allowed by default"
        );
        assert!(
            is_valid_segment("a-b", 10, b"-"),
            "hyphen allowed when in extra"
        );
        assert!(is_valid_segment("a:b", 10, b":"));
        // disallowed everywhere: spaces, control, punctuation.
        assert!(!is_valid_segment("a b", 10, b"-:"));
        assert!(!is_valid_segment("a*b", 10, b"-:"));
        assert!(!is_valid_segment("a\nb", 10, b"-:"));
    }

    // ── validate_resource: envelope-safety (`:` edges and doubles) ────────────

    #[test]
    fn validate_resource_accepts_namespaced_and_dashed() {
        for ok in [
            "users",
            "users:archive",
            "a:b:c",
            "users-2024",
            "u_table",
            &"x".repeat(128),
        ] {
            assert!(validate_resource(ok).is_ok(), "should accept {ok:?}");
        }
    }

    #[test]
    fn validate_resource_rejects_colon_edges_and_doubles() {
        for bad in [
            "",
            ":users",
            "users:",
            "a::b",
            ":",
            "::",
            "users*",
            "users\nDEL",
            "a b",
            "x/y",
            "name?q",
            &"x".repeat(129),
        ] {
            assert!(validate_resource(bad).is_err(), "should reject {bad:?}");
        }
    }

    // ── validate_id: wider charset (includes `_`), length 256 ─────────────────

    #[test]
    fn validate_id_charset_and_bounds() {
        for ok in ["abc", "a-b_c:d", "ID-2024_07:01", &"i".repeat(256)] {
            assert!(validate_id(ok).is_ok(), "should accept {ok:?}");
        }
        for bad in ["", "a b", "a/b", "a*b", "a.b", &"i".repeat(257)] {
            assert!(validate_id(bad).is_err(), "should reject {bad:?}");
        }
    }

    // ── build_key_prefix: with/without namespace ─────────────────────────────

    #[test]
    fn build_key_prefix_with_and_without_namespace() {
        assert_eq!(build_key_prefix(None, "owner", "res"), "owner:res");
        assert_eq!(build_key_prefix(Some("ns"), "owner", "res"), "ns:owner:res");
        // Empty owner/resource is the caller's contract; the helper just joins.
        assert_eq!(build_key_prefix(None, "", "res"), ":res");
    }

    // ── backend: always Backend with the redis prefix ────────────────────────

    #[test]
    fn backend_wraps_message_as_backend() {
        for msg in ["connection refused", "WRONGTYPE Operation", "MOVED 3999"] {
            let e = backend(msg);
            match e {
                DataPlaneError::Backend { message } => {
                    assert!(message.starts_with("redis backend: "), "{message}");
                    assert!(message.contains(msg), "{message}");
                }
                other => panic!("expected Backend, got {other:?}"),
            }
        }
    }

    // ── value_to_hash_string: scalars + composites ───────────────────────────

    #[test]
    fn value_to_hash_string_covers_every_value_type() {
        assert_eq!(value_to_hash_string(&json!("hi")), "hi");
        assert_eq!(value_to_hash_string(&json!("")), "");
        assert_eq!(value_to_hash_string(&json!(42)), "42");
        assert_eq!(value_to_hash_string(&json!(-1)), "-1");
        assert_eq!(value_to_hash_string(&json!(3.5)), "3.5");
        assert_eq!(value_to_hash_string(&json!(true)), "true");
        assert_eq!(value_to_hash_string(&Value::Null), "null");
        assert_eq!(value_to_hash_string(&json!([1, 2])), "[1,2]");
        assert_eq!(value_to_hash_string(&json!({ "k": 1 })), r#"{"k":1}"#);
        // A string that LOOKS like JSON passes through verbatim (not re-encoded).
        assert_eq!(value_to_hash_string(&json!("[1,2]")), "[1,2]");
    }

    // ── hash_to_row: parse-back vs. plain-string fallback ────────────────────

    #[test]
    fn hash_to_row_keeps_id_and_handles_empty_hash() {
        let row = hash_to_row("only-id".to_string(), std::collections::HashMap::new());
        let Value::Object(m) = row else { panic!() };
        assert_eq!(m.len(), 1);
        assert_eq!(m.get("id"), Some(&json!("only-id")));
    }

    #[test]
    fn hash_to_row_parses_objects_numbers_bools_keeps_strings() {
        let mut h = std::collections::HashMap::new();
        h.insert("obj".to_string(), r#"{"x":1}"#.to_string());
        h.insert("num".to_string(), "42".to_string());
        h.insert("flag".to_string(), "true".to_string());
        h.insert("plain".to_string(), "not json".to_string());
        h.insert("nullish".to_string(), "null".to_string());
        let Value::Object(m) = hash_to_row("id".to_string(), h) else {
            panic!()
        };
        assert_eq!(m.get("obj"), Some(&json!({ "x": 1 })));
        assert_eq!(m.get("num"), Some(&json!(42)));
        assert_eq!(m.get("flag"), Some(&json!(true)));
        assert_eq!(m.get("plain"), Some(&json!("not json")));
        assert_eq!(m.get("nullish"), Some(&Value::Null));
    }

    #[test]
    fn value_to_hash_string_then_back_round_trips_via_hash_to_row() {
        // A composite written then read reconstructs the same JSON.
        for v in [
            json!({ "a": [1, 2] }),
            json!([true, null]),
            json!(7),
            json!("x"),
        ] {
            let stored = value_to_hash_string(&v);
            let mut h = std::collections::HashMap::new();
            h.insert("f".to_string(), stored);
            let Value::Object(m) = hash_to_row("id".to_string(), h) else {
                panic!()
            };
            assert_eq!(m.get("f"), Some(&v), "round-trip {v}");
        }
    }

    // ── generate_id: shape + uniqueness ──────────────────────────────────────

    #[test]
    fn generate_id_has_ms_dash_hex_shape_and_validates() {
        let id = generate_id();
        let (ms, hex) = id.split_once('-').expect("id has a '-' separator");
        assert!(ms.chars().all(|c| c.is_ascii_digit()), "ms part: {ms}");
        assert_eq!(hex.len(), 8, "8 hex chars: {hex}");
        assert!(
            hex.chars().all(|c| c.is_ascii_hexdigit()),
            "hex part: {hex}"
        );
        // A generated id always passes validate_id (the envelope contract).
        assert!(validate_id(&id).is_ok(), "generated id must be valid: {id}");
    }

    #[test]
    fn generate_id_is_distinct_across_calls() {
        let a = generate_id();
        let b = generate_id();
        let c = generate_id();
        // The xorshift advances per call, so consecutive ids differ.
        assert!(a != b || b != c, "ids should not all be identical");
    }

    // ── split_id_data: number/bool ids, reserved-strip, errors ───────────────

    fn op_with(data: Value, filter: Option<Value>) -> DataOperation {
        DataOperation {
            op: DataOperationKind::Update,
            resource: "users".into(),
            data: Some(data),
            filter,
            sort: None,
            limit: None,
            offset: None,
            idempotency_key: None,
            expected_version: None,
            returning: None,
            aggregate: None,
            fields: None,
            search: None,
            vector: None,
        }
    }

    #[test]
    fn split_id_data_stringifies_number_and_bool_ids() {
        let (id, _) = split_id_data(&op_with(json!({ "id": 123, "n": 1 }), None), false).unwrap();
        assert_eq!(id, "123");
        let (id, _) = split_id_data(&op_with(json!({ "id": true }), None), false).unwrap();
        assert_eq!(id, "true");
    }

    #[test]
    fn split_id_data_rejects_array_id() {
        let err = split_id_data(&op_with(json!({ "id": [1, 2] }), None), false).unwrap_err();
        assert!(
            matches!(err, DataPlaneError::InvalidRequest { .. }),
            "{err:?}"
        );
    }

    #[test]
    fn split_id_data_rejects_non_object_data() {
        let mut op = op_with(json!("not an object"), None);
        op.data = Some(json!([1, 2, 3]));
        assert!(split_id_data(&op, false).is_err());
    }

    #[test]
    fn split_id_data_validates_the_extracted_id() {
        // An id with a forbidden char (space) is rejected by validate_id.
        let err = split_id_data(&op_with(json!({ "id": "bad id" }), None), false).unwrap_err();
        assert!(
            matches!(err, DataPlaneError::InvalidIdentifier { .. }),
            "{err:?}"
        );
    }

    #[test]
    fn split_id_data_removes_id_from_remaining_fields() {
        let (_, rest) =
            split_id_data(&op_with(json!({ "id": "x", "a": 1, "b": 2 }), None), false).unwrap();
        assert!(!rest.contains_key("id"));
        assert_eq!(rest.len(), 2);
    }
}
