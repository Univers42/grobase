//! The per-mount Redis pool: holds the auto-reconnecting `ConnectionManager`,
//! derives owner-scoped key prefixes, and dispatches single + batch operations.

use super::convert::build_key_prefix;
use super::query::{run_delete, run_get, run_insert, run_list, run_update, run_upsert};
use super::validate::validate_resource;
use super::SUPPORTED_OPS;
use async_trait::async_trait;
use data_plane_core::{
    BatchItemOutcome, BatchItemStatus, BatchSummary, DataOperation, DataOperationKind,
    DataPlaneError, DataPlaneResult, DataResult, EnginePool, RequestIdentity, TxBeginRequest,
    TxHandle,
};
use redis::aio::ConnectionManager;
use serde_json::Value;

pub struct RedisPool {
    pub(super) mount_id: String,
    pub(super) tenant_id: String,
    /// True for a SHARE_POOLS shared_rls pool serving many tenants on one redis:
    /// the single-owner guard is skipped (the per-request owner key-prefix —
    /// `<owner>:<resource>` derived from the identity — carries isolation). See
    /// `crate::pools_shared`.
    pub(super) shared_pool: bool,
    pub(super) manager: ConnectionManager,
    /// `Some("tenant_<id>")` for `schema_per_tenant` mounts: prepended to every
    /// key so a tenant's keyspace is fully partitioned. `None` (shared_rls /
    /// db_per_tenant) → no extra segment, the historical key shape.
    pub(super) namespace: Option<String>,
}

impl RedisPool {
    pub(super) fn owner(identity: &RequestIdentity) -> String {
        identity.owner_principal().to_string()
    }

    /// `<namespace>:<owner>:<resource>` for schema_per_tenant, else the
    /// historical `<owner>:<resource>`. The namespace segment is pre-sanitized
    /// to `[a-z0-9_]` by `safe_schema`, so it cannot break the `:`-delimited
    /// key envelope.
    fn key_prefix(&self, resource: &str, identity: &RequestIdentity) -> String {
        build_key_prefix(self.namespace.as_deref(), &Self::owner(identity), resource)
    }

    pub(super) fn id_from_filter_or_data(op: &DataOperation) -> DataPlaneResult<String> {
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
            batch: Some(BatchSummary {
                atomic: false,
                items: outcomes,
            }),
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
