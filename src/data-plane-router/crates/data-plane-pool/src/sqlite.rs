//! SQLite engine adapter (R-sqlite, Phase 3b).
//!
//! Embedded, file-per-mount engine on `rusqlite` (sync) driven through
//! `deadpool-sqlite`'s `interact()`, which runs each closure on a blocking
//! thread so the async runtime is never stalled. WAL is enabled at pool open
//! (1 writer + N concurrent readers) and `busy_timeout` smooths writer
//! contention. The DSN is a file path (`sqlite:///var/lib/mini-baas/<ref>.db`),
//! so a `db_per_tenant` mount is a distinct file; `shared_rls` mounts owner-scope
//! every read/write via an `owner_id` predicate exactly like the MySQL adapter
//! (SQLite has no RLS), and writes are owner-stamped so a forged body cannot
//! cross tenants.
//!
//! Honest descriptor (`EngineCapabilities::sqlite`): CRUD + upsert + ATOMIC
//! batch + aggregate + introspection. `transactions:false` — a connection-pinned
//! cross-request TxHandle is disproportionate under the `interact` model, so
//! `begin()` returns NotImplemented; a single batch is still atomic (one tx
//! inside one closure).

use crate::resolver::MountResolver;
use async_trait::async_trait;
use data_plane_core::{
    validate_default_expr, AggFunc, Aggregate, BatchItemOutcome, BatchItemStatus, BatchSummary,
    ColumnSchema, DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult,
    DataResult, DatabaseMount, DdlColumnDef, EngineAdapter, EngineCapabilities, EngineHealth,
    EnginePool, Filter, NormalizedType, RawStatement, RequestIdentity, SchemaDdlOp,
    SchemaDdlRequest, SchemaDdlResult, SchemaDdlStatus, SchemaDescriptor, TableSchema,
    TxBeginRequest, TxHandle,
};
use deadpool_sqlite::{Config as SqliteConfig, Pool, Runtime};
use rusqlite::types::Value as SqlValue;
use rusqlite::{params_from_iter, Connection};
use serde_json::{Map as JsonMap, Value};
use std::collections::BTreeMap;
use std::sync::Arc;

/// Server-controlled columns a client may never set/override.
const RESERVED_COLUMNS: &[&str] = &["owner_id", "tenant_id"];

/// The op kinds this adapter dispatches — single source of truth for the
/// descriptor (via `capability_honesty`) and the per-request gate.
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

pub struct SqliteEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl SqliteEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

#[async_trait]
impl EngineAdapter for SqliteEngineAdapter {
    fn engine(&self) -> &str {
        "sqlite"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::sqlite()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        let path = sqlite_path(&dsn);
        let cfg = SqliteConfig::new(path.clone());
        let pool = cfg
            .create_pool(Runtime::Tokio1)
            .map_err(|e| DataPlaneError::Backend {
                message: format!("sqlite pool create failed: {e}"),
            })?;

        // Enable WAL + a busy timeout once (WAL persists in the file; the timeout
        // is per-connection but harmless to set here on the first checkout).
        let obj = pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("sqlite checkout failed: {e}"),
        })?;
        obj.interact(|conn| {
            conn.pragma_update(None, "journal_mode", "WAL")?;
            // The standard WAL pairing (and what PocketBase ships): NORMAL
            // skips the per-commit fsync that FULL forces — the database can
            // never corrupt, at worst the last commits roll back on an OS
            // crash. Default FULL made every insert pay a ~10 ms fsync,
            // 2-3x slower than PocketBase on the same disk.
            conn.pragma_update(None, "synchronous", "NORMAL")?;
            conn.pragma_update(None, "busy_timeout", 5000)?;
            conn.pragma_update(None, "foreign_keys", "ON")
        })
        .await
        .map_err(|e| DataPlaneError::Backend {
            message: format!("sqlite pragma setup failed: {e}"),
        })?
        .map_err(backend)?;

        // Dedicated writer thread (single-writer + GROUP COMMIT): one OS
        // thread owns one connection and drains queued writes in batches of
        // up to GROUP_MAX per transaction — one commit (and one checkpoint
        // share) amortized across the whole group. Reads stay on the pool
        // (WAL = N parallel readers).
        let (writer, jobs) = tokio::sync::mpsc::unbounded_channel();
        let writer_path = path.clone();
        std::thread::Builder::new()
            .name(format!("sqlite-writer-{}", mount.id))
            .spawn(move || writer_loop(&writer_path, jobs))
            .map_err(|e| DataPlaneError::Backend {
                message: format!("sqlite writer thread spawn failed: {e}"),
            })?;

        Ok(Box::new(SqlitePool {
            mount_id: mount.id.clone(),
            tenant_id: mount.tenant_id.clone(),
            owner_scoped: mount.isolation().owner_scoped(),
            shared_pool: crate::pools_shared(&mount),
            pool,
            writer,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth {
            engine: "sqlite".to_string(),
            mount_id: pool.mount_id().to_string(),
            status: "unknown".to_string(),
        })
    }
}

pub struct SqlitePool {
    mount_id: String,
    tenant_id: String,
    /// `true` for `shared_rls` (the default) — every read/write is scoped to the
    /// caller's `owner_id`. `false` for `tenant_owned` (the whole file is one
    /// tenant's, scoped at mount resolution) — no per-row owner predicate.
    owner_scoped: bool,
    /// True for a SHARE_POOLS shared_rls pool serving many tenants from one
    /// SQLite file: the single-owner `check_tenant` assertion is skipped (the
    /// `owner_id` predicate from each request's identity carries isolation).
    /// See `crate::pools_shared`.
    shared_pool: bool,
    pool: Pool,
    /// SQLite allows exactly ONE writer per database. N pooled connections
    /// fighting for the file lock collapse under load (measured: 48 req/s at
    /// c=64, p99 pinned at the 5 s busy_timeout); even a fair semaphore pays
    /// a full commit per write (57 req/s at c=64). The answer — the one
    /// high-throughput SQLite servers use — is this queue to a dedicated
    /// writer thread that GROUP-COMMITS: up to [`GROUP_MAX`] queued writes
    /// execute inside one transaction (a savepoint per job preserves per-job
    /// atomicity), so one commit is amortized across the whole group. WAL
    /// readers stay fully parallel on the pool.
    writer: tokio::sync::mpsc::UnboundedSender<WriteJob>,
}

