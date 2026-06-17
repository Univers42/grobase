//! MySQL engine adapter — R7.
//!
//! Mirrors the design of [`crate::postgres`] but for the official
//! `mysql_async` crate. The driver owns a connection pool per
//! [`DatabaseMount::pool_key`] so the hot path never pays the connect cost the
//! legacy `MysqlEngine` TypeScript adapter does on every request
//! (`mysql.createConnection(...)` per call).
//!
//! Tenant isolation:
//!   * MySQL has no GUC equivalent to Postgres `set_config('app.current_*')`,
//!     so this adapter intersects every read filter with `owner_id = ?` server-
//!     side and re-injects `owner_id` into every write payload from the
//!     verified [`RequestIdentity`] before reaching the wire. A forged client
//!     filter or body cannot leak cross-tenant rows.
//!   * Parity contract with the legacy
//!     [`src/apps/query-router/src/engines/mysql.engine.ts`] is preserved:
//!     `owner_id` is the only column the adapter enforces (TS does not write
//!     `tenant_id` either; per-tenant DB isolation lives at the mount layer).
//!
//! Pattern stack:
//!   * Adapter (GoF)       — implements [`EngineAdapter`].
//!   * Object Pool         — `mysql_async::Pool` is already a connection pool.
//!   * Strategy            — operation kind switches the executor branch.
//!   * Template Method     — `build_owner_filter`/`build_owned_columns` shared
//!     across all read/write code paths.

use crate::ident::quote_mysql_ident;
use crate::resolver::MountResolver;
use async_trait::async_trait;
use data_plane_core::{
    validate_default_expr, AggFunc, Aggregate, BatchItemOutcome, BatchItemStatus, BatchSummary,
    ColumnSchema, DataOperation, DataOperationKind, DataPlaneError,
    DataPlaneResult, DataResult, DatabaseMount, DdlColumnDef, EngineAdapter, EngineCapabilities,
    EngineHealth, EnginePool, Filter, ForeignKeyRef, MigrationRequest, MigrationResult,
    MigrationStatus, NormalizedType, RawStatement, RequestIdentity, SchemaDdlOp, SchemaDdlRequest,
    SchemaDdlResult, SchemaDdlStatus, SchemaDescriptor, TableSchema,
    TxBeginRequest, TxHandle,
};
use mysql_async::prelude::Queryable;
use mysql_async::{Conn, Opts, OptsBuilder, Params, Pool, PoolConstraints, PoolOpts, Row, TxOpts};
use mysql_async::{Column, Value as MysqlValue};
use tokio::sync::Mutex;
use serde_json::{Map as JsonMap, Value};
use std::collections::BTreeMap;
use std::sync::Arc;

