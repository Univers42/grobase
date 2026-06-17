//! HTTP passthrough engine adapter — R8.
//!
//! Mirrors the legacy `src/apps/query-router/src/engines/http.engine.ts`.
//! Treats an external REST endpoint as a "database": the mount's connection
//! string is a JSON `{baseUrl, headers?, routes?}` (or a bare http(s) URL)
//! and CRUD operations map to HTTP verbs.
//!
//! Tenant scope is propagated as an `X-Owner-Id` header derived from the
//! verified [`RequestIdentity`] so upstream services can apply their own
//! authorization without trusting the client.
//!
//! Isolation (gap G5): an HTTP mount has no schema/database/keyspace concept,
//! so [`data_plane_core::Isolation::scope`] returns
//! [`data_plane_core::ScopeDirective::None`] for it under EVERY strategy
//! (`shared_rls` / `schema_per_tenant` / `db_per_tenant`). This adapter
//! therefore applies no per-request scoping; per-tenant separation, if needed,
//! is an upstream concern keyed off the forwarded `X-Owner-Id`. Documented here
//! as an explicit no-op so the absence is intentional, not an oversight.
//!
//! Pattern stack:
//!   * Adapter (GoF)   — implements [`EngineAdapter`].
//!   * Object Pool     — `reqwest::Client` owns its own connection pool.
//!   * Strategy        — operation kind selects the HTTP verb + path shape.
//!
//! [`RequestIdentity`]: data_plane_core::RequestIdentity
//! [`EngineAdapter`]: data_plane_core::EngineAdapter

mod adapter;
mod convert;
mod pool;
mod query;
mod validate;

use data_plane_core::DataOperationKind;
use serde_json::{Map as JsonMap, Value};

pub use adapter::HttpEngineAdapter;
pub use validate::guard_and_resolve;

/// The operation kinds the HTTP adapter dispatches — the single source of truth
/// shared by `execute`'s gate, the capability descriptor, and the honesty test.
pub(crate) const SUPPORTED_OPS: &[DataOperationKind] = &[
    DataOperationKind::List,
    DataOperationKind::Get,
    DataOperationKind::Insert,
    DataOperationKind::Update,
    DataOperationKind::Delete,
    DataOperationKind::Upsert,
];

// Suppress unused-import warning if JsonMap ever stops being referenced
// (kept here for parity with other adapters and future use).
#[allow(dead_code)]
fn _json_map_assertion() -> JsonMap<String, Value> {
    JsonMap::new()
}

