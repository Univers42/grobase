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

use crate::resolver::MountResolver;
use async_trait::async_trait;
use data_plane_core::{
    BatchItemOutcome, BatchItemStatus, BatchSummary, DataOperation, DataOperationKind,
    DataPlaneError, DataPlaneResult, DataResult, DatabaseMount,
    EngineAdapter, EngineCapabilities, EngineHealth, EnginePool, RequestIdentity,
    TxBeginRequest, TxHandle,
};
use redis::aio::ConnectionManager;
use redis::{AsyncCommands, Client};
use serde_json::{Map as JsonMap, Value};
use std::sync::Arc;

/// Same character set as the TS adapter's `RESOURCE_REGEX`:
/// `[A-Za-z0-9_:-]{1,128}`. Rejects keys that could break the
/// `{owner}:{resource}:{id}` envelope.
fn is_valid_segment(s: &str, max_len: usize, allow_extra: &[u8]) -> bool {
    if s.is_empty() || s.len() > max_len {
        return false;
    }
    s.bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || allow_extra.contains(&b))
}

fn validate_resource(name: &str) -> DataPlaneResult<()> {
    if !is_valid_segment(name, 128, b"-:") {
        return Err(DataPlaneError::InvalidIdentifier {
            value: name.to_string(),
        });
    }
    // Reject leading/trailing/consecutive `:` — they would corrupt the
    // `{owner}:{resource}:{id}` envelope. The `:` separator is allowed for
    // namespaced resources like `users:archive` but never at the edges.
    if name.starts_with(':') || name.ends_with(':') || name.contains("::") {
        return Err(DataPlaneError::InvalidIdentifier {
            value: name.to_string(),
        });
    }
    Ok(())
}

fn validate_id(id: &str) -> DataPlaneResult<()> {
    if !is_valid_segment(id, 256, b"-_:") {
        return Err(DataPlaneError::InvalidIdentifier {
            value: id.to_string(),
        });
    }
    Ok(())
}

pub struct RedisEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl RedisEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

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