/// Fields the server controls — strip from any client payload before write,
/// re-inject from the verified identity. Same defensive posture as the Mongo
/// adapter's `RESERVED_FIELDS`.
const RESERVED_COLUMNS: [&str; 1] = ["owner_id"];

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
        Self { resolver, engine_name: "mysql" }
    }

    /// Build the adapter under a specific engine id (`"mysql"` or `"mariadb"`).
    /// The dispatch and pool are identical; only `engine()` + `capabilities()`
    /// differ.
    #[must_use]
    pub fn with_engine_name(resolver: Arc<dyn MountResolver>, engine_name: &'static str) -> Self {
        Self { resolver, engine_name }
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

/// Single (non-batch) operation dispatch shared by the auto-commit and tx
/// paths — the arms `run_batch` loops over. Exhaustive by enumeration so the
/// match can't silently drift from SUPPORTED_OPS.
async fn dispatch_single(
    q: &mut impl Queryable,
    operation: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    match operation.op {
        DataOperationKind::List => run_list(q, operation, identity).await,
        DataOperationKind::Get => run_get(q, operation, identity).await,
        DataOperationKind::Insert => run_insert(q, operation, identity).await,
        DataOperationKind::Update => run_update(q, operation, identity).await,
        DataOperationKind::Delete => run_delete(q, operation, identity).await,
        DataOperationKind::Upsert => run_upsert(q, operation, identity).await,
        DataOperationKind::Aggregate => run_aggregate(q, operation, identity).await,
        DataOperationKind::Batch => Err(DataPlaneError::InvalidRequest {
            message: "nested batches are not allowed".to_string(),
        }),
    }
}

/// Atomic batch: both call sites run inside a transaction (per-request or
/// interactive), so the first failed item propagates its error and the
/// surrounding transaction is rolled back — nothing persists.
async fn run_batch(
    q: &mut impl Queryable,
    operation: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let items = operation
        .batch_items()
        .map_err(|message| DataPlaneError::InvalidRequest { message })?;
    let mut outcomes = Vec::with_capacity(items.len());
    let mut total: u64 = 0;
    for (idx, item) in items.iter().enumerate() {
        let result = dispatch_single(q, item, identity).await.map_err(|e| {
            DataPlaneError::prefix_message(&format!("batch item {idx}: "), e)
        })?;
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
        batch: Some(BatchSummary { atomic: true, items: outcomes }),
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

        let opts: Opts = OptsBuilder::from_opts(base_opts).pool_opts(pool_opts).into();
        let pool = Pool::new(opts);

        // schema_per_tenant: the engine-neutral scope directive selects a
        // per-tenant database (`USE tenant_<id>`) on every checkout. The
        // namespace is derived from the mount's tenant_id (identity-
        // independent) so it's resolved once here; `None` for shared_rls /
        // db_per_tenant → no `USE`, byte-identical to before G5.
        let namespace = resolve_namespace(&mount);
        let shared_pool = crate::pools_shared(&mount);

        Ok(Box::new(MysqlPool {
            mount_id: mount.id,
            tenant_id: mount.tenant_id,
            shared_pool,
            pool,
            namespace,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth::unknown("mysql", pool.mount_id()))
    }
}

/// A pooled MySQL connection set bound to a single mount.
pub struct MysqlPool {
    mount_id: String,
    tenant_id: String,
    /// True for a SHARE_POOLS shared_rls pool serving many tenants from one
    /// connection set: the single-owner `check_tenant` assertion is then
    /// skipped (the `owner_id` predicate from each request's identity carries
    /// isolation — `self.tenant_id` has no single value to assert). See
    /// `crate::pools_shared` and the postgres adapter.
    shared_pool: bool,
    pool: Pool,
    /// `Some("tenant_<id>")` for `schema_per_tenant` mounts: the per-tenant
    /// database selected via `USE` on every checkout. `None` (shared_rls /
    /// db_per_tenant) means no `USE` — the DSN-default database, as before G5.
    namespace: Option<String>,
}

impl MysqlPool {
    /// Defense-in-depth tenant cross-check (the dispatcher already rejected
    /// identity/mount mismatches). Skipped for a SHARE_POOLS shared_rls pool:
    /// it is multi-tenant by design and has no single owner to assert — the
    /// `owner_id` predicate from THIS request's identity (`build_owner_filter`)
    /// carries isolation, exactly as the postgres adapter relies on its
    /// per-request RLS GUCs.
    fn check_tenant(&self, identity: &RequestIdentity) -> DataPlaneResult<()> {
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

    /// Pin the per-tenant database on a freshly checked-out connection.
    ///
    /// `USE` is re-issued on EVERY checkout (never assumed sticky): pooled
    /// connections are reused, so we cannot trust the database a prior borrower
    /// left selected. It is intentionally NOT run inside the per-request
    /// transaction — `USE` is connection-level state, not transactional. The
    /// schema is pre-sanitized to `[a-z0-9_]` by `safe_schema`, so interpolating
    /// it (`USE` cannot bind parameters) is injection-safe. No-op when `None`.
    async fn select_namespace(&self, conn: &mut Conn) -> DataPlaneResult<()> {
        if let Some(schema) = self.namespace.as_deref() {
            conn.query_drop(format!("USE `{schema}`"))
                .await
                .map_err(backend)?;
        }
        Ok(())
    }
}

/// Per-tenant database name for a `schema_per_tenant` MySQL mount — delegates to
/// the single source of truth, [`DatabaseMount::resolve_namespace`].
// ponytail: thin wrapper kept so call sites read `resolve_namespace(&mount)`;
// inline + delete in a follow-up.
fn resolve_namespace(mount: &DatabaseMount) -> Option<String> {
    mount.resolve_namespace()
}

#[async_trait]
impl EnginePool for MysqlPool {
    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        // Second line of defense (the dispatcher should already have rejected
        // tenant/mount mismatches — see routes::validate_identity_mount).
        self.check_tenant(&identity)?;

        // Parity with the TS adapter: every request runs in its own
        // transaction so a multi-statement write is atomic per request even
        // before we expose multi-statement EnginePool::begin().
        let mut conn = self.pool.get_conn().await.map_err(backend)?;
        // schema_per_tenant: pin the per-tenant database before the tx opens
        // (USE is connection-level, not transactional). No-op for shared_rls.
        self.select_namespace(&mut conn).await?;
        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("mysql operation {:?}", operation.op),
            });
        }
        let mut tx = conn
            .start_transaction(TxOpts::default())
            .await
            .map_err(backend)?;

        // Batch rides the same per-request transaction every other op gets,
        // so a poisoned item rolls the whole batch back (atomic).
        let result = match operation.op {
            DataOperationKind::Batch => run_batch(&mut tx, &operation, &identity).await,
            _ => dispatch_single(&mut tx, &operation, &identity).await,
        };

        match result {
            Ok(data) => {
                tx.commit().await.map_err(backend)?;
                Ok(data)
            }
            Err(e) => {
                // Best-effort rollback; we keep the original error.
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    async fn begin(&self, request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        // Multi-statement transaction: check out a conn, set isolation if
        // requested, then `START TRANSACTION`. Conn stays pinned inside the
        // returned handle until commit / rollback drops it back to the pool.
        let mut conn = self.pool.get_conn().await.map_err(backend)?;
        // Pin the per-tenant database before the transaction begins.
        self.select_namespace(&mut conn).await?;
        if let Some(level) = request.isolation.as_ref() {
            let sql = match level {
                data_plane_core::IsolationLevel::ReadCommitted => {
                    "SET TRANSACTION ISOLATION LEVEL READ COMMITTED"
                }
                data_plane_core::IsolationLevel::RepeatableRead => {
                    "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"
                }
                data_plane_core::IsolationLevel::Serializable => {
                    "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
                }
                // MySQL has no native snapshot iso; fall back to RR.
                data_plane_core::IsolationLevel::Snapshot => {
                    "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"
                }
            };
            conn.query_drop(sql).await.map_err(backend)?;
        }
        conn.query_drop("START TRANSACTION").await.map_err(backend)?;

        let tx_id = uuid::Uuid::now_v7().to_string();
        Ok(Box::new(MysqlTxHandle {
            tx_id,
            mount_id: self.mount_id.clone(),
            // Bind the txn to the tenant that BEGAN it — not the pool's opener,
            // which differs under SHARE_POOLS. On a per-tenant pool this is
            // byte-identical (the dispatcher guarantees identity == pool tenant);
            // on a shared pool it is the only correct owner of this transaction.
            tenant_id: request.identity.tenant_id.clone(),
            conn: Mutex::new(Some(conn)),
        }))
    }

    async fn close(&self) -> DataPlaneResult<()> {
        // `mysql_async::Pool::disconnect` consumes the pool but Pool is a cheap
        // Arc so cloning is fine; outstanding connections drop independently.
        let pool = self.pool.clone();
        pool.disconnect().await.map_err(|e| DataPlaneError::Backend {
            message: format!("mysql pool disconnect failed: {e}"),
        })
    }

    async fn execute_raw(
        &self,
        statement: RawStatement,
        _identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let mut conn = self.pool.get_conn().await.map_err(backend)?;
        self.select_namespace(&mut conn).await?;
        let params: Vec<MysqlValue> = statement.params.iter().map(json_to_mysql_value).collect();
        if statement.expect_rows {
            let rows: Vec<Row> = conn
                .exec(statement.statement.as_str(), Params::Positional(params))
                .await
                .map_err(backend)?;
            let data: Vec<Value> = rows.into_iter().map(row_to_json).collect();
            let affected = data.len() as u64;
            Ok(DataResult::new(data, affected))
        } else {
            conn.exec_drop(statement.statement.as_str(), Params::Positional(params))
                .await
                .map_err(backend)?;
            Ok(DataResult::new(vec![], conn.affected_rows()))
        }
    }

    /// Apply a named migration, recording it in `_baas_migrations` so the same
    /// name is skipped on re-application. This makes the advertised `ddl: true`
    /// honest for the `/v1/admin/migrate` route (postgres already implements it).
    ///
    /// **Atomicity caveat:** MySQL performs an *implicit commit* on every DDL
    /// statement (CREATE/ALTER/DROP), so — unlike Postgres' transactional DDL —
    /// the statement batch is **not** all-or-nothing; each DDL self-commits. The
    /// marker row still guarantees idempotency (a re-run is `Skipped`), and DML-
    /// only migrations remain effectively atomic. We therefore do not wrap the
    /// batch in a transaction that DDL would silently break.
    ///
    /// **Security (H2) — `CREATE DATABASE` blast radius / credential split:**
    /// for `schema_per_tenant`, this path issues `CREATE DATABASE IF NOT EXISTS`
    /// (below), which needs a *server-wide* `CREATE` privilege. That is a much
    /// larger blast radius than the request path needs. This is acceptable ONLY
    /// because `apply_migration` is admin/control-plane gated (the route requires
    /// `service_role`/`admin`), but the migrate-time credential SHOULD be a
    /// SEPARATE, elevated credential from the request-path runtime credential,
    /// which needs only DML + `USE` on the already-provisioned tenant DB (never
    /// `CREATE DATABASE`). Provisioning the tenant DB ideally moves OUT of the
    /// data plane entirely into the Go control plane (G2), so the runtime data
    /// plane never holds a server-wide `CREATE` grant at all. Control-plane
    /// follow-up — do not widen the runtime credential to cover this.
    async fn apply_migration(
        &self,
        request: MigrationRequest,
        _identity: RequestIdentity,
    ) -> DataPlaneResult<MigrationResult> {
        let mut conn = self.pool.get_conn().await.map_err(backend)?;
        // schema_per_tenant: create + select the per-tenant database so the
        // marker table and every migration statement land there. `schema` is
        // pre-sanitized to `[a-z0-9_]`, so interpolation is injection-safe.
        // No-op for shared_rls / db_per_tenant (DSN-default db, parity).
        if let Some(schema) = self.namespace.as_deref() {
            conn.query_drop(format!("CREATE DATABASE IF NOT EXISTS `{schema}`"))
                .await
                .map_err(backend)?;
            conn.query_drop(format!("USE `{schema}`"))
                .await
                .map_err(backend)?;
        }
        conn.query_drop(
            "CREATE TABLE IF NOT EXISTS `_baas_migrations` (\
               name VARCHAR(255) PRIMARY KEY, \
               applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP)",
        )
        .await
        .map_err(backend)?;
        let already: Option<u8> = conn
            .exec_first(
                "SELECT 1 FROM `_baas_migrations` WHERE name = ?",
                (request.name.as_str(),),
            )
            .await
            .map_err(backend)?;
        if already.is_some() {
            return Ok(MigrationResult {
                name: request.name,
                status: MigrationStatus::Skipped,
                statements_run: 0,
            });
        }
        let mut run = 0u32;
        for stmt in &request.statements {
            conn.query_drop(stmt).await.map_err(backend)?;
            run += 1;
        }
        conn.exec_drop(
            "INSERT INTO `_baas_migrations` (name) VALUES (?)",
            (request.name.as_str(),),
        )
        .await
        .map_err(backend)?;
        Ok(MigrationResult {
            name: request.name,
            status: MigrationStatus::Applied,
            statements_run: run,
        })
    }

    /// Engine-agnostic schema introspection (M22). Reads
    /// `information_schema.COLUMNS` (+ `KEY_COLUMN_USAGE` for PK/FK), scoped to
    /// the database the connection is on (`TABLE_SCHEMA = DATABASE()`): a
    /// `schema_per_tenant` mount introspects its per-tenant database (pinned by
    /// `select_namespace`, same as the request path); shared_rls /
    /// db_per_tenant introspect the DSN-default database. Excludes the
    /// `_baas_migrations` marker table.
    async fn describe_schema(
        &self,
        identity: RequestIdentity,
    ) -> DataPlaneResult<SchemaDescriptor> {
        self.check_tenant(&identity)?;
        let mut conn = self.pool.get_conn().await.map_err(backend)?;
        self.select_namespace(&mut conn).await?;

        // Primary keys, per table, in key ordinal order.
        let pk_rows: Vec<(String, String)> = conn
            .query(
                "SELECT TABLE_NAME, COLUMN_NAME \
                 FROM information_schema.KEY_COLUMN_USAGE \
                 WHERE TABLE_SCHEMA = DATABASE() AND CONSTRAINT_NAME = 'PRIMARY' \
                 ORDER BY TABLE_NAME, ORDINAL_POSITION",
            )
            .await
            .map_err(backend)?;
        let mut pks: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for (table, column) in pk_rows {
            pks.entry(table).or_default().push(column);
        }

        // Foreign keys: (table, column) → referenced (table, column).
        let fk_rows: Vec<(String, String, String, String)> = conn
            .query(
                "SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME \
                 FROM information_schema.KEY_COLUMN_USAGE \
                 WHERE TABLE_SCHEMA = DATABASE() AND REFERENCED_TABLE_NAME IS NOT NULL",
            )
            .await
            .map_err(backend)?;
        let mut fks: BTreeMap<(String, String), ForeignKeyRef> = BTreeMap::new();
        for (table, column, ref_table, ref_column) in fk_rows {
            fks.insert((table, column), ForeignKeyRef { table: ref_table, column: ref_column });
        }

        // Columns of every BASE TABLE on the connected database.
        let col_rows: Vec<(String, String, String, String, Option<String>)> = conn
            .query(
                "SELECT c.TABLE_NAME, c.COLUMN_NAME, c.COLUMN_TYPE, c.IS_NULLABLE, c.COLUMN_DEFAULT \
                 FROM information_schema.COLUMNS c \
                 JOIN information_schema.TABLES t \
                   ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME \
                 WHERE c.TABLE_SCHEMA = DATABASE() \
                   AND t.TABLE_TYPE = 'BASE TABLE' \
                   AND c.TABLE_NAME <> '_baas_migrations' \
                 ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION",
            )
            .await
            .map_err(backend)?;
        let mut tables: BTreeMap<String, Vec<ColumnSchema>> = BTreeMap::new();
        for (table, name, column_type, is_nullable, default) in col_rows {
            let (normalized_type, enum_values) = normalize_mysql_type(&column_type);
            let references = fks.get(&(table.clone(), name.clone())).cloned();
            tables.entry(table).or_default().push(ColumnSchema {
                name,
                native_type: column_type,
                normalized_type,
                nullable: is_nullable.eq_ignore_ascii_case("yes"),
                default,
                enum_values,
                references,
                inferred: false,
            });
        }

        Ok(SchemaDescriptor {
            engine: "mysql".to_string(),
            tables: tables
                .into_iter()
                .map(|(name, columns)| TableSchema {
                    primary_key: pks.remove(&name).unwrap_or_default(),
                    name,
                    columns,
                })
                .collect(),
        })
    }

    /// Engine-agnostic schema DDL (M22 step 2). Lowered to ONE statement by
    /// the pure [`build_mysql_ddl`] builder and executed on the same
    /// namespace the request path uses (`select_namespace` pins the
    /// per-tenant database for schema_per_tenant; DSN-default otherwise).
    /// MySQL DDL is auto-commit — exactly why the contract is single-op:
    /// there is no multi-statement atomicity to fake. Unlike the admin-gated
    /// `apply_migration`, this path never issues `CREATE DATABASE`: a
    /// schema_per_tenant namespace must already be provisioned.
    async fn apply_schema_ddl(
        &self,
        ddl: SchemaDdlRequest,
        identity: RequestIdentity,
    ) -> DataPlaneResult<SchemaDdlResult> {
        self.check_tenant(&identity)?;
        let stmt = build_mysql_ddl(&ddl)?;
        let mut conn = self.pool.get_conn().await.map_err(backend)?;
        self.select_namespace(&mut conn).await?;
        conn.query_drop(stmt).await.map_err(ddl_backend)?;
        Ok(SchemaDdlResult {
            op: ddl.op,
            table: ddl.table,
            status: SchemaDdlStatus::Applied,
        })
    }
}

/// Maps a MySQL `COLUMN_TYPE` (the full rendered type, e.g. `varchar(255)`,
/// `enum('a','b')`, `tinyint(1) unsigned`) to the engine-neutral
/// [`NormalizedType`], returning the parsed enum labels for `enum(...)` types.
/// Pure — testable without a DB.
pub(crate) fn normalize_mysql_type(column_type: &str) -> (NormalizedType, Option<Vec<String>>) {
    let lower = column_type.trim().to_ascii_lowercase();
    if lower.starts_with("enum(") {
        return (NormalizedType::Enum, Some(parse_mysql_enum_values(column_type)));
    }
    // `tinyint(1)` (the MySQL boolean convention) before the generic int arm.
    if lower == "tinyint(1)" || lower.starts_with("tinyint(1) ") {
        return (NormalizedType::Boolean, None);
    }
    let base = lower.split(['(', ' ']).next().unwrap_or("");
    let ty = match base {
        "int" | "integer" | "bigint" | "smallint" | "mediumint" | "tinyint" => {
            NormalizedType::Integer
        }
        "float" | "double" => NormalizedType::Float,
        "decimal" | "numeric" => NormalizedType::Decimal,
        "date" => NormalizedType::Date,
        "datetime" | "timestamp" => NormalizedType::Datetime,
        "json" => NormalizedType::Json,
        "char" | "varchar" | "text" | "tinytext" | "mediumtext" | "longtext" => {
            NormalizedType::Text
        }
        _ => NormalizedType::Unknown,
    };
    (ty, None)
}

// ── M22 step 2: engine-agnostic schema DDL (pure SQL builders) ───────────────
//
// Pure (testable without a DB). Identifiers via `quote_mysql_ident`; enum
// VALUES are escaped string literals (`mysql_literal`, which doubles quotes
// AND escapes backslash — MySQL's default sql_mode treats `\` as an escape);
// caller DEFAULT expressions pass the shared `validate_default_expr` guard.

/// `'…'`-quoted MySQL string literal.
fn mysql_literal(value: &str) -> String {
    format!("'{}'", value.replace('\\', "\\\\").replace('\'', "''"))
}

/// Reverse type mapping (the inverse of [`normalize_mysql_type`]): lowers a
/// [`DdlColumnDef`] to its MySQL column type SQL. `in_primary_key` switches
/// text to `VARCHAR(255)` — `TEXT` cannot be a PK without a prefix length.
/// `objectid`/`unknown` are describe-only and rejected.
pub(crate) fn mysql_sql_type(def: &DdlColumnDef, in_primary_key: bool) -> DataPlaneResult<String> {
    Ok(match def.normalized_type {
        NormalizedType::Text => {
            if in_primary_key { "VARCHAR(255)".to_string() } else { "TEXT".to_string() }
        }
        NormalizedType::Integer => "BIGINT".to_string(),
        NormalizedType::Float => "DOUBLE".to_string(),
        NormalizedType::Decimal => "DECIMAL(18,6)".to_string(),
        NormalizedType::Boolean => "TINYINT(1)".to_string(),
        NormalizedType::Date => "DATE".to_string(),
        NormalizedType::Datetime => "DATETIME".to_string(),
        NormalizedType::Json => "JSON".to_string(),
        NormalizedType::Uuid => "CHAR(36)".to_string(),
        // v1: arrays land in JSON (MySQL has no array type).
        NormalizedType::Array => "JSON".to_string(),
        NormalizedType::Enum => {
            let values = def
                .enum_values
                .as_deref()
                .filter(|v| !v.is_empty())
                .ok_or_else(|| DataPlaneError::InvalidRequest {
                    message: format!("enum column '{}' requires non-empty enum_values", def.name),
                })?;
            let literals: Vec<String> = values.iter().map(|v| mysql_literal(v)).collect();
            format!("ENUM({})", literals.join(", "))
        }
        NormalizedType::Objectid | NormalizedType::Unknown => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!(
                    "column '{}': normalized_type '{:?}' cannot be created on mysql",
                    def.name, def.normalized_type
                ),
            })
        }
    })
}