impl SqlitePool {
    fn check_tenant(&self, identity: &RequestIdentity) -> DataPlaneResult<()> {
        // SHARE_POOLS shared_rls pool: multi-tenant by design, no single owner
        // to assert; the per-request `owner_id` predicate carries isolation.
        if self.shared_pool {
            return Ok(());
        }
        if identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match pool tenant".into(),
            });
        }
        Ok(())
    }

    fn owner(&self, identity: &RequestIdentity) -> Option<String> {
        self.owner_scoped.then(|| owner_of(identity))
    }

    /// Enqueue a job on the writer thread and await its (post-commit) reply.
    async fn submit<T>(
        &self,
        make: impl FnOnce(tokio::sync::oneshot::Sender<DataPlaneResult<T>>) -> WriteJob,
    ) -> DataPlaneResult<T> {
        let (reply, rx) = tokio::sync::oneshot::channel();
        self.writer
            .send(make(reply))
            .map_err(|_| DataPlaneError::Backend {
                message: "sqlite writer thread is gone".into(),
            })?;
        rx.await.map_err(|_| DataPlaneError::Backend {
            message: "sqlite writer dropped the reply".into(),
        })?
    }
}

#[async_trait]
impl EnginePool for SqlitePool {
    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        self.check_tenant(&identity)?;
        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("operation {:?} on sqlite", operation.op),
            });
        }
        let owner = self.owner(&identity);

        // Batch (atomic: a poison item rolls the whole batch back) runs on the
        // writer thread inside its own savepoint within the group transaction.
        if operation.op == DataOperationKind::Batch {
            let items = operation
                .batch_items()
                .map_err(|message| DataPlaneError::InvalidRequest { message })?;
            let mut plans: Vec<(SqlPlan, String)> = Vec::with_capacity(items.len());
            for sub in &items {
                let plan = build_plan(sub, owner.as_deref())?;
                plans.push((plan, format!("{:?}", sub.op)));
            }
            let summary = self.submit(|reply| WriteJob::Batch(plans, reply)).await?;
            return Ok(DataResult {
                rows: vec![],
                affected_rows: summary.items.iter().filter(|i| i.status == BatchItemStatus::Ok).count() as u64,
                next_cursor: None,
                batch: Some(summary),
            });
        }

        // Single-writer + group-commit: mutations queue to the writer thread;
        // reads (list/get/aggregate) run fully parallel on the pool under WAL.
        let is_write = matches!(
            operation.op,
            DataOperationKind::Insert
                | DataOperationKind::Update
                | DataOperationKind::Delete
                | DataOperationKind::Upsert
        );
        let plan = build_plan(&operation, owner.as_deref())?;
        if is_write {
            return self.submit(|reply| WriteJob::Plan(plan, reply)).await;
        }
        let obj = self.checkout().await?;
        obj.interact(move |conn| run_plan(&*conn, &plan))
            .await
            .map_err(|e| DataPlaneError::Backend {
                message: format!("sqlite interact: {e}"),
            })?
    }

    async fn begin(&self, _request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        // Honest with the descriptor (transactions:false): a connection-pinned
        // multi-statement transaction is not exposed on SQLite. A single batch
        // is still atomic via `execute`.
        Err(DataPlaneError::NotImplemented {
            feature: "multi-statement transactions on sqlite".to_string(),
        })
    }

    async fn close(&self) -> DataPlaneResult<()> {
        self.pool.close();
        Ok(())
    }

    /// Admin raw-SQL surface (route-gated on `service_role`). Used for DDL and
    /// anything outside the safe CRUD shape. `expect_rows` selects query vs
    /// execute; params bind positionally.
    async fn execute_raw(
        &self,
        statement: RawStatement,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        self.check_tenant(&identity)?;
        let RawStatement { statement: sql, params, expect_rows } = statement;
        let sql_params: Vec<SqlValue> = params.iter().map(json_to_sql).collect();
        // `expect_rows=false` is the write/DDL shape — writer-thread queue;
        // row-returning raw SQL reads in parallel off the pool.
        if !expect_rows {
            return self
                .submit(|reply| WriteJob::Raw { sql, params: sql_params, reply })
                .await;
        }
        let obj = self.checkout().await?;
        obj.interact(move |conn| {
            let rows = query_rows(&*conn, &sql, &sql_params)?;
            let affected = rows.len() as u64;
            Ok(DataResult::new(rows, affected))
        })
        .await
        .map_err(|e| DataPlaneError::Backend {
            message: format!("sqlite raw interact: {e}"),
        })?
    }

    async fn describe_schema(&self, identity: RequestIdentity) -> DataPlaneResult<SchemaDescriptor> {
        self.check_tenant(&identity)?;
        let obj = self.checkout().await?;
        obj.interact(|conn| describe_schema_blocking(&*conn))
            .await
            .map_err(|e| DataPlaneError::Backend {
                message: format!("sqlite introspect interact: {e}"),
            })?
    }

    /// Structured DDL (the typed-collections contract): lowered by the pure
    /// [`build_sqlite_ddl`] builder, executed on the mount's file. SQLite DDL
    /// is auto-commit — exactly why the contract is single-op. The one honest
    /// limit: `alter_column_type` is rejected (SQLite has no `ALTER COLUMN`;
    /// the official recipe is a 12-step table rebuild — out of contract).
    async fn apply_schema_ddl(
        &self,
        ddl: SchemaDdlRequest,
        identity: RequestIdentity,
    ) -> DataPlaneResult<SchemaDdlResult> {
        self.check_tenant(&identity)?;
        let stmt = build_sqlite_ddl(&ddl)?;
        self.submit(|reply| WriteJob::Ddl(stmt, reply)).await?;
        Ok(SchemaDdlResult {
            op: ddl.op,
            table: ddl.table,
            status: SchemaDdlStatus::Applied,
        })
    }
}

impl SqlitePool {
    async fn checkout(&self) -> DataPlaneResult<deadpool_sqlite::Object> {
        self.pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("sqlite checkout failed: {e}"),
        })
    }
}

// ── plan: pure (sql, params) building, no DB access ─────────────────────────

/// A built statement: its SQL, positional params, and whether it returns rows.
struct SqlPlan {
    sql: String,
    params: Vec<SqlValue>,
    returns_rows: bool,
}