// ── unit tests ──────────────────────────────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::convert::shape_response;
    use super::query::{
        append_query, encode, extract_scalar, join_url, route_or_default, scalar_id_from_filter,
        scalar_id_from_filter_or_data,
    };
    use super::validate::{
        is_blocked_ip, is_http_url, parse_connection, validate_resource, HttpConnection,
    };
    use data_plane_core::{DataOperation, DataOperationKind};
    use serde_json::{json, Value};
    use std::collections::BTreeMap;

    #[test]
    fn ssrf_blocks_internal_and_metadata_ips() {
        for bad in [
            "127.0.0.1",
            "169.254.169.254", // cloud metadata
            "10.0.0.5",
            "192.168.1.1",
            "172.16.0.1",
            "100.64.0.1", // CGNAT
            "0.0.0.0",
            "::1",
            "fd00::1",          // IPv6 ULA
            "fe80::1",          // IPv6 link-local
            "::ffff:127.0.0.1", // IPv4-mapped loopback
        ] {
            assert!(is_blocked_ip(bad.parse().unwrap()), "{bad} must be blocked");
        }
        for ok in ["1.1.1.1", "8.8.8.8", "93.184.216.34"] {
            assert!(!is_blocked_ip(ok.parse().unwrap()), "{ok} must be allowed");
        }
    }

    #[test]
    fn parse_connection_accepts_json_object() {
        let raw = r#"{"baseUrl":"https://api.example.com","headers":{"X-Api":"k"}}"#;
        let parsed = parse_connection(raw).unwrap();
        assert_eq!(parsed.base_url, "https://api.example.com");
        assert!(parsed.headers.is_some());
    }

    #[test]
    fn parse_connection_accepts_bare_url() {
        let parsed = parse_connection("http://localhost:9000").unwrap();
        assert_eq!(parsed.base_url, "http://localhost:9000");
    }

    #[test]
    fn parse_connection_rejects_non_http() {
        assert!(parse_connection("file:///etc/passwd").is_err());
        assert!(parse_connection("not a url at all").is_err());
        assert!(parse_connection(r#"{"baseUrl":"ftp://foo"}"#).is_err());
    }

    #[test]
    fn validate_resource_rejects_funny_chars() {
        assert!(validate_resource("").is_err());
        assert!(validate_resource("a b").is_err());
        assert!(validate_resource("foo?bar").is_err());
        for ok in ["users", "v1/users", "items.json", "x_y-z"] {
            assert!(validate_resource(ok).is_ok(), "should accept {ok:?}");
        }
    }

    #[test]
    fn join_url_strips_trailing_slash_and_adds_leading() {
        assert_eq!(
            join_url("http://x.com/", "users").unwrap(),
            "http://x.com/users"
        );
        assert_eq!(
            join_url("http://x.com", "/users").unwrap(),
            "http://x.com/users"
        );
        assert_eq!(
            join_url("http://x.com/api/", "/v1/users").unwrap(),
            "http://x.com/api/v1/users"
        );
    }

    #[test]
    fn append_query_url_encodes_filter_values() {
        let op = DataOperation {
            op: DataOperationKind::List,
            resource: "users".into(),
            data: None,
            filter: Some(json!({"name": "needle&hay"})),
            sort: None,
            limit: Some(10),
            offset: Some(5),
            idempotency_key: None,
            expected_version: None,
            returning: None,
            aggregate: None,
            fields: None,
            search: None,
            vector: None,
        };
        let path = append_query("/users", &op);
        assert!(path.starts_with("/users?"));
        assert!(path.contains("name=needle%26hay"));
        assert!(path.contains("limit=10"));
        assert!(path.contains("offset=5"));
    }

    #[test]
    fn extract_scalar_handles_supported_kinds() {
        assert_eq!(
            extract_scalar(Some(&json!("hi")), "x").unwrap(),
            "hi".to_string()
        );
        assert_eq!(
            extract_scalar(Some(&json!(42)), "x").unwrap(),
            "42".to_string()
        );
        assert!(extract_scalar(None, "x").is_err());
        assert!(extract_scalar(Some(&json!([1, 2])), "x").is_err());
    }

    #[test]
    fn shape_response_handles_array_envelope_object() {
        let r = shape_response(json!([{"a":1}, {"a":2}]));
        assert_eq!(r.affected_rows, 2);
        let r = shape_response(json!({"data":[{"a":1}]}));
        assert_eq!(r.affected_rows, 1);
        let r = shape_response(json!({"id":"x"}));
        assert_eq!(r.affected_rows, 1);
        let r = shape_response(json!("string"));
        assert_eq!(r.affected_rows, 0);
    }

    #[test]
    fn route_override_takes_precedence() {
        let conn = HttpConnection {
            base_url: "http://x".into(),
            headers: None,
            routes: Some(BTreeMap::from([(
                "list".to_string(),
                "/custom/list".to_string(),
            )])),
        };
        let path = route_or_default(&conn, "list", || "/default".into());
        assert_eq!(path, "/custom/list");
        let path = route_or_default(&conn, "get", || "/default".into());
        assert_eq!(path, "/default");
    }

    // ── is_blocked_ip: exhaustive reserved-range coverage ────────────────────

    #[test]
    fn is_blocked_ip_blocks_every_reserved_v4_range() {
        for bad in [
            "127.0.0.1", // loopback
            "127.255.255.254",
            "10.0.0.1", // RFC-1918 /8
            "10.255.255.255",
            "172.16.0.1", // RFC-1918 /12
            "172.31.255.255",
            "192.168.0.1",     // RFC-1918 /16
            "169.254.0.1",     // link-local
            "169.254.169.254", // cloud metadata
            "255.255.255.255", // broadcast
            "0.0.0.0",         // unspecified
            "0.1.2.3",         // 0.0.0.0/8
            "192.0.2.1",       // documentation TEST-NET-1
            "198.51.100.1",    // TEST-NET-2
            "203.0.113.1",     // TEST-NET-3
            "100.64.0.1",      // CGNAT /10 low edge
            "100.127.255.255", // CGNAT /10 high edge
        ] {
            assert!(is_blocked_ip(bad.parse().unwrap()), "{bad} must be blocked");
        }
    }

    #[test]
    fn is_blocked_ip_blocks_reserved_v6_and_mapped() {
        for bad in [
            "::1",     // loopback
            "::",      // unspecified
            "ff02::1", // multicast
            "fc00::1", // ULA /7
            "fdff::1", // ULA /7
            "fe80::1", // link-local /10
            "febf::1",
            "::ffff:127.0.0.1",       // IPv4-mapped loopback
            "::ffff:10.0.0.1",        // IPv4-mapped private
            "::ffff:169.254.169.254", // IPv4-mapped metadata
        ] {
            assert!(is_blocked_ip(bad.parse().unwrap()), "{bad} must be blocked");
        }
    }

    #[test]
    fn is_blocked_ip_allows_public_addresses() {
        for ok in [
            "1.1.1.1",
            "8.8.8.8",
            "93.184.216.34",
            "100.63.255.255",       // just below CGNAT
            "100.128.0.0",          // just above CGNAT
            "172.15.255.255",       // just below RFC-1918 /12
            "172.32.0.0",           // just above RFC-1918 /12
            "2606:4700:4700::1111", // public IPv6 (Cloudflare)
        ] {
            assert!(!is_blocked_ip(ok.parse().unwrap()), "{ok} must be allowed");
        }
    }

    // ── is_http_url: scheme detection, case-insensitive ──────────────────────

    #[test]
    fn is_http_url_detects_http_and_https_any_case() {
        assert!(is_http_url("http://x"));
        assert!(is_http_url("https://x"));
        assert!(is_http_url("HTTP://X"));
        assert!(is_http_url("HtTpS://x"));
        assert!(!is_http_url("ftp://x"));
        assert!(!is_http_url("file:///etc"));
        assert!(!is_http_url("ws://x"));
        assert!(!is_http_url(""));
        assert!(!is_http_url("//x"));
        assert!(!is_http_url("httpx://x"));
    }

    // ── join_url: slash normalization edge cases ─────────────────────────────

    #[test]
    fn join_url_normalizes_slashes() {
        assert_eq!(join_url("http://x", "users").unwrap(), "http://x/users");
        assert_eq!(join_url("http://x/", "/users").unwrap(), "http://x/users");
        assert_eq!(join_url("http://x///", "users").unwrap(), "http://x/users");
        // empty path → single slash.
        assert_eq!(join_url("http://x", "").unwrap(), "http://x/");
        // path that is just "/" stays one slash.
        assert_eq!(join_url("http://x/", "/").unwrap(), "http://x/");
    }

    // ── encode: percent-encoding of reserved chars ───────────────────────────

    #[test]
    fn encode_percent_encodes_all_non_alphanumerics() {
        assert_eq!(encode("a b"), "a%20b");
        assert_eq!(encode("a&b=c"), "a%26b%3Dc");
        assert_eq!(encode("100%"), "100%25");
        assert_eq!(encode("plain123"), "plain123");
        assert_eq!(encode("a/b?c#d"), "a%2Fb%3Fc%23d");
        // unicode bytes get percent-encoded too.
        assert_eq!(encode("é"), "%C3%A9");
        assert_eq!(encode(""), "");
    }

    // ── validate_resource: charset boundaries ────────────────────────────────

    #[test]
    fn validate_resource_accepts_url_path_chars() {
        for ok in [
            "users",
            "v1/users",
            "items.json",
            "x_y-z",
            "a/b/c",
            &"x".repeat(128),
        ] {
            assert!(validate_resource(ok).is_ok(), "should accept {ok:?}");
        }
    }

    #[test]
    fn validate_resource_rejects_funny_and_overlong() {
        for bad in [
            "",
            "a b",
            "foo?bar",
            "a&b",
            "a#b",
            "a%b",
            "a:b",
            &"x".repeat(129),
        ] {
            assert!(validate_resource(bad).is_err(), "should reject {bad:?}");
        }
    }

    // ── extract_scalar: every supported + rejected kind ──────────────────────

    #[test]
    fn extract_scalar_supported_kinds_and_rejections() {
        assert_eq!(extract_scalar(Some(&json!("s")), "x").unwrap(), "s");
        assert_eq!(extract_scalar(Some(&json!("")), "x").unwrap(), "");
        assert_eq!(extract_scalar(Some(&json!(0)), "x").unwrap(), "0");
        assert_eq!(extract_scalar(Some(&json!(-7)), "x").unwrap(), "-7");
        assert_eq!(extract_scalar(Some(&json!(3.5)), "x").unwrap(), "3.5");
        assert_eq!(extract_scalar(Some(&json!(true)), "x").unwrap(), "true");
        assert_eq!(extract_scalar(Some(&json!(false)), "x").unwrap(), "false");
        // rejected: null, array, object, missing.
        for bad in [
            Some(&json!(null)),
            Some(&json!([1])),
            Some(&json!({ "k": 1 })),
            None,
        ] {
            assert!(extract_scalar(bad, "x").is_err(), "should reject {bad:?}");
        }
    }

    fn list_op(filter: Option<Value>, data: Option<Value>) -> DataOperation {
        DataOperation {
            op: DataOperationKind::Get,
            resource: "users".into(),
            data,
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
    fn scalar_id_from_filter_reads_filter_id_only() {
        let op = list_op(Some(json!({ "id": "f1" })), Some(json!({ "id": "d1" })));
        assert_eq!(scalar_id_from_filter(&op).unwrap(), "f1");
        // no filter id → error (does NOT fall back to data here).
        let op2 = list_op(None, Some(json!({ "id": "d1" })));
        assert!(scalar_id_from_filter(&op2).is_err());
    }

    #[test]
    fn scalar_id_from_filter_or_data_prefers_filter_then_data() {
        // filter wins when present
        let op = list_op(Some(json!({ "id": "f1" })), Some(json!({ "id": "d1" })));
        assert_eq!(scalar_id_from_filter_or_data(&op).unwrap(), "f1");
        // falls back to data when filter has no id
        let op2 = list_op(None, Some(json!({ "id": "d1" })));
        assert_eq!(scalar_id_from_filter_or_data(&op2).unwrap(), "d1");
        // neither → error
        let op3 = list_op(None, None);
        assert!(scalar_id_from_filter_or_data(&op3).is_err());
        // numeric id from data is stringified
        let op4 = list_op(None, Some(json!({ "id": 42 })));
        assert_eq!(scalar_id_from_filter_or_data(&op4).unwrap(), "42");
    }

    // ── append_query: null skipping, sort/limit/offset, separators ───────────

    #[test]
    fn append_query_no_params_returns_path_unchanged() {
        let op = list_op(None, None);
        assert_eq!(append_query("/users", &op), "/users");
        // a filter that is all-null also yields no params.
        let op2 = list_op(Some(json!({ "a": null })), None);
        assert_eq!(append_query("/users", &op2), "/users");
    }

    #[test]
    fn append_query_uses_ampersand_when_path_already_has_query() {
        let mut op = list_op(Some(json!({ "name": "x" })), None);
        op.limit = Some(5);
        let path = append_query("/users?page=2", &op);
        assert!(path.starts_with("/users?page=2&"), "{path}");
        assert!(path.contains("name=x"));
        assert!(path.contains("limit=5"));
    }

    #[test]
    fn append_query_encodes_non_string_filter_values() {
        let op = list_op(Some(json!({ "n": 7, "flag": true })), None);
        let path = append_query("/users", &op);
        assert!(path.contains("n=7"), "{path}");
        assert!(path.contains("flag=true"), "{path}");
    }

    #[test]
    fn append_query_serializes_sort_map() {
        let mut op = list_op(None, None);
        let mut sort = BTreeMap::new();
        sort.insert("name".to_string(), "asc".to_string());
        op.sort = Some(sort);
        let path = append_query("/users", &op);
        assert!(path.contains("sort="), "{path}");
    }

    // ── shape_response: array / {data} / object / scalar ─────────────────────

    #[test]
    fn shape_response_every_envelope_shape() {
        assert_eq!(
            shape_response(json!([{ "a": 1 }, { "a": 2 }])).affected_rows,
            2
        );
        assert_eq!(shape_response(json!([])).affected_rows, 0);
        assert_eq!(
            shape_response(json!({ "data": [{ "a": 1 }] })).affected_rows,
            1
        );
        assert_eq!(shape_response(json!({ "data": [] })).affected_rows, 0);
        assert_eq!(shape_response(json!({ "id": "x" })).affected_rows, 1);
        // non-array `data` is NOT unwrapped — the object is one row.
        assert_eq!(shape_response(json!({ "data": "scalar" })).affected_rows, 1);
        // scalars → empty.
        assert_eq!(shape_response(json!("s")).affected_rows, 0);
        assert_eq!(shape_response(json!(42)).affected_rows, 0);
        assert_eq!(shape_response(json!(null)).affected_rows, 0);
    }

    // ── route_or_default: override vs default closure ────────────────────────

    #[test]
    fn route_or_default_falls_back_when_no_routes() {
        let conn = HttpConnection {
            base_url: "http://x".into(),
            headers: None,
            routes: None,
        };
        assert_eq!(route_or_default(&conn, "list", || "/d".into()), "/d");
    }

    // ── parse_connection: more shapes ────────────────────────────────────────

    #[test]
    fn parse_connection_json_rejects_non_http_base_url() {
        assert!(parse_connection(r#"{"baseUrl":"ws://foo"}"#).is_err());
        assert!(parse_connection(r#"{"baseUrl":"/relative"}"#).is_err());
    }

    #[test]
    fn parse_connection_bare_https_url() {
        let p = parse_connection("https://api.example.com/v1").unwrap();
        assert_eq!(p.base_url, "https://api.example.com/v1");
        assert!(p.headers.is_none());
        assert!(p.routes.is_none());
    }

    #[test]
    fn parse_connection_json_with_routes() {
        let raw = r#"{"baseUrl":"https://x.com","routes":{"list":"/all"}}"#;
        let p = parse_connection(raw).unwrap();
        assert_eq!(
            p.routes.unwrap().get("list").map(String::as_str),
            Some("/all")
        );
    }
}