/// One full column clause: `` `name` TYPE NULL|NOT NULL [DEFAULT expr] ``.
/// Nullability is ALWAYS rendered (`NULL` explicitly) because `MODIFY COLUMN`
/// resets every attribute — the caller sends the full target def precisely so
/// nothing is silently lost.
fn mysql_column_clause(def: &DdlColumnDef, in_primary_key: bool) -> DataPlaneResult<String> {
    let col = quote_mysql_ident(&def.name)?;
    let ty = mysql_sql_type(def, in_primary_key)?;
    let mut clause = format!("{col} {ty} {}", if def.nullable { "NULL" } else { "NOT NULL" });
    if let Some(default) = def.default.as_deref() {
        validate_default_expr(default)?;
        clause.push_str(&format!(" DEFAULT {default}"));
    }
    Ok(clause)
}

/// Lowers a [`SchemaDdlRequest`] to its single MySQL DDL statement
/// (namespace selection happens at the connection via `USE`, mirroring the
/// request path, so statements stay unqualified).
pub(crate) fn build_mysql_ddl(ddl: &SchemaDdlRequest) -> DataPlaneResult<String> {
    let table = quote_mysql_ident(&ddl.table)?;
    Ok(match ddl.op {
        SchemaDdlOp::AddColumn => format!(
            "ALTER TABLE {table} ADD COLUMN {}",
            mysql_column_clause(ddl.require_column()?, false)?
        ),
        SchemaDdlOp::DropColumn => format!(
            "ALTER TABLE {table} DROP COLUMN {}",
            quote_mysql_ident(ddl.require_column_name()?)?
        ),
        // MODIFY COLUMN resets attributes — full target def by contract.
        SchemaDdlOp::AlterColumnType => format!(
            "ALTER TABLE {table} MODIFY COLUMN {}",
            mysql_column_clause(ddl.require_column()?, false)?
        ),
        SchemaDdlOp::CreateTable => {
            let (columns, primary_key) = ddl.require_create_spec()?;
            let pk_set: std::collections::BTreeSet<&str> =
                primary_key.iter().map(String::as_str).collect();
            let mut clauses = Vec::with_capacity(columns.len() + 2);
            let mut has_owner = false;
            for def in columns {
                if def.name == "owner_id" {
                    has_owner = true;
                }
                clauses.push(mysql_column_clause(def, pk_set.contains(def.name.as_str()))?);
            }
            if !has_owner {
                // The MySQL adapter owner-scopes every read/write on owner_id
                // — a table without the column would fail its first request.
                // VARCHAR(64), not CHAR(36): API-key principals are the
                // synthetic `api-key:<uuid>` string (44 chars), not a uuid.
                clauses.push(format!("{} VARCHAR(64)", quote_mysql_ident("owner_id")?));
            }
            let pk: Vec<String> = primary_key
                .iter()
                .map(|c| quote_mysql_ident(c))
                .collect::<DataPlaneResult<_>>()?;
            clauses.push(format!("PRIMARY KEY ({})", pk.join(", ")));
            format!("CREATE TABLE {table} ({})", clauses.join(", "))
        }
        SchemaDdlOp::DropTable => format!("DROP TABLE {table}"),
    })
}