fn build_plan(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    match op.op {
        DataOperationKind::List => build_list(op, owner),
        DataOperationKind::Get => build_get(op, owner),
        DataOperationKind::Insert => build_insert(op, owner),
        DataOperationKind::Update => build_update(op, owner),
        DataOperationKind::Delete => build_delete(op, owner),
        DataOperationKind::Upsert => build_upsert(op, owner),
        DataOperationKind::Aggregate => build_aggregate(op, owner),
        DataOperationKind::Batch => Err(DataPlaneError::InvalidRequest {
            message: "nested batch is not allowed".into(),
        }),
    }
}

fn build_list(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), owner)?;
    let order_sql = build_order_by(op.sort.as_ref())?;
    let limit = op.limit.unwrap_or(100).min(500);
    let offset = op.offset.unwrap_or(0);
    Ok(SqlPlan {
        sql: format!("SELECT * FROM {table}{where_sql}{order_sql} LIMIT {limit} OFFSET {offset}"),
        params,
        returns_rows: true,
    })
}

fn build_get(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), owner)?;
    Ok(SqlPlan {
        sql: format!("SELECT * FROM {table}{where_sql} LIMIT 1"),
        params,
        returns_rows: true,
    })
}

fn build_insert(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let columns = build_owned_columns(op.data.as_ref(), owner)?;
    if columns.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "insert `data` must not be empty".to_string(),
        });
    }
    let (col_sql, ph, params) = render_columns(&columns)?;
    Ok(SqlPlan {
        sql: format!("INSERT INTO {table} ({col_sql}) VALUES ({ph})"),
        params,
        returns_rows: false,
    })
}

fn build_update(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    crate::sql_scope::guard_constraining_filter(op.filter.as_ref(), RESERVED_COLUMNS)?;
    let set_cols = build_safe_columns(op.data.as_ref())?;
    if set_cols.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "update `data` must not be empty".to_string(),
        });
    }
    let mut params: Vec<SqlValue> = Vec::with_capacity(set_cols.len());
    let mut set_parts = Vec::with_capacity(set_cols.len());
    for (col, val) in &set_cols {
        set_parts.push(format!("{} = ?", quote_ident(col)?));
        params.push(json_to_sql(val));
    }
    let (where_sql, mut where_params) = build_owner_filter(op.filter.as_ref(), owner)?;
    params.append(&mut where_params);
    Ok(SqlPlan {
        sql: format!("UPDATE {table} SET {}{where_sql}", set_parts.join(", ")),
        params,
        returns_rows: false,
    })
}

fn build_delete(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    crate::sql_scope::guard_constraining_filter(op.filter.as_ref(), RESERVED_COLUMNS)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), owner)?;
    Ok(SqlPlan {
        sql: format!("DELETE FROM {table}{where_sql}"),
        params,
        returns_rows: false,
    })
}

fn build_upsert(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let data = require_object(op.data.as_ref(), "data")?;
    let filter = require_object(op.filter.as_ref(), "filter")?;
    let columns = build_owned_columns(op.data.as_ref(), owner)?;
    if columns.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert `data` must not be empty".to_string(),
        });
    }
    // Conflict target = owner_id (when owner-scoped) + the sorted filter keys.
    // SQLite arbitrates ON CONFLICT at the matching UNIQUE index, BELOW any RLS:
    // a foreign owner's id collision hits the id PRIMARY KEY (an unhandled
    // target) and errors rather than overwriting — the cross-owner guard.
    let mut conflict_cols: Vec<String> = Vec::new();
    if owner.is_some() {
        conflict_cols.push(quote_ident("owner_id")?);
    }
    let mut keys: Vec<&str> = filter
        .keys()
        .map(String::as_str)
        .filter(|k| *k != "owner_id")
        .collect();
    keys.sort_unstable();
    if keys.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert `filter` (conflict key) must not be empty".to_string(),
        });
    }
    for k in &keys {
        conflict_cols.push(quote_ident(k)?);
    }
    let conflict_set: std::collections::BTreeSet<&str> =
        keys.iter().copied().chain(std::iter::once("owner_id")).collect();

    let (col_sql, ph, params) = render_columns(&columns)?;
    // Update every owned column that is NOT part of the conflict target.
    let mut update_parts: Vec<String> = Vec::new();
    for (col, _) in &columns {
        if conflict_set.contains(col.as_str()) {
            continue;
        }
        let q = quote_ident(col)?;
        update_parts.push(format!("{q} = excluded.{q}"));
    }
    let do_clause = if update_parts.is_empty() {
        // Only the key/owner columns were supplied → idempotent no-op on conflict.
        "DO NOTHING".to_string()
    } else {
        format!("DO UPDATE SET {}", update_parts.join(", "))
    };
    let _ = data; // require_object validated shape; columns already built
    Ok(SqlPlan {
        sql: format!(
            "INSERT INTO {table} ({col_sql}) VALUES ({ph}) ON CONFLICT ({}) {do_clause}",
            conflict_cols.join(", ")
        ),
        params,
        returns_rows: false,
    })
}

fn build_aggregate(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let spec = op.aggregate.as_ref().ok_or_else(|| DataPlaneError::InvalidRequest {
        message: "aggregate requires an `aggregate` spec".to_string(),
    })?;
    if spec.aggregates.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "aggregate requires at least one aggregate function".to_string(),
        });
    }
    let mut seen: std::collections::BTreeSet<&str> = std::collections::BTreeSet::new();
    for name in spec
        .group_by
        .iter()
        .map(String::as_str)
        .chain(spec.aggregates.iter().map(|a| a.alias.as_str()))
    {
        if !seen.insert(name) {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("duplicate aggregate output column '{name}'"),
            });
        }
    }
    let mut select_cols: Vec<String> = Vec::new();
    let mut group_cols: Vec<String> = Vec::new();
    for col in &spec.group_by {
        let ident = quote_ident(col)?;
        select_cols.push(ident.clone());
        group_cols.push(ident);
    }
    for agg in &spec.aggregates {
        select_cols.push(build_aggregate_expr(agg)?);
    }
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), owner)?;
    let group_sql = if group_cols.is_empty() {
        String::new()
    } else {
        format!(" GROUP BY {}", group_cols.join(", "))
    };
    let order_sql = build_order_by(op.sort.as_ref())?;
    let limit = op.limit.unwrap_or(1000).min(10_000);
    Ok(SqlPlan {
        sql: format!(
            "SELECT {} FROM {table}{where_sql}{group_sql}{order_sql} LIMIT {limit}",
            select_cols.join(", ")
        ),
        params,
        returns_rows: true,
    })
}

