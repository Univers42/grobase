use crate::{
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult, DatabaseMount,
    EngineCapabilities, RequestIdentity, SchemaDdlRequest, SchemaDdlResult, SchemaDescriptor,
};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[async_trait]
pub trait EngineAdapter: Send + Sync {
    fn engine(&self) -> &str;
    fn capabilities(&self) -> EngineCapabilities;
    /// The operation kinds this adapter actually dispatches — the single source
    /// of truth. `dispatch_op` rejects anything not in this set, and the
    /// capability-honesty test asserts the descriptor's `supports_op` agrees
    /// with it, so a descriptor cannot advertise an op the adapter doesn't
    /// serve. Adding an op means: implement the dispatch arm, list it here, and
    /// flip the matching capability flag — the gate keeps the three in sync.
    fn supported_ops(&self) -> &'static [DataOperationKind];
    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>>;
    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth>;
}

/// Admin-scope raw-statement request. The route handler validates that the
/// caller has the `service_role` role (or `admin` in scopes) before dispatch
/// — engines TRUST the route-level gate and execute the statement verbatim.
/// Use for DDL, ALTER, index management, aggregations, anything outside the
/// safe CRUD surface.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RawStatement {
    pub statement: String,
    #[serde(default)]
    pub params: Vec<Value>,
    /// When true the engine returns `rows`; when false it returns just
    /// `affected_rows`. Engines that always return rows ignore this flag.
    #[serde(default)]
    pub expect_rows: bool,
}

#[async_trait]
pub trait EnginePool: Send + Sync {
    fn mount_id(&self) -> &str;
    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult>;
    async fn begin(&self, request: crate::TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>>;
    async fn close(&self) -> DataPlaneResult<()>;

    /// Execute an arbitrary engine-native statement (raw SQL for relational
    /// engines, raw command for KV/document engines). Default returns
    /// NotImplemented so engines without a native raw surface opt out
    /// explicitly. The route-level handler enforces admin authorisation.
    async fn execute_raw(
        &self,
        statement: RawStatement,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let _ = (statement, identity);
        Err(DataPlaneError::NotImplemented {
            feature: format!("raw statement execution on {}", self.mount_id()),
        })
    }

    /// Engine-agnostic schema introspection (M22). Returns every table /
    /// collection visible to this mount (scoped exactly like the request
    /// path — schema_per_tenant mounts only see their tenant schema) with
    /// normalized column types, PK/FK metadata and enum values. Default
    /// returns NotImplemented so engines without an introspection surface
    /// (redis, http) opt out explicitly; the route gates on the
    /// `introspect` capability flag before ever reaching this.
    async fn describe_schema(
        &self,
        identity: RequestIdentity,
    ) -> DataPlaneResult<SchemaDescriptor> {
        let _ = identity;
        Err(DataPlaneError::NotImplemented {
            feature: format!("schema introspection on {}", self.mount_id()),
        })
    }

    /// Apply ONE engine-agnostic schema-DDL operation (M22 step 2): add /
    /// drop / retype a column, create / drop a table. Engines lower the
    /// request through pure, identifier-validated builders (never raw client
    /// SQL). Single-op by contract — MySQL DDL self-commits, so a batch here
    /// would fake atomicity. Default returns NotImplemented so engines
    /// without a DDL surface (redis, http) opt out explicitly; the route
    /// gates on the `schema_ddl` capability flag before ever reaching this.
    async fn apply_schema_ddl(
        &self,
        ddl: SchemaDdlRequest,
        identity: RequestIdentity,
    ) -> DataPlaneResult<SchemaDdlResult> {
        let _ = (ddl, identity);
        Err(DataPlaneError::NotImplemented {
            feature: format!("schema DDL on {}", self.mount_id()),
        })
    }

    /// Apply a named migration as an atomic batch. Runs every statement
    /// inside a single transaction, then writes a marker row into a
    /// `_baas_migrations(name, applied_at)` table on the tenant DB so the
    /// same name is skipped on re-application.
    ///
    /// Engines override this only if they support multi-statement tx + a
    /// way to track applied marker names. Default returns NotImplemented.
    async fn apply_migration(
        &self,
        request: MigrationRequest,
        identity: RequestIdentity,
    ) -> DataPlaneResult<MigrationResult> {
        let _ = (request, identity);
        Err(DataPlaneError::NotImplemented {
            feature: format!("apply_migration on {}", self.mount_id()),
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MigrationRequest {
    pub name: String,
    pub statements: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MigrationResult {
    pub name: String,
    pub status: MigrationStatus,
    pub statements_run: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MigrationStatus {
    Applied,
    Skipped,
}

#[async_trait]
pub trait TxHandle: Send + Sync {
    fn tx_id(&self) -> &str;
    fn mount_id(&self) -> &str;
    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult>;
    async fn commit(&self) -> DataPlaneResult<()>;
    async fn rollback(&self) -> DataPlaneResult<()>;
    async fn prepare(&self) -> DataPlaneResult<()>;
}

#[async_trait]
pub trait PoolRegistry: Send + Sync {
    async fn get_or_create(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>>;
    async fn release_idle(&self) -> DataPlaneResult<()>;
    async fn close_mount(&self, mount_id: &str) -> DataPlaneResult<()>;
    async fn stats(&self) -> DataPlaneResult<Vec<PoolStats>>;

    /// Pin the pool identified by `pool_key` (see [`DatabaseMount::pool_key`])
    /// against idle reaping / LRU eviction while a transaction derived from it
    /// is in flight — the registry must never close a pool out from under an
    /// open tx. Balanced by [`PoolRegistry::unpin_tx`]. Default no-op for
    /// registries without a bounded cache.
    async fn pin_tx(&self, pool_key: &str) {
        let _ = pool_key;
    }

    /// Release a pin taken by [`PoolRegistry::pin_tx`]. Default no-op.
    async fn unpin_tx(&self, pool_key: &str) {
        let _ = pool_key;
    }

    /// Drain (close + drop) the pool identified by `pool_key` so the next
    /// request rebuilds it with a freshly-resolved credential — the rotation
    /// hook for gap G8. Because `pool_key` embeds `credential_ref.version` (see
    /// [`DatabaseMount::pool_key`]), draining the OLD version's key leaves a
    /// newer version's pool untouched. A pool with an in-flight transaction
    /// (`tx_pins > 0`) is left in place (the idle reaper retires it once the tx
    /// finishes) so we never close a connection out from under an open tx.
    /// Default no-op for registries without a bounded cache.
    async fn drain_pool_key(&self, pool_key: &str) -> DataPlaneResult<()> {
        let _ = pool_key;
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EngineHealth {
    pub engine: String,
    pub mount_id: String,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PoolStats {
    pub mount_id: String,
    pub engine: String,
    pub active_connections: u32,
    pub idle_connections: u32,
    pub waiting_requests: u32,
}