#[async_trait]
impl EngineAdapter for RedisEngineAdapter {
    fn engine(&self) -> &str {
        "redis"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::redis()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        // Phase B: refuse the redis `rediss://…#insecure` cert-skip under max.
        crate::tls::reject_insecure_tls(&dsn, crate::tls::max_security(), &["#insecure"])?;
        let client = Client::open(dsn.as_str()).map_err(|e| DataPlaneError::Backend {
            message: format!("invalid redis URL: {e}"),
        })?;
        let manager =
            ConnectionManager::new(client)
                .await
                .map_err(|e| DataPlaneError::Backend {
                    message: format!("redis connection manager init failed: {e}"),
                })?;
        // schema_per_tenant: a per-tenant namespace segment prepended to every
        // key (`<namespace>:<owner>:<resource>:<id>`). Derived from the mount's
        // tenant_id (identity-independent) so resolved once here; `None` for
        // shared_rls / db_per_tenant → the historical `<owner>:<resource>:<id>`
        // envelope, byte-identical to before G5.
        let namespace = resolve_namespace(&mount);
        let shared_pool = crate::pools_shared(&mount);
        Ok(Box::new(RedisPool {
            mount_id: mount.id,
            tenant_id: mount.tenant_id,
            shared_pool,
            manager,
            namespace,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth::unknown("redis", pool.mount_id()))
    }
}

pub struct RedisPool {
    mount_id: String,
    tenant_id: String,
    /// True for a SHARE_POOLS shared_rls pool serving many tenants on one redis:
    /// the single-owner guard is skipped (the per-request owner key-prefix —
    /// `<owner>:<resource>` derived from the identity — carries isolation). See
    /// `crate::pools_shared`.
    shared_pool: bool,
    manager: ConnectionManager,
    /// `Some("tenant_<id>")` for `schema_per_tenant` mounts: prepended to every
    /// key so a tenant's keyspace is fully partitioned. `None` (shared_rls /
    /// db_per_tenant) → no extra segment, the historical key shape.
    namespace: Option<String>,
}

impl RedisPool {
    fn owner(identity: &RequestIdentity) -> String {
        identity.owner_principal().to_string()
    }

    /// `<namespace>:<owner>:<resource>` for schema_per_tenant, else the
    /// historical `<owner>:<resource>`. The namespace segment is pre-sanitized
    /// to `[a-z0-9_]` by `safe_schema`, so it cannot break the `:`-delimited
    /// key envelope.
    fn key_prefix(&self, resource: &str, identity: &RequestIdentity) -> String {
        build_key_prefix(self.namespace.as_deref(), &Self::owner(identity), resource)
    }

    fn id_from_filter_or_data(op: &DataOperation) -> DataPlaneResult<String> {
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
        match from_filter.or(from_data) {
            Some(Value::String(s)) => Ok(s.clone()),
            Some(Value::Number(n)) => Ok(n.to_string()),
            Some(Value::Bool(b)) => Ok(b.to_string()),
            _ => Err(DataPlaneError::InvalidRequest {
                message: "redis op requires filter.id or data.id (string/number/bool)".to_string(),
            }),
        }
    }

    /// Single (non-batch) operation dispatch — derives the key prefix from
    /// the operation's own `resource`, so batch items can span resources.
    /// Exhaustive by enumeration so the match can't drift from SUPPORTED_OPS.
    async fn dispatch_single(
        &self,
        operation: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        validate_resource(&operation.resource)?;
        let mut conn = self.manager.clone();
        let prefix = self.key_prefix(&operation.resource, identity);
        match operation.op {
            DataOperationKind::List => run_list(&mut conn, &prefix, operation).await,
            DataOperationKind::Get => run_get(&mut conn, &prefix, operation).await,
            DataOperationKind::Insert => run_insert(&mut conn, &prefix, operation).await,
            DataOperationKind::Update => run_update(&mut conn, &prefix, operation).await,
            DataOperationKind::Delete => run_delete(&mut conn, &prefix, operation).await,
            DataOperationKind::Upsert => run_upsert(&mut conn, &prefix, operation).await,
            DataOperationKind::Batch => Err(DataPlaneError::InvalidRequest {
                message: "nested batches are not allowed".to_string(),
            }),
            DataOperationKind::Aggregate => Err(DataPlaneError::NotImplemented {
                feature: "redis aggregate operation (not implemented)".to_string(),
            }),
        }
    }

    /// Ordered, non-atomic batch: redis has no rollback (MULTI/EXEC queues
    /// commands but cannot undo executed ones), so items run in order and the
    /// first failure stops execution — earlier items stay applied, and the
    /// summary reports ok / error / skipped per item.
    async fn run_batch(
        &self,
        operation: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let items = operation
            .batch_items()
            .map_err(|message| DataPlaneError::InvalidRequest { message })?;
        let mut outcomes = Vec::with_capacity(items.len());
        let mut total: u64 = 0;
        let mut failed = false;
        for (idx, item) in items.iter().enumerate() {
            if failed {
                outcomes.push(BatchItemOutcome {
                    index: idx as u32,
                    status: BatchItemStatus::Skipped,
                    affected_rows: 0,
                    error: None,
                });
                continue;
            }
            match self.dispatch_single(item, identity).await {
                Ok(result) => {
                    total += result.affected_rows;
                    outcomes.push(BatchItemOutcome {
                        index: idx as u32,
                        status: BatchItemStatus::Ok,
                        affected_rows: result.affected_rows,
                        error: None,
                    });
                }
                Err(e) => {
                    failed = true;
                    outcomes.push(BatchItemOutcome {
                        index: idx as u32,
                        status: BatchItemStatus::Error,
                        affected_rows: 0,
                        error: Some(e.to_string()),
                    });
                }
            }
        }
        Ok(DataResult {
            rows: vec![],
            affected_rows: total,
            next_cursor: None,
            batch: Some(BatchSummary { atomic: false, items: outcomes }),
        })
    }
}

#[async_trait]
impl EnginePool for RedisPool {
    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        // SHARE_POOLS shared_rls pool: multi-tenant by design, no single owner to
        // assert; the per-request owner key-prefix carries isolation.
        if !self.shared_pool && identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match pool tenant".into(),
            });
        }
        validate_resource(&operation.resource)?;

        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("redis operation {:?}", operation.op),
            });
        }
        match operation.op {
            // Ordered, NON-atomic (no rollback in redis — MULTI/EXEC queues
            // but cannot undo): items run in order, first failure stops.
            DataOperationKind::Batch => self.run_batch(&operation, &identity).await,
            _ => self.dispatch_single(&operation, &identity).await,
        }
    }

    async fn begin(&self, _request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        Err(DataPlaneError::NotImplemented {
            feature: "redis multi-statement transactions (MULTI/EXEC not yet exposed)".to_string(),
        })
    }

    async fn close(&self) -> DataPlaneResult<()> {
        // ConnectionManager auto-closes on drop; no explicit handshake.
        Ok(())
    }
}