fn build_aggregate_expr(agg: &Aggregate) -> DataPlaneResult<String> {
    let alias = quote_ident(&agg.alias)?;
    let func = match agg.func {
        AggFunc::Count => "COUNT",
        AggFunc::Sum => "SUM",
        AggFunc::Avg => "AVG",
        AggFunc::Min => "MIN",
        AggFunc::Max => "MAX",
    };
    let arg = match (&agg.field, agg.func) {
        (Some(field), _) => quote_ident(field)?,
        (None, AggFunc::Count) if !agg.distinct => "*".to_string(),
        (None, _) => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("aggregate '{func}' requires a `field`"),
            })
        }
    };
    if agg.distinct {
        Ok(format!("{func}(DISTINCT {arg}) AS {alias}"))
    } else {
        Ok(format!("{func}({arg}) AS {alias}"))
    }
}

// ── blocking executors (run inside interact, sync rusqlite) ──────────────────

fn run_plan(conn: &Connection, plan: &SqlPlan) -> DataPlaneResult<DataResult> {
    if plan.returns_rows {
        let rows = query_rows(conn, &plan.sql, &plan.params)?;
        let affected = rows.len() as u64;
        Ok(DataResult::new(rows, affected))
    } else {
        let affected = exec_write(conn, &plan.sql, &plan.params)?;
        Ok(DataResult::new(vec![], affected))
    }
}

// ── single-writer GROUP COMMIT ───────────────────────────────────────────────
//
// One OS thread owns one write connection per mount. Queued jobs execute in
// groups of up to GROUP_MAX inside ONE transaction — a SAVEPOINT per job keeps
// per-job atomicity (a failing job rolls back only itself) — so the per-commit
// cost (and the WAL-checkpoint share) is amortized across the group. Replies
// are sent only AFTER the group commits: an acked write is a committed write.

/// Upper bound on jobs coalesced into one transaction. Big enough to amortize
/// the commit under load, small enough to bound reply latency for the first
/// job in a group.
const GROUP_MAX: usize = 128;

enum WriteJob {
    /// One built CRUD statement (insert/update/delete/upsert).
    Plan(SqlPlan, tokio::sync::oneshot::Sender<DataPlaneResult<DataResult>>),
    /// An atomic multi-statement batch (its own savepoint = all-or-nothing).
    Batch(
        Vec<(SqlPlan, String)>,
        tokio::sync::oneshot::Sender<DataPlaneResult<BatchSummary>>,
    ),
    /// Raw write/DDL SQL (`expect_rows=false` shape).
    Raw {
        sql: String,
        params: Vec<SqlValue>,
        reply: tokio::sync::oneshot::Sender<DataPlaneResult<DataResult>>,
    },
    /// A structured-DDL statement (classified errors).
    Ddl(String, tokio::sync::oneshot::Sender<DataPlaneResult<DataResult>>),
}

/// A processed job's deferred outcome: replies fire after COMMIT.
enum Deferred {
    Data(
        tokio::sync::oneshot::Sender<DataPlaneResult<DataResult>>,
        DataPlaneResult<DataResult>,
    ),
    Batch(
        tokio::sync::oneshot::Sender<DataPlaneResult<BatchSummary>>,
        DataPlaneResult<BatchSummary>,
    ),
}

impl Deferred {
    /// Send the buffered outcome; `commit_ok=false` downgrades a success to a
    /// backend error (the group's COMMIT failed → nothing persisted).
    fn send(self, commit_ok: bool) {
        fn gate<T>(commit_ok: bool, r: DataPlaneResult<T>) -> DataPlaneResult<T> {
            match (commit_ok, r) {
                (false, Ok(_)) => Err(DataPlaneError::Backend {
                    message: "sqlite group commit failed".into(),
                }),
                (_, r) => r,
            }
        }
        match self {
            Self::Data(tx, r) => {
                let _ = tx.send(gate(commit_ok, r));
            }
            Self::Batch(tx, r) => {
                let _ = tx.send(gate(commit_ok, r));
            }
        }
    }
}

fn open_writer_conn(path: &str) -> Result<Connection, rusqlite::Error> {
    let conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "busy_timeout", 5000)?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    Ok(conn)
}

fn writer_loop(path: &str, mut jobs: tokio::sync::mpsc::UnboundedReceiver<WriteJob>) {
    let conn = match open_writer_conn(path) {
        Ok(c) => c,
        Err(e) => {
            // Fail every job with the open error; senders see Backend.
            let msg = format!("sqlite writer connection failed: {e}");
            while let Some(job) = jobs.blocking_recv() {
                let err = || DataPlaneError::Backend { message: msg.clone() };
                match job {
                    WriteJob::Plan(_, tx) | WriteJob::Raw { reply: tx, .. } | WriteJob::Ddl(_, tx) => {
                        let _ = tx.send(Err(err()));
                    }
                    WriteJob::Batch(_, tx) => {
                        let _ = tx.send(Err(err()));
                    }
                }
            }
            return;
        }
    };

    // Exits when every sender is dropped (the pool was closed/evicted).
    while let Some(first) = jobs.blocking_recv() {
        let mut group = vec![first];
        while group.len() < GROUP_MAX {
            match jobs.try_recv() {
                Ok(job) => group.push(job),
                Err(_) => break,
            }
        }

        if let Err(e) = conn.execute_batch("BEGIN IMMEDIATE") {
            let msg = format!("sqlite begin failed: {e}");
            for job in group {
                let err = || DataPlaneError::Backend { message: msg.clone() };
                match job {
                    WriteJob::Plan(_, tx) | WriteJob::Raw { reply: tx, .. } | WriteJob::Ddl(_, tx) => {
                        let _ = tx.send(Err(err()));
                    }
                    WriteJob::Batch(_, tx) => {
                        let _ = tx.send(Err(err()));
                    }
                }
            }
            continue;
        }

        let mut deferred: Vec<Deferred> = Vec::with_capacity(group.len());
        for (i, job) in group.into_iter().enumerate() {
            deferred.push(process_in_savepoint(&conn, i, job));
        }
        let commit_ok = conn.execute_batch("COMMIT").is_ok();
        if !commit_ok {
            // Roll anything half-open back so the connection is reusable.
            let _ = conn.execute_batch("ROLLBACK");
        }
        for d in deferred {
            d.send(commit_ok);
        }
    }
}

