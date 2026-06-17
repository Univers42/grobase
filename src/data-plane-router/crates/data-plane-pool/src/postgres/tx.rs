//! The pinned `PgTxHandle`, per-request RLS/search-path application, and the
//! operation dispatcher shared by the auto-commit and interactive-tx paths.

use super::adapter::PostgresPool;
use super::{convert, crud, query};
use async_trait::async_trait;
use data_plane_core::{
    BatchItemOutcome, BatchItemStatus, BatchSummary, DataOperation, DataOperationKind,
    DataPlaneError, DataPlaneResult, DataResult, RequestIdentity, TxHandle,
};
use deadpool_postgres::Object;
use tokio::sync::Mutex;
use tokio_postgres::GenericClient;

/// Pinned PostgreSQL transaction. Owns the checked-out connection for the
/// full life of the tx; releases it to the pool when dropped.
///
/// Concurrency: `tokio::sync::Mutex` serializes the calls so that two
/// concurrent `execute()` / `commit()` requests against the same `tx_id`
/// don't interleave on the wire (which would be a SQL-level corruption).
pub(super) struct PgTxHandle {
    pub(super) tx_id: String,
    pub(super) mount_id: String,
    /// Snapshot of the mount's `Isolation::owner_scoped()` at begin time —
    /// txn writes must scope exactly like single-op writes on this mount.
    pub(super) owner_scoped: bool,
    pub(super) client: Mutex<Object>,
}

#[async_trait]
impl TxHandle for PgTxHandle {
    fn tx_id(&self) -> &str {
        &self.tx_id
    }

    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let client = self.client.lock().await;
        // MutexGuard → Object → ClientWrapper → Client. Three derefs.
        dispatch_op(&***client, &operation, &identity, self.owner_scoped).await
    }

    async fn commit(&self) -> DataPlaneResult<()> {
        let client = self.client.lock().await;
        client
            .execute("COMMIT", &[])
            .await
            .map_err(|e| convert::backend(&e))?;
        Ok(())
    }

    async fn rollback(&self) -> DataPlaneResult<()> {
        let client = self.client.lock().await;
        // Best-effort: if the tx is already aborted, ROLLBACK is a no-op.
        let _ = client.execute("ROLLBACK", &[]).await;
        Ok(())
    }

    async fn prepare(&self) -> DataPlaneResult<()> {
        // 2PC (`PREPARE TRANSACTION`) is intentionally not exposed; the
        // capability descriptor declares `two_phase_commit: false`.
        Err(DataPlaneError::NotImplemented {
            feature: "postgres PREPARE TRANSACTION (2PC)".to_string(),
        })
    }
}

/// Set the RLS GUCs that the tenant identity needs. Used by both auto-commit
/// and multi-statement paths. `set_config(..., true)` scopes them to the
/// current transaction, which is exactly what we want.
pub(super) async fn apply_rls_context<C: GenericClient + Sync>(
    client: &C,
    identity: &RequestIdentity,
) -> DataPlaneResult<()> {
    let principal = PostgresPool::principal(identity).to_string();
    let tenant = identity.tenant_id.clone();
    // Build the claims object with serde_json so a `"` or `}` in the identity
    // cannot inject a chosen `sub` — which is the RLS principal that
    // `auth.current_user_id()` reads first. Never hand-format the security
    // principal. (Defense in depth; identity should also be validated upstream.)
    let claims = serde_json::json!({ "sub": &principal, "tenant_id": &tenant }).to_string();
    client
        .execute(
            "SELECT set_config('app.current_user_id', $1, true), \
                    set_config('app.current_tenant_id', $2, true), \
                    set_config('request.jwt.claims', $3, true)",
            &[&principal, &tenant, &claims],
        )
        .await
        .map_err(|e| convert::backend(&e))?;
    Ok(())
}