/// Parses the labels out of a MySQL `enum('a','b','it''s')` COLUMN_TYPE.
/// Handles the `''` escape for a literal quote. Pure helper for
/// [`normalize_mysql_type`].
fn parse_mysql_enum_values(column_type: &str) -> Vec<String> {
    let inner = column_type
        .find('(')
        .and_then(|start| column_type.rfind(')').map(|end| &column_type[start + 1..end]))
        .unwrap_or("");
    let mut values = Vec::new();
    let mut current = String::new();
    let mut in_quote = false;
    let mut chars = inner.chars().peekable();
    while let Some(c) = chars.next() {
        if in_quote {
            if c == '\'' {
                if chars.peek() == Some(&'\'') {
                    current.push('\'');
                    chars.next();
                } else {
                    in_quote = false;
                    values.push(std::mem::take(&mut current));
                }
            } else {
                current.push(c);
            }
        } else if c == '\'' {
            in_quote = true;
        }
        // Anything outside quotes (commas, spaces) is a separator — skipped.
    }
    values
}

/// Pinned MySQL transaction. Holds the checked-out connection across
/// execute calls; releases it when commit/rollback consumes the handle.
///
/// `conn` is `Option<Conn>` inside the Mutex so commit/rollback can take
/// ownership and drop the Conn (the deadpool reclaim happens on drop).
pub struct MysqlTxHandle {
    tx_id: String,
    mount_id: String,
    tenant_id: String,
    conn: Mutex<Option<Conn>>,
}

#[async_trait]
impl TxHandle for MysqlTxHandle {
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
        if identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match transaction tenant".into(),
            });
        }
        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("mysql operation {:?}", operation.op),
            });
        }
        let mut guard = self.conn.lock().await;
        let conn = guard.as_mut().ok_or_else(|| DataPlaneError::Backend {
            message: "mysql tx already finalised".into(),
        })?;
        // Inside an interactive transaction a failed batch item poisons the
        // tx like any failed statement — the caller decides commit/rollback.
        match operation.op {
            DataOperationKind::Batch => run_batch(conn, &operation, &identity).await,
            _ => dispatch_single(conn, &operation, &identity).await,
        }
    }

    async fn commit(&self) -> DataPlaneResult<()> {
        let mut guard = self.conn.lock().await;
        let mut conn = guard.take().ok_or_else(|| DataPlaneError::Backend {
            message: "mysql tx already finalised".into(),
        })?;
        conn.query_drop("COMMIT").await.map_err(backend)?;
        // Drop returns the Conn to the pool.
        drop(conn);
        Ok(())
    }

    async fn rollback(&self) -> DataPlaneResult<()> {
        let mut guard = self.conn.lock().await;
        if let Some(mut conn) = guard.take() {
            // Best-effort; if the connection is already aborted, ROLLBACK is
            // a no-op on the wire.
            let _ = conn.query_drop("ROLLBACK").await;
            drop(conn);
        }
        Ok(())
    }

    async fn prepare(&self) -> DataPlaneResult<()> {
        Err(DataPlaneError::NotImplemented {
            feature: "mysql XA PREPARE (2PC)".to_string(),
        })
    }
}

// ── operation implementations ───────────────────────────────────────────────

async fn run_list(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), identity)?;
    let order_sql = build_order_by(op.sort.as_ref())?;
    let limit = op.limit.unwrap_or(100).min(500);
    let offset = op.offset.unwrap_or(0);

    let sql = format!(
        "SELECT * FROM {table}{where_sql}{order_sql} LIMIT {limit} OFFSET {offset}"
    );
    let rows: Vec<Row> = q
        .exec(sql.as_str(), Params::Positional(params))
        .await
        .map_err(backend)?;

    let data: Vec<Value> = rows.into_iter().map(row_to_json).collect();
    let affected = data.len() as u64;
    Ok(DataResult::new(data, affected))
}

async fn run_get(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), identity)?;

    let sql = format!("SELECT * FROM {table}{where_sql} LIMIT 1");
    let row: Option<Row> = q
        .exec_first(sql.as_str(), Params::Positional(params))
        .await
        .map_err(backend)?;

    let (rows, affected) = match row {
        Some(r) => (vec![row_to_json(r)], 1),
        None => (vec![], 0),
    };
    Ok(DataResult::new(rows, affected))
}

async fn run_insert(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let columns = build_owned_columns(op.data.as_ref(), identity)?;
    if columns.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "insert `data` must not be empty".to_string(),
        });
    }

    let frags = render_insert_columns(&columns)?;
    let sql = format!(
        "INSERT INTO {table} ({col_sql}) VALUES ({placeholders})",
        col_sql = frags.columns_sql,
        placeholders = frags.placeholders
    );
    let echo = frags.echo;
    // exec_iter so we can read affected_rows + last_insert_id off the
    // QueryResult — the Queryable trait doesn't surface those on `q`.
    let result = q
        .exec_iter(sql.as_str(), Params::Positional(frags.params))
        .await
        .map_err(backend)?;
    let last_id = result.last_insert_id();
    result.drop_result().await.map_err(backend)?;

    // Match the TS adapter: return the enriched payload plus the auto-id.
    let mut out = echo;
    if let Some(id) = last_id {
        out.insert("id".to_string(), Value::Number(id.into()));
    }
    Ok(DataResult::new(vec![Value::Object(out)], 1))
}

async fn run_update(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    crate::sql_scope::guard_constraining_filter(op.filter.as_ref(), &RESERVED_COLUMNS)?;
    // Server-controlled fields must not be UPDATE-able from the client.
    let set_cols = build_safe_columns(op.data.as_ref())?;
    if set_cols.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "update `data` must not be empty".to_string(),
        });
    }

    let mut params: Vec<MysqlValue> = Vec::with_capacity(set_cols.len());
    let mut set_parts = Vec::with_capacity(set_cols.len());
    for (col, val) in &set_cols {
        let quoted = quote_mysql_ident(col)?;
        set_parts.push(format!("{quoted} = ?"));
        params.push(json_to_mysql_value(val));
    }

    let (where_sql, mut where_params) = build_owner_filter(op.filter.as_ref(), identity)?;
    params.append(&mut where_params);

    let sql = format!(
        "UPDATE {table} SET {set}{where_sql}",
        set = set_parts.join(", ")
    );
    let result = q
        .exec_iter(sql.as_str(), Params::Positional(params))
        .await
        .map_err(backend)?;
    let affected = result.affected_rows();
    result.drop_result().await.map_err(backend)?;
    Ok(DataResult::new(vec![], affected))
}

async fn run_delete(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    crate::sql_scope::guard_constraining_filter(op.filter.as_ref(), &RESERVED_COLUMNS)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), identity)?;

    let sql = format!("DELETE FROM {table}{where_sql}");
    let result = q
        .exec_iter(sql.as_str(), Params::Positional(params))
        .await
        .map_err(backend)?;
    let affected = result.affected_rows();
    result.drop_result().await.map_err(backend)?;
    Ok(DataResult::new(vec![], affected))
}