/// Run one job inside its own savepoint: a failing job rolls back ONLY itself;
/// the surrounding group transaction (and its siblings) proceed.
fn process_in_savepoint(conn: &Connection, idx: usize, job: WriteJob) -> Deferred {
    let sp = format!("g{idx}");
    if let Err(e) = conn.execute_batch(&format!("SAVEPOINT {sp}")) {
        let err = DataPlaneError::Backend {
            message: format!("sqlite savepoint: {e}"),
        };
        return match job {
            WriteJob::Plan(_, tx) | WriteJob::Raw { reply: tx, .. } | WriteJob::Ddl(_, tx) => {
                Deferred::Data(tx, Err(err))
            }
            WriteJob::Batch(_, tx) => Deferred::Batch(tx, Err(err)),
        };
    }
    let (outcome, failed): (Deferred, bool) = match job {
        WriteJob::Plan(plan, tx) => {
            let r = run_plan(conn, &plan);
            let failed = r.is_err();
            (Deferred::Data(tx, r), failed)
        }
        WriteJob::Raw { sql, params, reply } => {
            let r = exec_write(conn, &sql, &params).map(|affected| DataResult::new(vec![], affected));
            let failed = r.is_err();
            (Deferred::Data(reply, r), failed)
        }
        WriteJob::Ddl(sql, tx) => {
            let r = conn
                .execute(&sql, [])
                .map(|_| DataResult::new(vec![], 0))
                .map_err(|e| classify_sqlite_ddl_error(&e));
            let failed = r.is_err();
            (Deferred::Data(tx, r), failed)
        }
        WriteJob::Batch(plans, tx) => {
            let r = run_batch_in_savepoint(conn, &plans);
            let failed = r.is_err();
            (Deferred::Batch(tx, r), failed)
        }
    };
    if failed {
        // The job's own writes (if any) are undone; siblings are untouched.
        let _ = conn.execute_batch(&format!("ROLLBACK TO {sp}"));
    }
    let _ = conn.execute_batch(&format!("RELEASE {sp}"));
    outcome
}

/// The atomic-batch contract inside the group: all items or none. The caller
/// (`process_in_savepoint`) rolls the enclosing savepoint back on Err, which
/// undoes every item executed before the poison one.
fn run_batch_in_savepoint(
    conn: &Connection,
    plans: &[(SqlPlan, String)],
) -> DataPlaneResult<BatchSummary> {
    let mut items: Vec<BatchItemOutcome> = Vec::with_capacity(plans.len());
    for (idx, (plan, _kind)) in plans.iter().enumerate() {
        let res = if plan.returns_rows {
            query_rows(conn, &plan.sql, &plan.params).map(|_| 0u64)
        } else {
            exec_write(conn, &plan.sql, &plan.params)
        };
        match res {
            Ok(affected) => items.push(BatchItemOutcome {
                index: idx as u32,
                status: BatchItemStatus::Ok,
                affected_rows: affected,
                error: None,
            }),
            Err(e) => {
                return Err(DataPlaneError::prefix_message(
                    &format!("batch item {idx}: "),
                    e,
                ))
            }
        }
    }
    Ok(BatchSummary {
        atomic: true,
        items,
    })
}

fn query_rows(conn: &Connection, sql: &str, params: &[SqlValue]) -> DataPlaneResult<Vec<Value>> {
    // prepare_cached reuses the compiled VDBE program for a fixed query shape
    // (the per-connection cache is sized in `tune_read_conn`), removing a SQL
    // parse + recompile from every read — what PocketBase already amortizes.
    // Results are byte-identical to `prepare`.
    let mut stmt = conn.prepare_cached(sql).map_err(backend)?;
    let col_names: Vec<String> = stmt.column_names().into_iter().map(String::from).collect();
    let mapped = stmt
        .query_map(params_from_iter(params.iter()), move |row| {
            let mut obj = JsonMap::with_capacity(col_names.len());
            for (i, name) in col_names.iter().enumerate() {
                obj.insert(name.clone(), sql_to_json(row.get::<_, SqlValue>(i)?));
            }
            Ok(Value::Object(obj))
        })
        .map_err(backend)?;
    let mut out = Vec::new();
    for r in mapped {
        out.push(r.map_err(backend)?);
    }
    Ok(out)
}

fn exec_write(conn: &Connection, sql: &str, params: &[SqlValue]) -> DataPlaneResult<u64> {
    let n = conn
        .execute(sql, params_from_iter(params.iter()))
        .map_err(backend)?;
    Ok(n as u64)
}

fn describe_schema_blocking(conn: &Connection) -> DataPlaneResult<SchemaDescriptor> {
    let mut tables: Vec<TableSchema> = Vec::new();
    let table_names: Vec<String> = {
        let mut stmt = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .map_err(backend)?;
        let names = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(backend)?;
        names.filter_map(Result::ok).collect()
    };
    for table in table_names {
        let mut columns: Vec<ColumnSchema> = Vec::new();
        let mut primary_key: Vec<(i64, String)> = Vec::new();
        let mut stmt = conn
            .prepare(&format!("PRAGMA table_info({})", quote_ident(&table)?))
            .map_err(backend)?;
        let rows = stmt
            .query_map([], |row| {
                let name: String = row.get(1)?;
                let native: String = row.get(2)?;
                let notnull: i64 = row.get(3)?;
                let dflt: Option<String> = row.get(4)?;
                let pk: i64 = row.get(5)?; // 0 = not pk, else 1-based position
                Ok((name, native, notnull == 0, dflt, pk))
            })
            .map_err(backend)?;
        for r in rows {
            let (name, native, nullable, default, pk) = r.map_err(backend)?;
            if pk > 0 {
                primary_key.push((pk, name.clone()));
            }
            let normalized = normalize_sqlite_type(&native);
            columns.push(ColumnSchema {
                name,
                native_type: native,
                normalized_type: normalized,
                nullable,
                default,
                enum_values: None,
                references: None,
                inferred: false,
            });
        }
        primary_key.sort_by_key(|(rank, _)| *rank);
        tables.push(TableSchema {
            name: table,
            primary_key: primary_key.into_iter().map(|(_, n)| n).collect(),
            columns,
        });
    }
    Ok(SchemaDescriptor {
        engine: "sqlite".to_string(),
        tables,
    })
}