// ── operations ──────────────────────────────────────────────────────────────

async fn run_list(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let limit = op.limit.unwrap_or(100).min(500) as usize;
    let offset = op.offset.unwrap_or(0) as usize;
    let pattern = format!("{prefix}:*");

    // SCAN with MATCH avoids blocking the server unlike KEYS.
    let mut keys: Vec<String> = Vec::new();
    let mut iter = conn.scan_match::<_, String>(&pattern).await.map_err(backend)?;
    while let Some(k) = futures::StreamExt::next(&mut iter).await {
        keys.push(k);
        if keys.len() > limit + offset {
            break;
        }
    }
    drop(iter);
    keys.sort();
    let slice = keys
        .into_iter()
        .skip(offset)
        .take(limit)
        .collect::<Vec<_>>();
    if slice.is_empty() {
        return Ok(DataResult::new(vec![], 0));
    }

    let mut rows: Vec<Value> = Vec::with_capacity(slice.len());
    let prefix_with_sep = format!("{prefix}:");
    for k in &slice {
        let hash: std::collections::HashMap<String, String> =
            conn.hgetall(k).await.map_err(backend)?;
        if hash.is_empty() {
            continue;
        }
        let id = k.strip_prefix(&prefix_with_sep).unwrap_or(k).to_string();
        rows.push(hash_to_row(id, hash));
    }
    let affected = rows.len() as u64;
    Ok(DataResult::new(rows, affected))
}

async fn run_get(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let id = RedisPool::id_from_filter_or_data(op)?;
    validate_id(&id)?;
    let key = format!("{prefix}:{id}");
    let hash: std::collections::HashMap<String, String> =
        conn.hgetall(&key).await.map_err(backend)?;
    if hash.is_empty() {
        return Ok(DataResult::new(vec![], 0));
    }
    Ok(DataResult::new(vec![hash_to_row(id, hash)], 1))
}

async fn run_insert(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let (id, mut data) = split_id_data(op, /*allow_generate=*/ true)?;
    let key = format!("{prefix}:{id}");
    let exists: bool = conn.exists(&key).await.map_err(backend)?;
    if exists {
        return Err(DataPlaneError::Backend {
            message: format!("redis key already exists: {key}"),
        });
    }
    write_hash(conn, &key, &data).await?;
    data.insert("id".to_string(), Value::String(id));
    Ok(DataResult::new(vec![Value::Object(data)], 1))
}

async fn run_update(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let (id, mut data) = split_id_data(op, /*allow_generate=*/ false)?;
    let key = format!("{prefix}:{id}");
    let exists: bool = conn.exists(&key).await.map_err(backend)?;
    if !exists {
        return Ok(DataResult::new(vec![], 0));
    }
    write_hash(conn, &key, &data).await?;
    data.insert("id".to_string(), Value::String(id));
    Ok(DataResult::new(vec![Value::Object(data)], 1))
}

async fn run_delete(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let id = RedisPool::id_from_filter_or_data(op)?;
    validate_id(&id)?;
    let key = format!("{prefix}:{id}");
    let removed: u64 = conn.del(&key).await.map_err(backend)?;
    Ok(DataResult::new(vec![], removed))
}

async fn run_upsert(
    conn: &mut ConnectionManager,
    prefix: &str,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let (id, mut data) = split_id_data(op, /*allow_generate=*/ true)?;
    let key = format!("{prefix}:{id}");
    write_hash(conn, &key, &data).await?;
    data.insert("id".to_string(), Value::String(id));
    Ok(DataResult::new(vec![Value::Object(data)], 1))
}

