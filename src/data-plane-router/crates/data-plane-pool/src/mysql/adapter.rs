//! EngineAdapter for MySQL/MariaDB: pool construction + the operation-dispatch
//! shared by the auto-commit and transaction paths.

use super::pool::MysqlPool;
use super::query::{
    run_aggregate, run_delete, run_get, run_insert, run_list, run_update, run_upsert,
};
use super::*;

/// Adapter that knows how to construct [`MysqlPool`] instances from a
/// [`DatabaseMount`]. Held as `Arc<dyn EngineAdapter>` inside the registry.
///
/// MariaDB speaks the same wire protocol and is served by the SAME dispatch
/// (mysql_async connects to either) — so the adapter is parameterized by
/// `engine_name`. The registry routes a mount to this adapter by matching
/// `mount.engine == self.engine()`, so one code path serves both engines while
/// each keeps its own engine id + capability descriptor (honesty preserved).
pub struct MysqlEngineAdapter {
    resolver: Arc<dyn MountResolver>,
    engine_name: &'static str,
}

impl MysqlEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self {
            resolver,
            engine_name: "mysql",
        }
    }

    /// Build the adapter under a specific engine id (`"mysql"` or `"mariadb"`).
    /// The dispatch and pool are identical; only `engine()` + `capabilities()`
    /// differ.
    #[must_use]
    pub fn with_engine_name(resolver: Arc<dyn MountResolver>, engine_name: &'static str) -> Self {
        Self {
            resolver,
            engine_name,
        }
    }
}

/// The operation kinds the MySQL adapter dispatches — the single source of
/// truth shared by both dispatch paths' gates (tx and non-tx), the capability
/// descriptor, and the honesty test.
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

/// Per-table isolation master flag (`DATA_PLANE_PER_TABLE_ISOLATION`). OFF by
/// default → the shared set is forced empty in `open_pool`, so every table stays
/// owner-scoped (byte-parity). Only a NAMED table on an opted-in mount can skip
/// owner-scoping.
fn per_table_isolation_enabled() -> bool {
    matches!(
        std::env::var("DATA_PLANE_PER_TABLE_ISOLATION").as_deref(),
        Ok("1" | "true" | "TRUE" | "on" | "ON" | "yes")
    )
}

/// Admin owner-scope bypass master flag (`DATA_PLANE_ADMIN_BYPASS`, F2). OFF by
/// default → an admin identity is owner-scoped exactly like any caller
/// (byte-parity). ON → an [`RequestIdentity::is_admin`] caller's reads and
/// filter-based mutations (update/delete) skip the `owner_id` predicate so an
/// admin sees/operates across owners; admin INSERTs still stamp `owner_id` (the
/// row keeps a defined owner).
fn admin_bypass_enabled() -> bool {
    matches!(
        std::env::var("DATA_PLANE_ADMIN_BYPASS").as_deref(),
        Ok("1" | "true" | "TRUE" | "on" | "ON" | "yes")
    )
}

/// Single (non-batch) operation dispatch shared by the auto-commit and tx
/// paths — the arms `run_batch` loops over. Exhaustive by enumeration so the
/// match can't silently drift from SUPPORTED_OPS. `scoped` is derived from THIS
/// operation's resource: false only for a NAMED shared table, true otherwise.
pub(super) async fn dispatch_single(
    q: &mut impl Queryable,
    operation: &DataOperation,
    identity: &RequestIdentity,
    shared: &[String],
) -> DataPlaneResult<DataResult> {
    let scoped = !shared.iter().any(|t| t == &operation.resource);
    // F2 admin bypass: an admin's reads + filter-based mutations skip the owner
    // predicate (read across owners). INSERT/UPSERT keep `scoped` so an admin's
    // new rows still stamp `owner_id`. OFF by default → read_scoped == scoped
    // (byte-parity).
    let read_scoped = scoped && !(admin_bypass_enabled() && identity.is_admin());
    match operation.op {
        DataOperationKind::List => run_list(q, operation, identity, read_scoped).await,
        DataOperationKind::Get => run_get(q, operation, identity, read_scoped).await,
        DataOperationKind::Insert => run_insert(q, operation, identity, scoped).await,
        DataOperationKind::Update => run_update(q, operation, identity, read_scoped).await,
        DataOperationKind::Delete => run_delete(q, operation, identity, read_scoped).await,
        DataOperationKind::Upsert => run_upsert(q, operation, identity, scoped).await,
        DataOperationKind::Aggregate => run_aggregate(q, operation, identity, read_scoped).await,
        DataOperationKind::Batch => Err(DataPlaneError::InvalidRequest {
            message: "nested batches are not allowed".to_string(),
        }),
    }
}

