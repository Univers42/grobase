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

use crate::resolver::MountResolver;
use async_trait::async_trait;
use data_plane_core::{
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult, DatabaseMount,
    EngineAdapter, EngineCapabilities, EngineHealth, EnginePool, RequestIdentity, TxBeginRequest,
    TxHandle,
};
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
use reqwest::{header, Client, Method, StatusCode};
use serde::Deserialize;
use serde_json::{Map as JsonMap, Value};
use std::collections::BTreeMap;
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_RESOURCE_LEN: usize = 128;

#[derive(Debug, Deserialize, Default)]
struct HttpConnection {
    #[serde(rename = "baseUrl")]
    base_url: String,
    #[serde(default)]
    headers: Option<BTreeMap<String, String>>,
    #[serde(default)]
    routes: Option<BTreeMap<String, String>>,
}

pub struct HttpEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl HttpEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

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

#[async_trait]
impl EngineAdapter for HttpEngineAdapter {
    fn engine(&self) -> &str {
        "http"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::http()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        let conn = parse_connection(&dsn)?;
        // SSRF guard: resolve + validate the base-URL host, reject internal /
        // link-local / cloud-metadata targets, and PIN the client to the
        // validated public IP(s) so a later DNS rebind can't redirect requests
        // inward. `DATA_PLANE_HTTP_ALLOW_INTERNAL=1` skips it (trusted dev mocks).
        let pinned = guard_and_resolve(&conn.base_url).await?;
        let mut builder = Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .user_agent("mini-baas-data-plane-router/0.1");
        if let Some((host, addrs)) = pinned {
            for addr in addrs {
                builder = builder.resolve(&host, addr);
            }
        }
        let client = builder.build().map_err(|e| DataPlaneError::Backend {
            message: format!("reqwest client init failed: {e}"),
        })?;
        let shared_pool = crate::pools_shared(&mount);
        Ok(Box::new(HttpPool {
            mount_id: mount.id,
            tenant_id: mount.tenant_id,
            shared_pool,
            client,
            conn,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth {
            engine: "http".to_string(),
            mount_id: pool.mount_id().to_string(),
            status: "unknown".to_string(),
        })
    }
}

pub struct HttpPool {
    mount_id: String,
    tenant_id: String,
    /// True for a SHARE_POOLS shared_rls pool: the single-owner guard is skipped
    /// (the per-request `x-owner-id` header carries isolation to the upstream).
    /// See `crate::pools_shared`.
    shared_pool: bool,
    client: Client,
    conn: HttpConnection,
}

#[async_trait]
impl EnginePool for HttpPool {
    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        // SHARE_POOLS shared_rls pool: multi-tenant by design, no single owner to
        // assert; the per-request `x-owner-id` header carries isolation upstream.
        if !self.shared_pool && identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match pool tenant".into(),
            });
        }
        validate_resource(&operation.resource)?;
        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("http operation {:?}", operation.op),
            });
        }

        let (method, path, body) = match operation.op {
            DataOperationKind::List => {
                let path = route_or_default(&self.conn, "list", || format!("/{}", operation.resource));
                let path = append_query(&path, &operation);
                (Method::GET, path, None)
            }
            DataOperationKind::Get => {
                let id = scalar_id_from_filter(&operation)?;
                let path = route_or_default(&self.conn, "get", || {
                    format!("/{}/{}", operation.resource, encode(&id))
                });
                (Method::GET, path, None)
            }
            DataOperationKind::Insert => {
                let path = route_or_default(&self.conn, "insert", || format!("/{}", operation.resource));
                (Method::POST, path, operation.data.clone())
            }
            DataOperationKind::Update => {
                let id = scalar_id_from_filter(&operation)?;
                let path = route_or_default(&self.conn, "update", || {
                    format!("/{}/{}", operation.resource, encode(&id))
                });
                (Method::PATCH, path, operation.data.clone())
            }
            DataOperationKind::Delete => {
                let id = scalar_id_from_filter(&operation)?;
                let path = route_or_default(&self.conn, "delete", || {
                    format!("/{}/{}", operation.resource, encode(&id))
                });
                (Method::DELETE, path, None)
            }
            DataOperationKind::Upsert => {
                let id = scalar_id_from_filter_or_data(&operation)?;
                let path = route_or_default(&self.conn, "upsert", || {
                    format!("/{}/{}", operation.resource, encode(&id))
                });
                (Method::PUT, path, operation.data.clone())
            }
            DataOperationKind::Batch | DataOperationKind::Aggregate => {
                return Err(DataPlaneError::NotImplemented {
                    feature: "http batch/aggregate operation (not implemented)".to_string(),
                });
            }
        };

        let url = join_url(&self.conn.base_url, &path)?;
        self.dispatch(method, &url, body.as_ref(), &identity, &operation)
            .await
    }

    async fn begin(&self, _request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        Err(DataPlaneError::NotImplemented {
            feature: "http transactions are upstream-defined and not exposed by this adapter"
                .to_string(),
        })
    }

    async fn close(&self) -> DataPlaneResult<()> {
        Ok(())
    }
}