// ── helpers ─────────────────────────────────────────────────────────────────

/// The key prefix, optionally namespaced. Pure (no I/O, no `self`) so the
/// envelope shape is unit-testable without a live Redis connection.
fn build_key_prefix(namespace: Option<&str>, owner: &str, resource: &str) -> String {
    match namespace {
        Some(ns) => format!("{ns}:{owner}:{resource}"),
        None => format!("{owner}:{resource}"),
    }
}

fn backend<E: std::fmt::Display>(e: E) -> DataPlaneError {
    DataPlaneError::Backend {
        message: format!("redis backend: {e}"),
    }
}

/// Per-tenant key-prefix segment for a `schema_per_tenant` Redis mount —
/// delegates to the single source of truth, [`DatabaseMount::resolve_namespace`].
// ponytail: thin wrapper kept so call sites read `resolve_namespace(&mount)`;
// inline + delete in a follow-up.
fn resolve_namespace(mount: &DatabaseMount) -> Option<String> {
    mount.resolve_namespace()
}

/// Split `op.data` into `(id, remaining_fields)`. If `allow_generate` is true
/// and no id is provided, generates one ({ms}-{random}).
fn split_id_data(
    op: &DataOperation,
    allow_generate: bool,
) -> DataPlaneResult<(String, JsonMap<String, Value>)> {
    let Some(Value::Object(map)) = op.data.as_ref() else {
        return Err(DataPlaneError::InvalidRequest {
            message: "redis op requires data as a JSON object".to_string(),
        });
    };
    let mut rest = map.clone();
    let id_value = op
        .filter
        .as_ref()
        .and_then(|v| v.as_object())
        .and_then(|m| m.get("id"))
        .cloned()
        .or_else(|| rest.remove("id"));
    let id = match id_value {
        Some(Value::String(s)) => s,
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(_) => {
            return Err(DataPlaneError::InvalidRequest {
                message: "redis id must be a string/number/bool".to_string(),
            });
        }
        None if allow_generate => generate_id(),
        None => {
            return Err(DataPlaneError::InvalidRequest {
                message: "redis update requires filter.id or data.id".to_string(),
            });
        }
    };
    validate_id(&id)?;
    rest.remove("id");
    Ok((id, rest))
}

fn generate_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    // Plain counter is fine — the key is then namespaced under owner+resource
    // so cross-mount collisions are impossible.
    format!("{ms}-{:08x}", fastrand_u32())
}

fn fastrand_u32() -> u32 {
    use std::cell::Cell;
    use std::time::{SystemTime, UNIX_EPOCH};
    // Tiny xorshift seeded from nanoseconds — not crypto, just enough for ids.
    thread_local! {
        static STATE: Cell<u32> = const { Cell::new(0) };
    }
    STATE.with(|s| {
        let mut x = s.get();
        if x == 0 {
            x = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.subsec_nanos())
                .unwrap_or(1)
                | 1;
        }
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        s.set(x);
        x
    })
}

async fn write_hash(
    conn: &mut ConnectionManager,
    key: &str,
    data: &JsonMap<String, Value>,
) -> DataPlaneResult<()> {
    if data.is_empty() {
        return Ok(());
    }
    let pairs: Vec<(String, String)> = data
        .iter()
        .map(|(k, v)| (k.clone(), value_to_hash_string(v)))
        .collect();
    // hset_multiple expects Vec<(K, V)> for the field/value pairs.
    let _: () = conn.hset_multiple(key, &pairs).await.map_err(backend)?;
    Ok(())
}

fn value_to_hash_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

fn hash_to_row(id: String, hash: std::collections::HashMap<String, String>) -> Value {
    let mut row = JsonMap::with_capacity(hash.len() + 1);
    row.insert("id".to_string(), Value::String(id));
    for (k, v) in hash {
        let parsed = serde_json::from_str(&v).unwrap_or(Value::String(v));
        row.insert(k, parsed);
    }
    Value::Object(row)
}

// ── unit tests ──────────────────────────────────────────────────────────────
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
}