fn normalize_sqlite_type(native: &str) -> NormalizedType {
    let t = native.to_ascii_lowercase();
    if t.contains("int") {
        NormalizedType::Integer
    } else if t.contains("char") || t.contains("clob") || t.contains("text") {
        NormalizedType::Text
    } else if t.contains("real") || t.contains("floa") || t.contains("doub") {
        NormalizedType::Float
    } else if t.contains("num") || t.contains("dec") {
        NormalizedType::Decimal
    } else if t.contains("bool") {
        NormalizedType::Boolean
    } else if t.contains("blob") {
        NormalizedType::Unknown
    } else if t.contains("date") || t.contains("time") {
        NormalizedType::Datetime
    } else {
        NormalizedType::Unknown
    }
}

// ── pure helpers (owner scope, filter lowering, columns) ─────────────────────

fn owner_of(identity: &RequestIdentity) -> String {
    identity.owner_principal().to_string()
}

/// `WHERE` clause that intersects the (reserved-stripped) client filter with the
/// trusted `owner_id` predicate. `owner: None` (tenant_owned) emits the client
/// filter only — but still requires a `WHERE` to avoid an unscoped statement
/// when a filter is present; an absent filter yields an empty clause (caller
/// guards mass mutations separately).
/// SQLite binds every value as a positional `?` (param order IS binding order),
/// so the shared filter lowerer pushes through this sink.
struct SqliteSink(Vec<SqlValue>);

impl crate::sql_scope::SqlParamSink for SqliteSink {
    fn bind(&mut self, value: &Value) -> String {
        self.0.push(json_to_sql(value));
        "?".to_string()
    }
    fn quote_ident(&self, name: &str) -> DataPlaneResult<String> {
        quote_ident(name)
    }
}

fn build_owner_filter(
    filter: Option<&Value>,
    owner: Option<&str>,
) -> DataPlaneResult<(String, Vec<SqlValue>)> {
    let mut sink = SqliteSink(Vec::new());
    let mut clauses: Vec<String> = Vec::new();
    if let Some(filter_value) = filter {
        let cleaned = crate::sql_scope::strip_reserved_top_level(filter_value, RESERVED_COLUMNS);
        let tree = Filter::parse(&cleaned)?;
        if let Some(sql) = crate::sql_scope::lower_filter(&tree, &mut sink)? {
            clauses.push(format!("({sql})"));
        }
    }
    if let Some(owner) = owner {
        sink.0.push(SqlValue::Text(owner.to_string()));
        clauses.push("\"owner_id\" = ?".to_string());
    }
    let params = sink.0;
    if clauses.is_empty() {
        Ok((String::new(), params))
    } else {
        Ok((format!(" WHERE {}", clauses.join(" AND ")), params))
    }
}

/// INSERT/UPSERT column set: strip reserved client columns, re-inject the
/// trusted `owner_id` when owner-scoped.
fn build_owned_columns(
    data: Option<&Value>,
    owner: Option<&str>,
) -> DataPlaneResult<Vec<(String, Value)>> {
    let map = require_object(data, "data")?;
    let mut columns: Vec<(String, Value)> = Vec::with_capacity(map.len() + 1);
    for (col, val) in map {
        if RESERVED_COLUMNS.contains(&col.as_str()) {
            continue;
        }
        columns.push((col.clone(), val.clone()));
    }
    if let Some(owner) = owner {
        columns.push(("owner_id".to_string(), Value::String(owner.to_string())));
    }
    Ok(columns)
}

fn build_safe_columns(data: Option<&Value>) -> DataPlaneResult<Vec<(String, Value)>> {
    let map = require_object(data, "data")?;
    let mut out: Vec<(String, Value)> = Vec::with_capacity(map.len());
    for (col, val) in map {
        if RESERVED_COLUMNS.contains(&col.as_str()) {
            continue;
        }
        out.push((col.clone(), val.clone()));
    }
    Ok(out)
}

/// Render `(col, col, …)`, `(?, ?, …)` and the matching param vector.
fn render_columns(
    columns: &[(String, Value)],
) -> DataPlaneResult<(String, String, Vec<SqlValue>)> {
    let mut col_sql = Vec::with_capacity(columns.len());
    let mut ph = Vec::with_capacity(columns.len());
    let mut params = Vec::with_capacity(columns.len());
    for (col, val) in columns {
        col_sql.push(quote_ident(col)?);
        ph.push("?".to_string());
        params.push(json_to_sql(val));
    }
    Ok((col_sql.join(", "), ph.join(", "), params))
}

fn build_order_by(sort: Option<&BTreeMap<String, String>>) -> DataPlaneResult<String> {
    let Some(map) = sort else {
        return Ok(String::new());
    };
    if map.is_empty() {
        return Ok(String::new());
    }
    let mut parts: Vec<String> = Vec::with_capacity(map.len());
    for (col, dir) in map {
        let dir_sql = if dir.eq_ignore_ascii_case("desc") { "DESC" } else { "ASC" };
        parts.push(format!("{} {dir_sql}", quote_ident(col)?));
    }
    Ok(format!(" ORDER BY {}", parts.join(", ")))
}

fn require_object<'a>(data: Option<&'a Value>, what: &str) -> DataPlaneResult<&'a JsonMap<String, Value>> {
    match data {
        Some(Value::Object(map)) => Ok(map),
        Some(other) => Err(DataPlaneError::InvalidRequest {
            message: format!("{what} must be a JSON object, got {other:?}"),
        }),
        None => Err(DataPlaneError::InvalidRequest {
            message: format!("{what} is required"),
        }),
    }
}