impl HttpPool {
    async fn dispatch(
        &self,
        method: Method,
        url: &str,
        body: Option<&Value>,
        identity: &RequestIdentity,
        operation: &DataOperation,
    ) -> DataPlaneResult<DataResult> {
        let mut req = self
            .client
            .request(method.clone(), url)
            .header(header::ACCEPT, "application/json");

        if let Some(extra) = &self.conn.headers {
            for (k, v) in extra {
                req = req.header(k.as_str(), v.as_str());
            }
        }
        let owner = identity
            .user_id
            .clone()
            .unwrap_or_else(|| identity.tenant_id.clone());
        req = req.header("x-owner-id", owner);
        if let Some(idem) = &operation.idempotency_key {
            req = req.header("idempotency-key", idem.as_str());
        }
        if let Some(b) = body {
            req = req
                .header(header::CONTENT_TYPE, "application/json")
                .body(serde_json::to_vec(b).unwrap_or_default());
        }

        let resp = req.send().await.map_err(|e| DataPlaneError::Backend {
            message: format!("http upstream {method} {url}: {e}"),
        })?;

        let status = resp.status();
        if status == StatusCode::NO_CONTENT {
            return Ok(DataResult {
                rows: vec![],
                affected_rows: 0,
                next_cursor: None,
                batch: None,
            });
        }
        if status.is_server_error() {
            return Err(DataPlaneError::Backend {
                message: format!("http upstream {method} {url} returned {status}"),
            });
        }
        if status.is_client_error() {
            return Err(DataPlaneError::Backend {
                message: format!("http upstream {method} {url} returned {status}"),
            });
        }

        let text = resp.text().await.unwrap_or_default();
        if text.is_empty() {
            return Ok(DataResult {
                rows: vec![],
                affected_rows: 0,
                next_cursor: None,
                batch: None,
            });
        }
        let parsed: Value = serde_json::from_str(&text).unwrap_or(Value::String(text));
        Ok(shape_response(parsed))
    }
}

// ── helpers ─────────────────────────────────────────────────────────────────

fn validate_resource(resource: &str) -> DataPlaneResult<()> {
    if resource.is_empty() || resource.len() > MAX_RESOURCE_LEN {
        return Err(DataPlaneError::InvalidIdentifier {
            value: resource.to_string(),
        });
    }
    for b in resource.bytes() {
        if !(b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.' | b'/')) {
            return Err(DataPlaneError::InvalidIdentifier {
                value: resource.to_string(),
            });
        }
    }
    Ok(())
}

fn parse_connection(raw: &str) -> DataPlaneResult<HttpConnection> {
    // Try JSON first.
    if let Ok(parsed) = serde_json::from_str::<HttpConnection>(raw) {
        if !is_http_url(&parsed.base_url) {
            return Err(DataPlaneError::Backend {
                message: "http baseUrl must be a fully qualified http(s) URL".to_string(),
            });
        }
        return Ok(parsed);
    }
    // Bare URL shorthand.
    if is_http_url(raw) {
        return Ok(HttpConnection {
            base_url: raw.to_string(),
            headers: None,
            routes: None,
        });
    }
    Err(DataPlaneError::Backend {
        message: "http connection_string must be JSON { baseUrl, ... } or a bare http(s) URL"
            .to_string(),
    })
}