async fn run_upsert(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let columns = build_owned_columns(op.data.as_ref(), identity)?;
    if columns.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert `data` must not be empty".to_string(),
        });
    }

    let frags = render_insert_columns(&columns)?;
    // SAFETY (cross-owner hijack): `ON DUPLICATE KEY UPDATE` fires on ANY
    // unique-key collision — including a row owned by a DIFFERENT principal
    // (MySQL cannot scope the arbitration the way PG's ON CONFLICT target
    // does). So when the platform owner-stamps rows we (a) never reassign
    // `owner_id` in the update branch, and (b) guard every column with
    // `IF(owner_id = VALUES(owner_id), new, old)`: a collision with a foreign
    // owner's row becomes a no-op instead of overwriting (and stealing) it.
    // `owner_id` is platform-injected by `build_owned_columns` (client copies
    // are stripped first), so its presence == owner-scoped mount.
    let owner_scoped = columns.iter().any(|(col, _)| col == "owner_id");
    let mut update_parts = Vec::with_capacity(columns.len());
    for (col, _) in &columns {
        if owner_scoped && col == "owner_id" {
            continue;
        }
        let quoted = quote_mysql_ident(col)?;
        if owner_scoped {
            update_parts.push(format!(
                "{quoted} = IF(`owner_id` = VALUES(`owner_id`), VALUES({quoted}), {quoted})"
            ));
        } else {
            update_parts.push(format!("{quoted} = VALUES({quoted})"));
        }
    }
    if update_parts.is_empty() {
        // owner_id was the only column: make the duplicate branch a no-op.
        update_parts.push("`owner_id` = `owner_id`".to_string());
    }
    let sql = format!(
        "INSERT INTO {table} ({col_sql}) VALUES ({placeholders}) \
         ON DUPLICATE KEY UPDATE {update_sql}",
        col_sql = frags.columns_sql,
        placeholders = frags.placeholders,
        update_sql = update_parts.join(", ")
    );
    let echo = frags.echo;
    let result = q
        .exec_iter(sql.as_str(), Params::Positional(frags.params))
        .await
        .map_err(backend)?;
    let affected = result.affected_rows();
    let last_id = result.last_insert_id();
    result.drop_result().await.map_err(backend)?;
    let mut out = echo;
    if let Some(id) = last_id {
        out.insert("id".to_string(), Value::Number(id.into()));
    }
    Ok(DataResult::new(vec![Value::Object(out)], affected))
}

/// Grouped aggregation, mirroring the Postgres lowering:
/// `SELECT <group cols>, <agg exprs> FROM t WHERE <owner ∩ filter>
/// [GROUP BY <group cols>] [ORDER BY …] LIMIT n`.
/// Reads are owner-scoped server-side here (MySQL has no RLS), so the owner
/// predicate is intersected exactly like `run_list`. **Safety:** every
/// identifier goes through `quote_mysql_ident`; the function name comes from
/// the allowlisted [`AggFunc`] enum, never client text.
async fn run_aggregate(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let spec = op
        .aggregate
        .as_ref()
        .ok_or_else(|| DataPlaneError::InvalidRequest {
            message: "aggregate requires an `aggregate` spec".to_string(),
        })?;
    if spec.aggregates.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "aggregate requires at least one aggregate function".to_string(),
        });
    }
    // Output column names must be unique or the row JSON would drop one.
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

    let mut select_cols: Vec<String> =
        Vec::with_capacity(spec.group_by.len() + spec.aggregates.len());
    let mut group_cols: Vec<String> = Vec::with_capacity(spec.group_by.len());
    for col in &spec.group_by {
        let ident = quote_mysql_ident(col)?;
        select_cols.push(ident.clone());
        group_cols.push(ident);
    }
    for agg in &spec.aggregates {
        select_cols.push(build_mysql_aggregate_expr(agg)?);
    }

    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), identity)?;
    let group_sql = if group_cols.is_empty() {
        String::new()
    } else {
        format!(" GROUP BY {}", group_cols.join(", "))
    };
    let order_sql = build_order_by(op.sort.as_ref())?;
    let limit = op.limit.unwrap_or(1000).min(10_000);

    let sql = format!(
        "SELECT {cols} FROM {table}{where_sql}{group_sql}{order_sql} LIMIT {limit}",
        cols = select_cols.join(", ")
    );
    let rows: Vec<Row> = q
        .exec(sql.as_str(), Params::Positional(params))
        .await
        .map_err(backend)?;
    let data: Vec<Value> = rows.into_iter().map(row_to_json).collect();
    let affected = data.len() as u64;
    Ok(DataResult::new(data, affected))
}

/// One `func(arg) AS alias` expression — same contract as the PG builder:
/// `count` with no field is `COUNT(*)`; everything else requires a field;
/// `distinct` requires a field.
fn build_mysql_aggregate_expr(agg: &Aggregate) -> DataPlaneResult<String> {
    let alias = quote_mysql_ident(&agg.alias)?;
    let func = match agg.func {
        AggFunc::Count => "COUNT",
        AggFunc::Sum => "SUM",
        AggFunc::Avg => "AVG",
        AggFunc::Min => "MIN",
        AggFunc::Max => "MAX",
    };
    let arg = match (&agg.field, agg.func) {
        (Some(field), _) => quote_mysql_ident(field)?,
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

// ── shared helpers ──────────────────────────────────────────────────────────

fn backend<E: std::fmt::Display>(e: E) -> DataPlaneError {
    classify_mysql_error(format!("mysql backend: {e}"), false)
}

/// DDL-path variant of [`backend`]: additionally maps the "existing data is
/// incompatible with the new type" server errors raised by `MODIFY COLUMN`
/// — 1265 "Data truncated", 1366 "Incorrect <type> value", 1292 "Truncated
/// incorrect <type> value" — to a 409 Conflict. Scoped to the DDL path only
/// (additive): the query path keeps [`backend`]'s existing mapping.
fn ddl_backend<E: std::fmt::Display>(e: E) -> DataPlaneError {
    classify_mysql_error(format!("mysql backend: {e}"), true)
}

/// Best-effort integrity-violation detection from the server message (the
/// generic helper only has the Display text): 1062 "Duplicate entry", 1452
/// foreign-key failure → a client error (409 Conflict), not an engine 5xx.
/// Truncation/cast errors (1265/1292/1366 — bad enum value, unparseable
/// date) and 1264 "Out of range" classify as Conflict on BOTH paths: on DDL
/// they mean the table's data conflicts with the requested type, on writes
/// they mean the caller's VALUE doesn't fit the column — either way the
/// caller's fault, and a 5xx would make outbox clients retry a write that
/// can never succeed.
fn classify_mysql_error(message: String, ddl: bool) -> DataPlaneError {
    let lower = message.to_lowercase();
    if lower.contains("duplicate entry") || lower.contains("foreign key constraint fails") {
        return DataPlaneError::Conflict { message };
    }
    if lower.contains("data truncated")
        || lower.contains("truncated incorrect")
        || lower.contains("out of range value")
        || (lower.contains("incorrect") && lower.contains("value"))
    {
        return DataPlaneError::Conflict { message };
    }
    if ddl {
        // Schema-shape mistakes are deterministic client errors — a 5xx makes
        // outbox-style clients retry a request that can never succeed.
        // 1060 "Duplicate column name" / 1050 "Table … already exists" → 409;
        // 1054 "Unknown column" / 1091 "Can't DROP …; check that column/key
        // exists" / 1146 "Table … doesn't exist" → 400.
        if lower.contains("duplicate column name") || lower.contains("already exists") {
            return DataPlaneError::Conflict { message };
        }
        if lower.contains("unknown column")
            || lower.contains("check that column/key exists")
            || lower.contains("doesn't exist")
        {
            return DataPlaneError::InvalidRequest { message };
        }
    }
    DataPlaneError::Backend { message }
}

fn owner_of(identity: &RequestIdentity) -> String {
    identity.owner_principal().to_string()
}

/// MySQL binds every value as a positional `?` (param order IS binding order),
/// so the shared filter lowerer pushes through this private sink:
/// `bind` records the value via [`json_to_mysql_value`] and emits `?`;
/// `quote_ident` defers to [`quote_mysql_ident`]. Kept private (never `pub`) so
/// no caller can bypass `bind` and bind a value to the wrong column.
struct MysqlSink(Vec<MysqlValue>);

impl crate::sql_scope::SqlParamSink for MysqlSink {
    fn bind(&mut self, value: &Value) -> String {
        self.0.push(json_to_mysql_value(value));
        "?".to_string()
    }
    fn quote_ident(&self, name: &str) -> DataPlaneResult<String> {
        quote_mysql_ident(name)
    }
}

/// Take the client filter, strip any attempt to override `owner_id`, then
/// intersect with the server-trusted owner. Always returns a `WHERE` clause
/// that includes `owner_id = ?` (the second line of defense against tenant
/// escape — defense in depth alongside per-mount DSN isolation). The
/// engine-neutral filter lowering lives in [`crate::sql_scope`]; only the
/// `owner_id` stamping below is MySQL-specific.
fn build_owner_filter(
    filter: Option<&Value>,
    identity: &RequestIdentity,
) -> DataPlaneResult<(String, Vec<MysqlValue>)> {
    let mut sink = MysqlSink(Vec::new());
    let mut clauses: Vec<String> = Vec::new();

    if let Some(filter_value) = filter {
        // Drop any top-level reserved-column override (the trusted value is added
        // below) before parsing, matching the prior posture. The trusted
        // `owner_id` predicate also supersedes any nested client `owner_id`.
        let cleaned = crate::sql_scope::strip_reserved_top_level(filter_value, &RESERVED_COLUMNS);
        let tree = Filter::parse(&cleaned)?;
        if let Some(sql) = crate::sql_scope::lower_filter(&tree, &mut sink)? {
            // Parenthesize the WHOLE client filter so the trusted `owner_id` AND
            // binds it as one unit. Without this, a top-level `$or` would parse
            // as `(a) OR (b AND owner_id)` — the `a` branch unscoped (cross-owner
            // leak), because SQL `AND` binds tighter than `OR`.
            clauses.push(format!("({sql})"));
        }
    }

    // Always inject the trusted owner predicate.
    sink.0.push(MysqlValue::Bytes(owner_of(identity).into_bytes()));
    clauses.push("`owner_id` = ?".to_string());

    Ok((format!(" WHERE {}", clauses.join(" AND ")), sink.0))
}

/// Strip reserved columns from client payload, then re-inject the trusted
/// `owner_id`. Returns the ordered list of (column, value) pairs and is the
/// shared core of `INSERT` and `UPSERT`.
fn build_owned_columns(
    data: Option<&Value>,
    identity: &RequestIdentity,
) -> DataPlaneResult<Vec<(String, Value)>> {
    let map = require_object(data, "data")?;
    let mut columns: Vec<(String, Value)> = Vec::with_capacity(map.len() + 1);
    for (col, val) in map {
        if RESERVED_COLUMNS.contains(&col.as_str()) {
            continue;
        }
        columns.push((col.clone(), val.clone()));
    }
    columns.push((
        "owner_id".to_string(),
        Value::String(owner_of(identity)),
    ));
    Ok(columns)
}

/// Same shape as `build_owned_columns` but for UPDATE — drops reserved
/// columns from the SET list without re-injecting (UPDATE doesn't need to
/// re-set `owner_id`; the WHERE clause already scopes the row).
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

fn require_object<'a>(
    data: Option<&'a Value>,
    what: &str,
) -> DataPlaneResult<&'a JsonMap<String, Value>> {
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

/// Rendered SQL fragments + ordered bind parameters + the echo payload that
/// the adapter returns to the caller. Avoids a 4-tuple return that clippy
/// flags as `type_complexity`.
struct InsertSqlFragments {
    columns_sql: String,
    placeholders: String,
    params: Vec<MysqlValue>,
    echo: JsonMap<String, Value>,
}

fn render_insert_columns(columns: &[(String, Value)]) -> DataPlaneResult<InsertSqlFragments> {
    let mut col_sql: Vec<String> = Vec::with_capacity(columns.len());
    let mut placeholders: Vec<&'static str> = Vec::with_capacity(columns.len());
    let mut params: Vec<MysqlValue> = Vec::with_capacity(columns.len());
    let mut echo = JsonMap::with_capacity(columns.len());
    for (col, val) in columns {
        let quoted = quote_mysql_ident(col)?;
        col_sql.push(quoted);
        placeholders.push("?");
        params.push(json_to_mysql_value(val));
        echo.insert(col.clone(), val.clone());
    }
    Ok(InsertSqlFragments {
        columns_sql: col_sql.join(", "),
        placeholders: placeholders.join(", "),
        params,
        echo,
    })
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
        let quoted = quote_mysql_ident(col)?;
        let dir_sql = if dir.eq_ignore_ascii_case("desc") {
            "DESC"
        } else {
            "ASC"
        };
        parts.push(format!("{quoted} {dir_sql}"));
    }
    Ok(format!(" ORDER BY {}", parts.join(", ")))
}