/// SQLite identifier quoting (`"col"`). Rejects identifiers containing a double
/// quote, NUL, or control chars so a crafted field name can't break out.
fn quote_ident(ident: &str) -> DataPlaneResult<String> {
    if ident.is_empty()
        || ident.len() > 128
        || ident.contains('"')
        || ident.contains('\0')
        || ident.chars().any(char::is_control)
    {
        return Err(DataPlaneError::InvalidIdentifier {
            value: ident.to_string(),
        });
    }
    Ok(format!("\"{ident}\""))
}

fn json_to_sql(value: &Value) -> SqlValue {
    match value {
        Value::Null => SqlValue::Null,
        Value::Bool(b) => SqlValue::Integer(i64::from(*b)),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                SqlValue::Integer(i)
            } else if let Some(f) = n.as_f64() {
                SqlValue::Real(f)
            } else {
                SqlValue::Null
            }
        }
        Value::String(s) => SqlValue::Text(s.clone()),
        // Arrays / objects are stored as their JSON text (SQLite has no native
        // composite types); reads return them as a string.
        other => SqlValue::Text(other.to_string()),
    }
}

fn sql_to_json(value: SqlValue) -> Value {
    match value {
        SqlValue::Null => Value::Null,
        SqlValue::Integer(i) => Value::Number(i.into()),
        SqlValue::Real(f) => serde_json::Number::from_f64(f).map_or(Value::Null, Value::Number),
        SqlValue::Text(s) => Value::String(s),
        SqlValue::Blob(b) => Value::String(format!("blob:{} bytes", b.len())),
    }
}

// ── structured schema DDL (typed collections) — pure SQL builders ───────────
//
// Mirrors the MySQL/PG lowering (`build_mysql_ddl`) in SQLite's dialect.
// Identifiers via the shared `quote_ident` ("…"); enum has no native type, so
// it lowers to TEXT + a CHECK(col IN (…)) constraint (enforced, even though
// introspection reports it back as text affinity); DEFAULT expressions pass
// the shared `validate_default_expr` guard before interpolation.

/// `'…'`-quoted SQLite string literal (quote doubling only — SQLite never
/// treats backslash as an escape).
fn sqlite_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

/// Lowers a [`DdlColumnDef`] to its SQLite column type. SQLite stores by type
/// affinity, so date/datetime/json/uuid land in TEXT and decimal in NUMERIC —
/// honest round-trip caveat: introspection reports the affinity, not the
/// declared intent. `objectid`/`unknown` are describe-only and rejected.
pub(crate) fn sqlite_sql_type(def: &DdlColumnDef) -> DataPlaneResult<String> {
    Ok(match def.normalized_type {
        NormalizedType::Text
        | NormalizedType::Date
        | NormalizedType::Datetime
        | NormalizedType::Json
        | NormalizedType::Uuid
        | NormalizedType::Array => "TEXT".to_string(),
        NormalizedType::Integer | NormalizedType::Boolean => "INTEGER".to_string(),
        NormalizedType::Float => "REAL".to_string(),
        NormalizedType::Decimal => "NUMERIC".to_string(),
        NormalizedType::Enum => {
            // Type + constraint are composed in `sqlite_column_clause` (the
            // CHECK needs the quoted column name).
            "TEXT".to_string()
        }
        NormalizedType::Objectid | NormalizedType::Unknown => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!(
                    "column '{}': normalized_type '{:?}' cannot be created on sqlite",
                    def.name, def.normalized_type
                ),
            })
        }
    })
}

/// One full column clause: `"name" TYPE [NOT NULL] [DEFAULT expr] [CHECK …]`.
fn sqlite_column_clause(def: &DdlColumnDef) -> DataPlaneResult<String> {
    let col = quote_ident(&def.name)?;
    let ty = sqlite_sql_type(def)?;
    let mut clause = format!("{col} {ty}");
    if !def.nullable {
        clause.push_str(" NOT NULL");
    }
    if let Some(default) = def.default.as_deref() {
        validate_default_expr(default)?;
        clause.push_str(&format!(" DEFAULT {default}"));
    }
    if def.normalized_type == NormalizedType::Enum {
        let values = def
            .enum_values
            .as_deref()
            .filter(|v| !v.is_empty())
            .ok_or_else(|| DataPlaneError::InvalidRequest {
                message: format!("enum column '{}' requires non-empty enum_values", def.name),
            })?;
        let literals: Vec<String> = values.iter().map(|v| sqlite_literal(v)).collect();
        clause.push_str(&format!(" CHECK ({col} IN ({}))", literals.join(", ")));
    }
    Ok(clause)
}

/// Lowers a [`SchemaDdlRequest`] to its single SQLite DDL statement.
/// `alter_column_type` is honestly rejected: SQLite has no `ALTER COLUMN`
/// (the official recipe is a 12-step table rebuild, out of this contract).
pub(crate) fn build_sqlite_ddl(ddl: &SchemaDdlRequest) -> DataPlaneResult<String> {
    let table = quote_ident(&ddl.table)?;
    Ok(match ddl.op {
        SchemaDdlOp::AddColumn => format!(
            "ALTER TABLE {table} ADD COLUMN {}",
            sqlite_column_clause(ddl.require_column()?)?
        ),
        SchemaDdlOp::DropColumn => format!(
            "ALTER TABLE {table} DROP COLUMN {}",
            quote_ident(ddl.require_column_name()?)?
        ),
        SchemaDdlOp::AlterColumnType => {
            return Err(DataPlaneError::InvalidRequest {
                message: "sqlite cannot alter a column's type in place; create a new column, copy, and drop the old one".to_string(),
            })
        }
        SchemaDdlOp::CreateTable => {
            let (columns, primary_key) = ddl.require_create_spec()?;
            let mut clauses = Vec::with_capacity(columns.len() + 2);
            let mut has_owner = false;
            for def in columns {
                if def.name == "owner_id" {
                    has_owner = true;
                }
                clauses.push(sqlite_column_clause(def)?);
            }
            if !has_owner {
                // The adapter owner-scopes every read/write on owner_id — a
                // table without the column would fail its first request.
                clauses.push(format!("{} TEXT", quote_ident("owner_id")?));
            }
            let pk: Vec<String> = primary_key
                .iter()
                .map(|c| quote_ident(c))
                .collect::<DataPlaneResult<_>>()?;
            clauses.push(format!("PRIMARY KEY ({})", pk.join(", ")));
            format!("CREATE TABLE {table} ({})", clauses.join(", "))
        }
        SchemaDdlOp::DropTable => format!("DROP TABLE {table}"),
    })
}