/// Atomic batch: both call sites run inside a transaction (per-request or
/// interactive), so the first failed item propagates its error and the
/// surrounding transaction is rolled back — nothing persists.
pub(super) async fn run_batch(
    q: &mut impl Queryable,
    operation: &DataOperation,
    identity: &RequestIdentity,
    shared: &[String],
) -> DataPlaneResult<DataResult> {
    let items = operation
        .batch_items()
        .map_err(|message| DataPlaneError::InvalidRequest { message })?;
    let mut outcomes = Vec::with_capacity(items.len());
    let mut total: u64 = 0;
    for (idx, item) in items.iter().enumerate() {
        let result = dispatch_single(q, item, identity, shared)
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

#[async_trait]
impl EngineAdapter for MysqlEngineAdapter {
    fn engine(&self) -> &str {
        self.engine_name
    }

    fn capabilities(&self) -> EngineCapabilities {
        if self.engine_name == "mariadb" {
            EngineCapabilities::mariadb()
        } else {
            EngineCapabilities::mysql()
        }
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    // ponytail: linear pool-construction sequence (isolation guard → DSN →
    //   constraints → namespace) — one straight-line setup, no branch to factor.
    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        // tenant_owned (no per-row owner scoping) is implemented for
        // PostgreSQL only so far — fail CLOSED here rather than silently
        // owner-scoping a mount that promised not to (wrong rows beat
        // surprising rows, but a clear error beats both).
        if !mount.isolation().owner_scoped() {
            return Err(DataPlaneError::NotImplemented {
                feature: "tenant_owned isolation on this engine (PostgreSQL only for now)"
                    .to_string(),
            });
        }
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        let base_opts = Opts::from_url(&dsn).map_err(|e| DataPlaneError::Backend {
            message: format!("invalid mysql URL: {e}"),
        })?;

        let constraints = PoolConstraints::new(
            mount.pool_policy.min as usize,
            mount.pool_policy.max.max(1) as usize,
        )
        .ok_or_else(|| DataPlaneError::Backend {
            message: format!(
                "invalid mysql pool constraints min={} max={}",
                mount.pool_policy.min, mount.pool_policy.max
            ),
        })?;
        let pool_opts = PoolOpts::new().with_constraints(constraints);

        let opts: Opts = OptsBuilder::from_opts(base_opts)
            .pool_opts(pool_opts)
            .into();
        let pool = Pool::new(opts);

        // schema_per_tenant: the engine-neutral scope directive selects a
        // per-tenant database (`USE tenant_<id>`) on every checkout. The
        // namespace is derived from the mount's tenant_id (identity-
        // independent) so it's resolved once here; `None` for shared_rls /
        // db_per_tenant → no `USE`, byte-identical to before G5.
        let namespace = resolve_namespace(&mount);
        let shared_pool = crate::pools_shared(&mount);
        // F1 per-table isolation: the set of NAMED tables that skip owner-scoping.
        // Forced empty unless the master flag is ON → byte-parity by construction.
        let shared_resources: std::sync::Arc<[String]> = if per_table_isolation_enabled() {
            mount.shared_resources().into()
        } else {
            Vec::new().into()
        };

        Ok(Box::new(MysqlPool {
            mount_id: mount.id,
            tenant_id: mount.tenant_id,
            shared_pool,
            pool,
            namespace,
            shared_resources,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth::unknown("mysql", pool.mount_id()))
    }
}

/// Per-tenant database name for a `schema_per_tenant` MySQL mount — delegates to
/// the single source of truth, [`DatabaseMount::resolve_namespace`].
// ponytail: thin wrapper kept so call sites read `resolve_namespace(&mount)`;
// inline + delete in a follow-up.
pub(super) fn resolve_namespace(mount: &DatabaseMount) -> Option<String> {
    mount.resolve_namespace()
}