fn is_http_url(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://")
}

/// SSRF classifier: `true` for any address an outbound HTTP mount must NOT reach
/// — loopback, RFC-1918 private, link-local (incl. 169.254.169.254 cloud
/// metadata), CGNAT, unspecified/broadcast/documentation, IPv6 ULA + link-local,
/// and IPv4-mapped forms of all the above.
fn is_blocked_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_unspecified()
                || v4.is_documentation()
                || v4.octets()[0] == 0
                || (v4.octets()[0] == 100 && (v4.octets()[1] & 0xc0) == 64) // 100.64/10 CGNAT
        }
        IpAddr::V6(v6) => {
            if let Some(mapped) = v6.to_ipv4_mapped() {
                return is_blocked_ip(IpAddr::V4(mapped));
            }
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || (v6.segments()[0] & 0xfe00) == 0xfc00 // fc00::/7 unique-local
                || (v6.segments()[0] & 0xffc0) == 0xfe80 // fe80::/10 link-local
        }
    }
}

fn ssrf_blocked(host: &str) -> DataPlaneError {
    DataPlaneError::Backend {
        message: format!(
            "http mount blocked: '{host}' resolves to an internal/reserved address (SSRF guard). \
             Set DATA_PLANE_HTTP_ALLOW_INTERNAL=1 only for trusted dev mocks."
        ),
    }
}

/// Validate an http mount's base URL against the SSRF guard and return the host
/// and its validated socket addresses to PIN (so a later DNS rebind cannot point
/// the client inward). `Ok(None)` when the dev escape is set (no check, no pin).
pub async fn guard_and_resolve(base_url: &str) -> DataPlaneResult<Option<(String, Vec<SocketAddr>)>> {
    if std::env::var("DATA_PLANE_HTTP_ALLOW_INTERNAL").ok().as_deref() == Some("1") {
        return Ok(None);
    }
    let url = reqwest::Url::parse(base_url)
        .map_err(|e| DataPlaneError::Backend { message: format!("http baseUrl parse: {e}") })?;
    let host = url
        .host_str()
        .ok_or_else(|| DataPlaneError::Backend {
            message: "http baseUrl has no host".to_string(),
        })?
        .to_string();
    let lower = host.to_ascii_lowercase();
    if lower == "localhost"
        || lower == "metadata"
        || lower == "instance-data"
        || lower.ends_with(".local")
        || lower.ends_with(".internal")
    {
        return Err(ssrf_blocked(&host));
    }
    let port = url.port_or_known_default().unwrap_or(80);
    // Literal IP host → classify directly (no DNS).
    if let Ok(ip) = host.parse::<IpAddr>() {
        if is_blocked_ip(ip) {
            return Err(ssrf_blocked(&host));
        }
        return Ok(Some((host, vec![SocketAddr::new(ip, port)])));
    }
    // Hostname → resolve off the async runtime, validate EVERY A/AAAA record.
    let h = host.clone();
    let addrs: Vec<SocketAddr> = tokio::task::spawn_blocking(move || {
        (h.as_str(), port).to_socket_addrs().map(|it| it.collect::<Vec<_>>())
    })
    .await
    .map_err(|e| DataPlaneError::Backend { message: format!("ssrf resolve join: {e}") })?
    .map_err(|e| DataPlaneError::Backend {
        message: format!("http host '{host}' did not resolve: {e}"),
    })?;
    if addrs.is_empty() {
        return Err(DataPlaneError::Backend {
            message: format!("http host '{host}' did not resolve"),
        });
    }
    for sa in &addrs {
        if is_blocked_ip(sa.ip()) {
            return Err(ssrf_blocked(&host));
        }
    }
    Ok(Some((host, addrs)))
}

fn join_url(base: &str, path: &str) -> DataPlaneResult<String> {
    let clean_base = base.trim_end_matches('/');
    let clean_path = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    };
    Ok(format!("{clean_base}{clean_path}"))
}