/// DDL-shaped mistakes ("already exists", "no such table/column", "duplicate
/// column") are the CALLER's error (400), not a backend fault — mirrors the
/// MySQL adapter's `ddl_backend` classification.
fn classify_sqlite_ddl_error(e: &rusqlite::Error) -> DataPlaneError {
    let msg = e.to_string();
    let lower = msg.to_ascii_lowercase();
    if lower.contains("already exists")
        || lower.contains("no such table")
        || lower.contains("no such column")
        || lower.contains("duplicate column")
    {
        DataPlaneError::InvalidRequest {
            message: format!("sqlite ddl: {msg}"),
        }
    } else {
        DataPlaneError::Backend {
            message: format!("sqlite ddl: {msg}"),
        }
    }
}

/// Classify a rusqlite error into the right client/server bucket: a constraint
/// violation (UNIQUE/PK/FK/NOT NULL/CHECK) is a 409 Conflict; everything else a
/// 502 Backend.
fn backend(e: rusqlite::Error) -> DataPlaneError {
    let msg = e.to_string();
    let lower = msg.to_ascii_lowercase();
    if lower.contains("unique constraint")
        || lower.contains("constraint failed")
        || lower.contains("not null")
        || lower.contains("foreign key")
    {
        DataPlaneError::Conflict {
            message: format!("sqlite constraint: {msg}"),
        }
    } else {
        DataPlaneError::Backend {
            message: format!("sqlite backend: {msg}"),
        }
    }
}

/// Parse a `sqlite:` DSN to a file path (or `:memory:`).
fn sqlite_path(dsn: &str) -> String {
    let s = dsn
        .strip_prefix("sqlite://")
        .or_else(|| dsn.strip_prefix("sqlite:"))
        .unwrap_or(dsn);
    if s.is_empty() || s == ":memory:" {
        ":memory:".to_string()
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dsn_parsing() {
        assert_eq!(sqlite_path("sqlite:///var/lib/x.db"), "/var/lib/x.db");
        assert_eq!(sqlite_path("sqlite::memory:"), ":memory:");
        assert_eq!(sqlite_path("sqlite://"), ":memory:");
        assert_eq!(sqlite_path("/abs/path.db"), "/abs/path.db");
    }

    #[test]
    fn ident_quoting_rejects_injection() {
        assert_eq!(quote_ident("name").unwrap(), "\"name\"");
        assert!(quote_ident("a\"; DROP TABLE x; --").is_err());
        assert!(quote_ident("").is_err());
    }

    #[test]
    fn owner_filter_always_scopes_when_owner_present() {
        let (sql, params) = build_owner_filter(Some(&serde_json::json!({"id": "x"})), Some("u1")).unwrap();
        assert!(sql.contains("\"owner_id\" = ?"), "{sql}");
        assert_eq!(params.len(), 2);
    }

    // ── structured DDL builders (typed collections) ─────────────────────────

    fn col(name: &str, ty: NormalizedType) -> DdlColumnDef {
        DdlColumnDef {
            name: name.into(),
            normalized_type: ty,
            nullable: true,
            default: None,
            enum_values: None,
        }
    }

    #[test]
    fn ddl_create_table_appends_owner_and_pk() {
        let req = SchemaDdlRequest {
            op: SchemaDdlOp::CreateTable,
            table: "posts".into(),
            column: None,
            column_name: None,
            columns: Some(vec![col("id", NormalizedType::Text), col("views", NormalizedType::Integer)]),
            primary_key: Some(vec!["id".into()]),
        };
        let sql = build_sqlite_ddl(&req).unwrap();
        assert_eq!(
            sql,
            "CREATE TABLE \"posts\" (\"id\" TEXT, \"views\" INTEGER, \"owner_id\" TEXT, PRIMARY KEY (\"id\"))"
        );
    }

    #[test]
    fn ddl_enum_lowers_to_text_check() {
        let mut c = col("status", NormalizedType::Enum);
        c.enum_values = Some(vec!["new".into(), "it's".into()]);
        c.nullable = false;
        c.default = Some("'new'".into());
        let req = SchemaDdlRequest {
            op: SchemaDdlOp::AddColumn,
            table: "posts".into(),
            column: Some(c),
            column_name: None,
            columns: None,
            primary_key: None,
        };
        let sql = build_sqlite_ddl(&req).unwrap();
        assert_eq!(
            sql,
            "ALTER TABLE \"posts\" ADD COLUMN \"status\" TEXT NOT NULL DEFAULT 'new' CHECK (\"status\" IN ('new', 'it''s'))"
        );
    }

    #[test]
    fn ddl_alter_column_type_is_honestly_rejected() {
        let req = SchemaDdlRequest {
            op: SchemaDdlOp::AlterColumnType,
            table: "posts".into(),
            column: Some(col("views", NormalizedType::Text)),
            column_name: None,
            columns: None,
            primary_key: None,
        };
        assert!(matches!(
            build_sqlite_ddl(&req),
            Err(DataPlaneError::InvalidRequest { .. })
        ));
    }

    #[test]
    fn ddl_drop_column_and_table_quote_identifiers() {
        let drop_col = SchemaDdlRequest {
            op: SchemaDdlOp::DropColumn,
            table: "posts".into(),
            column: None,
            column_name: Some("views".into()),
            columns: None,
            primary_key: None,
        };
        assert_eq!(build_sqlite_ddl(&drop_col).unwrap(), "ALTER TABLE \"posts\" DROP COLUMN \"views\"");
        let drop_table = SchemaDdlRequest {
            op: SchemaDdlOp::DropTable,
            table: "posts".into(),
            column: None,
            column_name: None,
            columns: None,
            primary_key: None,
        };
        assert_eq!(build_sqlite_ddl(&drop_table).unwrap(), "DROP TABLE \"posts\"");
    }

    #[test]
    fn ddl_default_expr_guard_applies() {
        let mut c = col("n", NormalizedType::Integer);
        c.default = Some("0; DROP TABLE x".into());
        let req = SchemaDdlRequest {
            op: SchemaDdlOp::AddColumn,
            table: "posts".into(),
            column: Some(c),
            column_name: None,
            columns: None,
            primary_key: None,
        };
        assert!(build_sqlite_ddl(&req).is_err());
    }
}