fn json_to_mysql_value(v: &Value) -> MysqlValue {
    match v {
        Value::Null => MysqlValue::NULL,
        Value::Bool(b) => MysqlValue::Int(i64::from(*b)),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                MysqlValue::Int(i)
            } else if let Some(u) = n.as_u64() {
                MysqlValue::UInt(u)
            } else {
                MysqlValue::Double(n.as_f64().unwrap_or(0.0))
            }
        }
        Value::String(s) => MysqlValue::Bytes(s.clone().into_bytes()),
        // Arrays + objects become JSON strings — MySQL 5.7+ has a JSON type
        // that accepts string literals.
        other => MysqlValue::Bytes(serde_json::to_vec(other).unwrap_or_default()),
    }
}

fn mysql_value_to_json(v: MysqlValue) -> Value {
    match v {
        MysqlValue::NULL => Value::Null,
        MysqlValue::Int(i) => Value::Number(i.into()),
        MysqlValue::UInt(u) => Value::Number(u.into()),
        MysqlValue::Float(f) => json_number_from_f64(f64::from(f)),
        MysqlValue::Double(d) => json_number_from_f64(d),
        MysqlValue::Bytes(bytes) => match String::from_utf8(bytes) {
            Ok(s) => Value::String(s),
            // Non-UTF8 BLOB: surface as a JSON null rather than panic; the
            // adapter is JSON-shaped on purpose and binary columns should be
            // base64-encoded by the schema-service before they ever land here.
            Err(_) => Value::Null,
        },
        MysqlValue::Date(y, mo, d, h, mi, s, us) => Value::String(format!(
            "{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{us:06}Z"
        )),
        MysqlValue::Time(neg, days, h, mi, s, us) => {
            let sign = if neg { "-" } else { "" };
            let total_h = u64::from(days) * 24 + u64::from(h);
            Value::String(format!("{sign}{total_h:02}:{mi:02}:{s:02}.{us:06}"))
        }
    }
}

fn json_number_from_f64(f: f64) -> Value {
    serde_json::Number::from_f64(f)
        .map(Value::Number)
        .unwrap_or(Value::Null)
}

fn row_to_json(mut row: Row) -> Value {
    let columns: Vec<Column> = row.columns_ref().to_vec();
    let mut out = JsonMap::with_capacity(columns.len());
    for (idx, col) in columns.iter().enumerate() {
        let name = col.name_str().into_owned();
        let raw: MysqlValue = row.take(idx).unwrap_or(MysqlValue::NULL);
        out.insert(name, mysql_value_to_json(raw));
    }
    Value::Object(out)
}