/// For `schema_per_tenant` mounts, pin the connection's `search_path` to the
/// tenant schema for the current transaction (`SET LOCAL`). No-op for shared /
/// db-per-tenant mounts. `public` is kept on the path so shared extensions and
/// types still resolve. The schema name is pre-sanitized to `[a-z0-9_]` by
/// [`DatabaseMount::tenant_schema`], so interpolating it here (SET cannot bind
/// parameters) carries no injection risk.
pub(super) async fn apply_search_path<C: GenericClient + Sync>(
    client: &C,
    schema: Option<&str>,
) -> DataPlaneResult<()> {
    let Some(schema) = schema else {
        return Ok(());
    };
    let sql = format!("SET LOCAL search_path TO {schema}, public");
    client
        .execute(sql.as_str(), &[])
        .await
        .map_err(|e| convert::backend(&e))?;
    Ok(())
}

/// The operation kinds the Postgres adapter dispatches. `dispatch_op` rejects
/// anything else; the capability descriptor (`EngineCapabilities::postgresql`)
/// and the honesty test both derive from this — the single source of truth.
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

pub(super) async fn dispatch_op<C: GenericClient + Sync>(
    client: &C,
    operation: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    if !SUPPORTED_OPS.contains(&operation.op) {
        return Err(DataPlaneError::NotImplemented {
            feature: format!("postgres operation {:?}", operation.op),
        });
    }
    match &operation.op {
        DataOperationKind::Batch => run_batch(client, operation, identity, owner_scoped).await,
        _ => dispatch_single(client, operation, identity, owner_scoped).await,
    }
}

/// Single (non-batch) operation dispatch — the arms `run_batch` loops over.
/// Exhaustive by enumeration (no wildcard): deleting a CRUD arm is a compile
/// error, so the match can't silently drift from SUPPORTED_OPS.
async fn dispatch_single<C: GenericClient + Sync>(
    client: &C,
    operation: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    match &operation.op {
        DataOperationKind::List => query::run_list(client, operation).await,
        DataOperationKind::Get => query::run_get(client, operation).await,
        DataOperationKind::Insert => {
            crud::run_insert(client, operation, identity, owner_scoped).await
        }
        DataOperationKind::Update => {
            crud::run_update(client, operation, identity, owner_scoped).await
        }
        DataOperationKind::Delete => {
            crud::run_delete(client, operation, identity, owner_scoped).await
        }
        DataOperationKind::Upsert => {
            crud::run_upsert(client, operation, identity, owner_scoped).await
        }
        DataOperationKind::Aggregate => query::run_aggregate(client, operation).await,
        DataOperationKind::Batch => Err(DataPlaneError::InvalidRequest {
            message: "nested batches are not allowed".to_string(),
        }),
    }
}

/// Atomic batch: the caller already wraps every `execute()` in a transaction
/// (and the tx path runs inside the caller's interactive transaction), so a
/// failed item simply propagates its error — the surrounding transaction is
/// never committed and nothing persists. Item errors carry the item index so
/// the 4xx envelope tells the caller exactly which sub-operation failed.
async fn run_batch<C: GenericClient + Sync>(
    client: &C,
    operation: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    let items = operation
        .batch_items()
        .map_err(|message| DataPlaneError::InvalidRequest { message })?;
    let mut outcomes = Vec::with_capacity(items.len());
    let mut total: u64 = 0;
    for (idx, item) in items.iter().enumerate() {
        let result = dispatch_single(client, item, identity, owner_scoped)
            .await
            .map_err(|e| DataPlaneError::prefix_message(&format!("batch item {idx}: "), e))?;
        total += result.affected_rows;
        outcomes.push(BatchItemOutcome {
            index: idx as u32,
            status: BatchItemStatus::Ok,
            affected_rows: result.affected_rows,
            error: None,
        });
    }
    Ok(DataResult {
        rows: vec![],
        affected_rows: total,
        next_cursor: None,
        batch: Some(BatchSummary {
            atomic: true,
            items: outcomes,
        }),
    })
}