fn encode(s: &str) -> String {
    utf8_percent_encode(s, NON_ALPHANUMERIC).to_string()
}

fn route_or_default<F: FnOnce() -> String>(
    conn: &HttpConnection,
    op_name: &str,
    default_path: F,
) -> String {
    conn.routes
        .as_ref()
        .and_then(|m| m.get(op_name))
        .cloned()
        .unwrap_or_else(default_path)
}

fn scalar_id_from_filter(op: &DataOperation) -> DataPlaneResult<String> {
    let id = op
        .filter
        .as_ref()
        .and_then(|v| v.as_object())
        .and_then(|m| m.get("id"));
    extract_scalar(id, "filter.id")
}

fn scalar_id_from_filter_or_data(op: &DataOperation) -> DataPlaneResult<String> {
    let from_filter = op
        .filter
        .as_ref()
        .and_then(|v| v.as_object())
        .and_then(|m| m.get("id"));
    let from_data = op
        .data
        .as_ref()
        .and_then(|v| v.as_object())
        .and_then(|m| m.get("id"));
    extract_scalar(from_filter.or(from_data), "filter.id or data.id")
}

fn extract_scalar(value: Option<&Value>, label: &str) -> DataPlaneResult<String> {
    match value {
        Some(Value::String(s)) => Ok(s.clone()),
        Some(Value::Number(n)) => Ok(n.to_string()),
        Some(Value::Bool(b)) => Ok(b.to_string()),
        _ => Err(DataPlaneError::InvalidRequest {
            message: format!("http op requires {label} as a string/number/bool"),
        }),
    }
}

fn append_query(path: &str, op: &DataOperation) -> String {
    let mut params: Vec<(String, String)> = Vec::new();
    if let Some(Value::Object(map)) = op.filter.as_ref() {
        for (k, v) in map {
            if v.is_null() {
                continue;
            }
            let value_str = match v {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            params.push((k.clone(), value_str));
        }
    }
    if let Some(sort) = op.sort.as_ref() {
        params.push((
            "sort".to_string(),
            serde_json::to_string(sort).unwrap_or_default(),
        ));
    }
    if let Some(l) = op.limit {
        params.push(("limit".to_string(), l.to_string()));
    }
    if let Some(o) = op.offset {
        params.push(("offset".to_string(), o.to_string()));
    }
    if params.is_empty() {
        return path.to_string();
    }
    let qs: Vec<String> = params
        .iter()
        .map(|(k, v)| format!("{}={}", encode(k), encode(v)))
        .collect();
    let sep = if path.contains('?') { '&' } else { '?' };
    format!("{path}{sep}{}", qs.join("&"))
}

fn shape_response(parsed: Value) -> DataResult {
    // Match the TS adapter: array → rows; { data: [...] } → rows; object → 1
    // row; everything else → empty.
    match parsed {
        Value::Array(arr) => {
            let count = arr.len() as u64;
            DataResult {
                rows: arr,
                affected_rows: count,
                next_cursor: None,
                batch: None,
            }
        }
        Value::Object(mut obj) => {
            if let Some(Value::Array(arr)) = obj.remove("data") {
                let count = arr.len() as u64;
                return DataResult {
                    rows: arr,
                    affected_rows: count,
                    next_cursor: None,
                    batch: None,
                };
            }
            // Re-wrap (we consumed `data` if it existed).
            DataResult {
                rows: vec![Value::Object(obj)],
                affected_rows: 1,
                next_cursor: None,
                batch: None,
            }
        }
        _ => DataResult {
            rows: vec![],
            affected_rows: 0,
            next_cursor: None,
            batch: None,
        },
    }
}

// Suppress unused-import warning if JsonMap ever stops being referenced
// (kept here for parity with other adapters and future use).
#[allow(dead_code)]
fn _json_map_assertion() -> JsonMap<String, Value> {
    JsonMap::new()
}

// ── unit tests ──────────────────────────────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
            "fd00::1",  // IPv6 ULA
            "fe80::1",  // IPv6 link-local
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
}