// ── unit tests (security-critical bits) ─────────────────────────────────────
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
    fn ddl_errors_classify_schema_shape_mistakes_as_client_errors() {
        // Deterministic user errors must be 4xx — a 5xx makes outbox clients
        // retry a doomed request forever (poison-pill).
        let dup = classify_mysql_error("Duplicate column name 'status'".into(), true);
        assert!(matches!(dup, DataPlaneError::Conflict { .. }), "{dup:?}");
        let missing = classify_mysql_error(
            "Can't DROP 'ghost'; check that column/key exists".into(), true);
        assert!(matches!(missing, DataPlaneError::InvalidRequest { .. }), "{missing:?}");
        let no_table = classify_mysql_error("Table 'ops.ghost' doesn't exist".into(), true);
        assert!(matches!(no_table, DataPlaneError::InvalidRequest { .. }), "{no_table:?}");
        // The query (non-DDL) path keeps its existing Backend mapping.
        let query_path = classify_mysql_error("Unknown column 'x' in 'field list'".into(), false);
        assert!(matches!(query_path, DataPlaneError::Backend { .. }), "{query_path:?}");
    }

    #[test]
    fn owner_filter_always_injects_owner_predicate() {
        let id = identity_with(Some("u-1"));
        let (sql, params) = build_owner_filter(None, &id).unwrap();
        assert_eq!(sql, " WHERE `owner_id` = ?");
        assert_eq!(params.len(), 1);
        assert!(matches!(&params[0], MysqlValue::Bytes(b) if b == b"u-1"));
    }

    #[test]
    fn shared_pool_scopes_each_request_by_its_own_owner() {
        // SHARE_POOLS isolation proof: a pool shared across tenants holds NO
        // tenant state — the owner predicate is bound from THIS request's
        // identity, so two tenants sharing one pool get two different owner
        // filters and can never read each other's rows. This is what makes
        // skipping the single-owner `check_tenant` guard safe on MySQL.
        let (_, pa) = build_owner_filter(None, &identity_with(Some("api-key:a"))).unwrap();
        let (_, pb) = build_owner_filter(None, &identity_with(Some("api-key:b"))).unwrap();
        assert!(matches!(&pa[0], MysqlValue::Bytes(b) if b == b"api-key:a"));
        assert!(matches!(&pb[0], MysqlValue::Bytes(b) if b == b"api-key:b"));
    }

    #[test]
    fn owner_filter_lowers_operators_not_just_equality() {
        // THE bug fix: an operator object is now a real predicate, not silently
        // bound as a literal value (which matched zero rows).
        let id = identity_with(Some("u-1"));
        // The client filter is always parenthesized so the trusted `owner_id`
        // AND scopes the WHOLE predicate (the `$or` case is the security proof).
        let cases = [
            (json!({ "age": { "$gte": 18 } }), " WHERE (`age` >= ?) AND `owner_id` = ?"),
            (json!({ "status": { "$in": ["a", "b"] } }), " WHERE (`status` IN (?, ?)) AND `owner_id` = ?"),
            (json!({ "n": { "$between": [1, 9] } }), " WHERE (`n` BETWEEN ? AND ?) AND `owner_id` = ?"),
            (json!({ "x": { "$null": true } }), " WHERE (`x` IS NULL) AND `owner_id` = ?"),
            (json!({ "name": { "$ilike": "a%" } }), " WHERE (LOWER(`name`) LIKE LOWER(?)) AND `owner_id` = ?"),
            (json!({ "$or": [{ "a": 1 }, { "b": { "$lt": 5 } }] }), " WHERE ((`a` = ?) OR (`b` < ?)) AND `owner_id` = ?"),
            (json!({ "name": "x" }), " WHERE (`name` = ?) AND `owner_id` = ?"), // equality still works
        ];
        for (filter, expected) in cases {
            let (sql, _) = build_owner_filter(Some(&filter), &id).unwrap();
            assert_eq!(sql, expected, "filter {filter}");
        }
    }

    #[test]
    fn owner_filter_rejects_unknown_operator() {
        let id = identity_with(Some("u-1"));
        let err = build_owner_filter(Some(&json!({ "a": { "$drop": 1 } })), &id).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{err:?}");
    }

    #[test]
    fn update_delete_refuse_unconstrained_filter() {
        // No empty/tautology full-table mutation (parity with the Postgres guard).
        let unconstrained = [
            None,
            Some(json!({})),
            Some(json!({ "$not": { "$or": [] } })),
            Some(json!({ "owner_id": "x" })), // only a reserved key → empty after strip
        ];
        for filter in unconstrained {
            let err =
                crate::sql_scope::guard_constraining_filter(filter.as_ref(), &RESERVED_COLUMNS)
                    .unwrap_err();
            assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{filter:?}: {err:?}");
        }
        assert!(
            crate::sql_scope::guard_constraining_filter(Some(&json!({ "id": 1 })), &RESERVED_COLUMNS)
                .is_ok()
        );
    }

    #[test]
    fn owner_filter_drops_client_owner_id_override() {
        let id = identity_with(Some("u-trusted"));
        let filter = json!({"owner_id": "u-attacker", "name": "needle"});
        let (sql, params) = build_owner_filter(Some(&filter), &id).unwrap();
        // Client `owner_id` is dropped, only the trusted one is appended at the end.
        assert!(sql.contains("`name` = ?"));
        assert!(sql.ends_with("`owner_id` = ?"));
        // Last param is always the trusted owner_id.
        assert!(matches!(params.last(), Some(MysqlValue::Bytes(b)) if b == b"u-trusted"));
    }

    #[test]
    fn owner_filter_falls_back_to_tenant_id() {
        let id = identity_with(None);
        let (_, params) = build_owner_filter(None, &id).unwrap();
        assert!(matches!(&params[0], MysqlValue::Bytes(b) if b == b"t-1"));
    }

    #[test]
    fn owner_filter_rejects_non_object_filter() {
        let id = identity_with(Some("u-1"));
        let bad = json!("just a string");
        let err = build_owner_filter(Some(&bad), &id).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }));
    }

    #[test]
    fn owner_filter_rejects_injection_via_column_name() {
        let id = identity_with(Some("u-1"));
        let bad = json!({"name; DROP TABLE users;--": "x"});
        let err = build_owner_filter(Some(&bad), &id).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidIdentifier { .. }));
    }

    #[test]
    fn owned_columns_strips_client_owner_id_and_appends_trusted_one() {
        let id = identity_with(Some("u-trusted"));
        let data = json!({"owner_id": "u-attacker", "name": "ok"});
        let cols = build_owned_columns(Some(&data), &id).unwrap();
        let names: Vec<&str> = cols.iter().map(|(c, _)| c.as_str()).collect();
        assert!(!names.contains(&"owner_id") || names.last().copied() == Some("owner_id"));
        // owner_id must appear exactly once and be the trusted value.
        let owner_occurrences: Vec<&Value> = cols
            .iter()
            .filter(|(c, _)| c == "owner_id")
            .map(|(_, v)| v)
            .collect();
        assert_eq!(owner_occurrences.len(), 1);
        assert_eq!(owner_occurrences[0], &Value::String("u-trusted".to_string()));
    }

    #[test]
    fn owned_columns_rejects_missing_data() {
        let id = identity_with(Some("u-1"));
        let err = build_owned_columns(None, &id).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }));
    }

    #[test]
    fn safe_columns_strips_owner_id() {
        let data = json!({"owner_id": "u-attacker", "name": "ok"});
        let cols = build_safe_columns(Some(&data)).unwrap();
        for (c, _) in &cols {
            assert_ne!(c, "owner_id");
        }
        assert_eq!(cols.len(), 1);
    }

    #[test]
    fn order_by_quotes_identifiers_and_caps_direction() {
        let mut sort = BTreeMap::new();
        sort.insert("created_at".to_string(), "desc".to_string());
        sort.insert("name".to_string(), "asc".to_string());
        let sql = build_order_by(Some(&sort)).unwrap();
        assert!(sql.contains("`created_at` DESC"));
        assert!(sql.contains("`name` ASC"));
    }

    #[test]
    fn order_by_rejects_injection_via_column() {
        let mut sort = BTreeMap::new();
        sort.insert("name; DROP".to_string(), "asc".to_string());
        assert!(build_order_by(Some(&sort)).is_err());
    }

    #[test]
    fn json_to_mysql_value_handles_scalars() {
        assert!(matches!(json_to_mysql_value(&Value::Null), MysqlValue::NULL));
        assert!(matches!(
            json_to_mysql_value(&json!(42)),
            MysqlValue::Int(42)
        ));
        assert!(matches!(
            json_to_mysql_value(&json!(true)),
            MysqlValue::Int(1)
        ));
        assert!(matches!(
            json_to_mysql_value(&json!("hi")),
            MysqlValue::Bytes(b) if b == b"hi"
        ));
    }

    #[test]
    fn json_to_mysql_value_encodes_objects_as_json_string() {
        let v = json!({"k": 1});
        let MysqlValue::Bytes(bytes) = json_to_mysql_value(&v) else {
            panic!("expected Bytes");
        };
        let as_str = String::from_utf8(bytes).unwrap();
        assert_eq!(as_str, r#"{"k":1}"#);
    }

    #[test]
    fn mysql_value_to_json_roundtrips_int_string_null() {
        assert_eq!(mysql_value_to_json(MysqlValue::NULL), Value::Null);
        assert_eq!(
            mysql_value_to_json(MysqlValue::Int(7)),
            Value::Number(7i64.into())
        );
        assert_eq!(
            mysql_value_to_json(MysqlValue::Bytes(b"hello".to_vec())),
            Value::String("hello".to_string())
        );
    }

    #[test]
    fn resolve_namespace_only_for_schema_per_tenant() {
        // Parity with redis's resolve_namespace test: the per-tenant database is
        // selected ONLY for `schema_per_tenant`; every other strategy → None
        // (DSN-default db, byte-identical to before G5). The schema_per_tenant
        // name carries the collision-free `_<hash8>` suffix, so match the prefix.
        use data_plane_core::{CredentialRef, DatabaseMount, PoolPolicy};
        let mk = |iso: Option<&str>| DatabaseMount {
            id: "db1".into(),
            tenant_id: "t-1".into(),
            project_id: None,
            engine: "mysql".into(),
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
        let ns = resolve_namespace(&mk(Some("schema_per_tenant"))).unwrap();
        assert!(ns.starts_with("tenant_t_1_"), "{ns}");
    }

    // --- M22 schema introspection: pure type normalizer (golden table) ---

    #[test]
    fn normalize_mysql_type_golden_table() {
        use NormalizedType as N;
        for (native, expected) in [
            ("int", N::Integer),
            ("int(11)", N::Integer),
            ("bigint(20) unsigned", N::Integer),
            ("smallint", N::Integer),
            ("tinyint(4)", N::Integer),
            ("tinyint(1)", N::Boolean), // the MySQL boolean convention
            ("tinyint(1) unsigned", N::Boolean),
            ("float", N::Float),
            ("double", N::Float),
            ("decimal(10,2)", N::Decimal),
            ("date", N::Date),
            ("datetime", N::Datetime),
            ("timestamp", N::Datetime),
            ("json", N::Json),
            ("char(36)", N::Text),
            ("varchar(255)", N::Text),
            ("text", N::Text),
            ("blob", N::Unknown),
            ("geometry", N::Unknown),
        ] {
            let (ty, values) = normalize_mysql_type(native);
            assert_eq!(ty, expected, "COLUMN_TYPE {native}");
            assert_eq!(values, None, "{native} carries no enum values");
        }
    }

    #[test]
    fn normalize_mysql_type_parses_enum_values() {
        let (ty, values) = normalize_mysql_type("enum('pending','paid','shipped','cancelled')");
        assert_eq!(ty, NormalizedType::Enum);
        assert_eq!(
            values,
            Some(vec![
                "pending".to_string(),
                "paid".to_string(),
                "shipped".to_string(),
                "cancelled".to_string(),
            ])
        );
        // Quote escaping (`''` → literal quote) and case-insensitive keyword.
        let (ty, values) = normalize_mysql_type("ENUM('it''s','b')");
        assert_eq!(ty, NormalizedType::Enum);
        assert_eq!(values, Some(vec!["it's".to_string(), "b".to_string()]));
        // Single value, no trailing garbage.
        let (_, values) = normalize_mysql_type("enum('only')");
        assert_eq!(values, Some(vec!["only".to_string()]));
    }

    // --- M22 step 2: schema DDL — pure SQL builders (golden tables) ---

    use data_plane_core::{DdlColumnDef, SchemaDdlOp, SchemaDdlRequest};

    fn col(name: &str, ty: NormalizedType) -> DdlColumnDef {
        DdlColumnDef {
            name: name.to_string(),
            normalized_type: ty,
            nullable: true,
            default: None,
            enum_values: None,
        }
    }

    fn ddl(op: SchemaDdlOp, table: &str) -> SchemaDdlRequest {
        SchemaDdlRequest {
            op,
            table: table.to_string(),
            column: None,
            column_name: None,
            columns: None,
            primary_key: None,
        }
    }

    #[test]
    fn mysql_sql_type_golden_table() {
        use NormalizedType as N;
        for (ty, expected) in [
            (N::Text, "TEXT"),
            (N::Integer, "BIGINT"),
            (N::Float, "DOUBLE"),
            (N::Decimal, "DECIMAL(18,6)"),
            (N::Boolean, "TINYINT(1)"),
            (N::Date, "DATE"),
            (N::Datetime, "DATETIME"),
            (N::Json, "JSON"),
            (N::Uuid, "CHAR(36)"),
            (N::Array, "JSON"),
        ] {
            assert_eq!(mysql_sql_type(&col("c", ty), false).unwrap(), expected, "{ty:?}");
        }
        // text inside a PRIMARY KEY needs a bounded type.
        assert_eq!(mysql_sql_type(&col("c", N::Text), true).unwrap(), "VARCHAR(255)");
        // enum values are escaped literals (quote doubled, backslash escaped).
        let mut status = col("status", N::Enum);
        status.enum_values = Some(vec!["pending".into(), "it's".into(), "a\\b".into()]);
        assert_eq!(
            mysql_sql_type(&status, false).unwrap(),
            "ENUM('pending', 'it''s', 'a\\\\b')"
        );
        // enum without values, and describe-only types, are client errors.
        assert!(mysql_sql_type(&col("c", N::Enum), false).is_err());
        for ty in [N::Objectid, N::Unknown] {
            assert!(matches!(
                mysql_sql_type(&col("c", ty), false).unwrap_err(),
                DataPlaneError::InvalidRequest { .. }
            ));
        }
    }

    #[test]
    fn mysql_ddl_statements_golden() {
        // add_column with full attributes
        let mut add = ddl(SchemaDdlOp::AddColumn, "orders");
        add.column = Some(DdlColumnDef {
            name: "qty".into(),
            normalized_type: NormalizedType::Integer,
            nullable: false,
            default: Some("0".into()),
            enum_values: None,
        });
        assert_eq!(
            build_mysql_ddl(&add).unwrap(),
            "ALTER TABLE `orders` ADD COLUMN `qty` BIGINT NOT NULL DEFAULT 0"
        );
        // drop_column
        let mut drop_col = ddl(SchemaDdlOp::DropColumn, "orders");
        drop_col.column_name = Some("qty".into());
        assert_eq!(
            build_mysql_ddl(&drop_col).unwrap(),
            "ALTER TABLE `orders` DROP COLUMN `qty`"
        );
        // alter_column_type → MODIFY with the FULL def (nullability explicit,
        // because MODIFY resets attributes).
        let mut alter = ddl(SchemaDdlOp::AlterColumnType, "orders");
        alter.column = Some(col("note", NormalizedType::Text));
        assert_eq!(
            build_mysql_ddl(&alter).unwrap(),
            "ALTER TABLE `orders` MODIFY COLUMN `note` TEXT NULL"
        );
        // drop_table
        assert_eq!(
            build_mysql_ddl(&ddl(SchemaDdlOp::DropTable, "orders")).unwrap(),
            "DROP TABLE `orders`"
        );
    }

    #[test]
    fn mysql_ddl_create_table_appends_owner_and_uses_varchar_pk() {
        let mut create = ddl(SchemaDdlOp::CreateTable, "orders");
        create.columns = Some(vec![
            DdlColumnDef {
                name: "sku".into(),
                normalized_type: NormalizedType::Text,
                nullable: false,
                default: None,
                enum_values: None,
            },
            col("note", NormalizedType::Text),
        ]);
        create.primary_key = Some(vec!["sku".into()]);
        assert_eq!(
            build_mysql_ddl(&create).unwrap(),
            "CREATE TABLE `orders` (`sku` VARCHAR(255) NOT NULL, `note` TEXT NULL, \
             `owner_id` VARCHAR(64), PRIMARY KEY (`sku`))"
        );
        // explicit owner_id is respected, not duplicated.
        let mut explicit = ddl(SchemaDdlOp::CreateTable, "orders");
        explicit.columns = Some(vec![
            DdlColumnDef {
                name: "id".into(),
                normalized_type: NormalizedType::Integer,
                nullable: false,
                default: None,
                enum_values: None,
            },
            col("owner_id", NormalizedType::Uuid),
        ]);
        explicit.primary_key = Some(vec!["id".into()]);
        let sql = build_mysql_ddl(&explicit).unwrap();
        assert_eq!(sql.matches("owner_id").count(), 1, "{sql}");
    }

    #[test]
    fn mysql_ddl_rejects_injection_and_unsafe_defaults() {
        assert!(matches!(
            build_mysql_ddl(&ddl(SchemaDdlOp::DropTable, "orders`; DROP TABLE x")).unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
        let mut bad_default = ddl(SchemaDdlOp::AddColumn, "orders");
        bad_default.column = Some(DdlColumnDef {
            name: "c".into(),
            normalized_type: NormalizedType::Text,
            nullable: true,
            default: Some("'x'; DROP TABLE orders".into()),
            enum_values: None,
        });
        assert!(matches!(
            build_mysql_ddl(&bad_default).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
    }

    #[test]
    fn mysql_error_classifier_maps_ddl_cast_errors_to_conflict() {
        // Truncation / incorrect-value (1264/1265/1292/1366: bad enum value,
        // unparseable date, overflow) → Conflict on BOTH paths now: on writes
        // they mean the caller's VALUE doesn't fit the column — a 5xx made
        // the live UI outbox retry a doomed write forever (M23 battery pin).
        for msg in [
            "Server error: `ERROR 1265 (01000): Data truncated for column 'n' at row 1'",
            "Server error: `ERROR 1292 (22007): Truncated incorrect DOUBLE value: 'abc'",
            "Server error: `ERROR 1366 (HY000): Incorrect integer value: 'abc' for column 'n' at row 1",
            "Server error: `ERROR 1264 (22003): Out of range value for column 'total' at row 1",
        ] {
            assert!(
                matches!(ddl_backend(msg), DataPlaneError::Conflict { .. }),
                "{msg}"
            );
            assert!(
                matches!(backend(msg), DataPlaneError::Conflict { .. }),
                "{msg}"
            );
        }
        // Integrity violations stay Conflict on BOTH paths (pre-existing).
        for msg in ["Duplicate entry 'x' for key 'PRIMARY'", "a foreign key constraint fails"] {
            assert!(matches!(backend(msg), DataPlaneError::Conflict { .. }), "{msg}");
            assert!(matches!(ddl_backend(msg), DataPlaneError::Conflict { .. }), "{msg}");
        }
        // Anything else is a Backend error on both paths.
        assert!(matches!(ddl_backend("connection reset"), DataPlaneError::Backend { .. }));
    }
}
