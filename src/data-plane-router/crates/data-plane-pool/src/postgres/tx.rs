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
    /// Snapshot of the owner-scope inputs at begin time — a txn's ops must scope
    /// exactly like single-op execs on this mount (see [`ScopeCtx`]).
    pub(super) isolation_owner_scoped: bool,
    pub(super) shared_resources: std::sync::Arc<[String]>,
    pub(super) admin_bypass: bool,
    pub(super) read_predicate: bool,
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
        let ctx = ScopeCtx {
            isolation_owner_scoped: self.isolation_owner_scoped,
            shared: &self.shared_resources,
            admin_bypass: self.admin_bypass,
            read_predicate: self.read_predicate,
        };
        // MutexGuard → Object → ClientWrapper → Client. Three derefs.
        dispatch_op(&***client, &operation, &identity, &ctx).await
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

/// Per-request owner-scope inputs threaded to the dispatcher, built once from the
/// pool's cached mount flags. Every field is OFF-by-default such that the
/// derivation collapses to today's behavior (byte-parity): an empty `shared` set,
/// `admin_bypass`/`read_predicate` both false → `derive_scope` returns
/// `(isolation_owner_scoped, isolation_owner_scoped)` and reads append no predicate.
pub(super) struct ScopeCtx<'a> {
    /// `mount.isolation().owner_scoped()` — false for `tenant_owned`.
    pub(super) isolation_owner_scoped: bool,
    /// F1: NAMED tables that skip owner-scoping. Empty unless the master is ON.
    pub(super) shared: &'a [String],
    /// F2: an admin identity's reads + filter-mutations skip the owner predicate.
    pub(super) admin_bypass: bool,
    /// Read-predicate master: gates predicate-based read owner-scoping on Postgres
    /// (OFF → reads append no `owner_id` predicate). Separate from F1 so an admin
    /// DB browser can edit (F1 + admin-bypass) without owner-scoping public reads.
    pub(super) read_predicate: bool,
}

/// Derive `(scoped, read_scoped)` for one operation's resource. `scoped` gates
/// INSERT/UPSERT owner stamping (false only for a NAMED shared table);
/// `read_scoped` additionally drops the owner predicate for an admin caller under
/// F2 (reads + filter-mutations). Pure → unit-tested without a client.
fn derive_scope(resource: &str, ctx: &ScopeCtx, is_admin: bool) -> (bool, bool) {
    let scoped = ctx.isolation_owner_scoped && !ctx.shared.iter().any(|t| t == resource);
    let read_scoped = scoped && !(ctx.admin_bypass && is_admin);
    (scoped, read_scoped)
}

pub(super) async fn dispatch_op<C: GenericClient + Sync>(
    client: &C,
    operation: &DataOperation,
    identity: &RequestIdentity,
    ctx: &ScopeCtx<'_>,
) -> DataPlaneResult<DataResult> {
    if !SUPPORTED_OPS.contains(&operation.op) {
        return Err(DataPlaneError::NotImplemented {
            feature: format!("postgres operation {:?}", operation.op),
        });
    }
    match &operation.op {
        DataOperationKind::Batch => run_batch(client, operation, identity, ctx).await,
        _ => dispatch_single(client, operation, identity, ctx).await,
    }
}

/// Single (non-batch) operation dispatch — the arms `run_batch` loops over.
/// Exhaustive by enumeration (no wildcard): deleting a CRUD arm is a compile
/// error, so the match can't silently drift from SUPPORTED_OPS. `scoped` gates
/// write owner-stamping; `read_owner_scoped` (F1-master-gated) gates the appended
/// read predicate — OFF → reads are byte-identical (RLS-GUC-scoped only).
async fn dispatch_single<C: GenericClient + Sync>(
    client: &C,
    operation: &DataOperation,
    identity: &RequestIdentity,
    ctx: &ScopeCtx<'_>,
) -> DataPlaneResult<DataResult> {
    let (scoped, read_scoped) = derive_scope(&operation.resource, ctx, identity.is_admin());
    let read_owner_scoped = ctx.read_predicate && read_scoped;
    match &operation.op {
        DataOperationKind::List => query::run_list(client, operation, identity, read_owner_scoped).await,
        DataOperationKind::Get => query::run_get(client, operation, identity, read_owner_scoped).await,
        DataOperationKind::Insert => crud::run_insert(client, operation, identity, scoped).await,
        DataOperationKind::Update => crud::run_update(client, operation, identity, read_scoped).await,
        DataOperationKind::Delete => crud::run_delete(client, operation, identity, read_scoped).await,
        DataOperationKind::Upsert => crud::run_upsert(client, operation, identity, scoped).await,
        DataOperationKind::Aggregate => {
            query::run_aggregate(client, operation, identity, read_owner_scoped).await
        }
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
    ctx: &ScopeCtx<'_>,
) -> DataPlaneResult<DataResult> {
    let items = operation
        .batch_items()
        .map_err(|message| DataPlaneError::InvalidRequest { message })?;
    let mut outcomes = Vec::with_capacity(items.len());
    let mut total: u64 = 0;
    for (idx, item) in items.iter().enumerate() {
        let result = dispatch_single(client, item, identity, ctx)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx<'a>(iso: bool, shared: &'a [String], admin_bypass: bool, pti: bool) -> ScopeCtx<'a> {
        ScopeCtx {
            isolation_owner_scoped: iso,
            shared,
            admin_bypass,
            read_predicate: pti,
        }
    }

    #[test]
    fn derive_scope_off_is_byte_parity() {
        // Flags OFF (empty shared set, no admin bypass) → (iso, iso) for ANY
        // caller, admin or not → byte-identical to before.
        let empty: Vec<String> = vec![];
        assert_eq!(
            derive_scope("Order", &ctx(true, &empty, false, false), false),
            (true, true)
        );
        assert_eq!(
            derive_scope("Order", &ctx(true, &empty, false, false), true),
            (true, true)
        );
        // tenant_owned (iso=false) → both false regardless of flags.
        assert_eq!(
            derive_scope("Order", &ctx(false, &empty, true, true), true),
            (false, false)
        );
    }

    #[test]
    fn derive_scope_shared_table_skips_owner() {
        let shared = vec!["Menu".to_string()];
        assert_eq!(
            derive_scope("Menu", &ctx(true, &shared, false, true), false),
            (false, false),
            "a NAMED shared catalog table is never owner-scoped"
        );
        assert_eq!(
            derive_scope("Order", &ctx(true, &shared, false, true), false),
            (true, true),
            "a non-shared table stays owner-scoped"
        );
    }

    #[test]
    fn derive_scope_admin_bypass_drops_read_scope_only() {
        let empty: Vec<String> = vec![];
        // F2 ON + admin → read_scoped false (read/update/delete cross-owner) but
        // scoped stays true (INSERT/UPSERT still stamp owner_id).
        assert_eq!(
            derive_scope("Order", &ctx(true, &empty, true, true), true),
            (true, false)
        );
        // F2 ON + non-admin → unchanged.
        assert_eq!(
            derive_scope("Order", &ctx(true, &empty, true, true), false),
            (true, true)
        );
        // F2 OFF + admin → unchanged (byte-parity).
        assert_eq!(
            derive_scope("Order", &ctx(true, &empty, false, true), true),
            (true, true)
        );
    }
}
