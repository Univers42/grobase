//! The pooled MySQL connection set ([`MysqlPool`]) and the pinned interactive
//! transaction handle ([`MysqlTxHandle`]) — the `EnginePool`/`TxHandle` surface.
//
// ponytail: >300 lines, but the `EnginePool for MysqlPool` trait impl is
//   indivisible (Rust forbids splitting one trait impl across files) and the
//   length is its 7 methods + their security docs (migration credential split,
//   schema-per-tenant USE discipline). Splitting the data methods from the
//   schema methods would only work as separate inherent blocks, not the trait —
//   not worth fragmenting one cohesive port.

use super::adapter::{dispatch_single, run_batch, SUPPORTED_OPS};
use super::convert::{json_to_mysql_value, row_to_json};
use super::error::{backend, ddl_backend};
use super::schema::{build_mysql_ddl, normalize_mysql_type};
use super::*;

/// A pooled MySQL connection set bound to a single mount.
pub struct MysqlPool {
    // Fields are `pub(super)` so the sibling `adapter` module can construct the
    // pool in `open_pool` (module-private would not cross the submodule split).
    pub(super) mount_id: String,
    pub(super) tenant_id: String,
    /// True for a SHARE_POOLS shared_rls pool serving many tenants from one
    /// connection set: the single-owner `check_tenant` assertion is then
    /// skipped (the `owner_id` predicate from each request's identity carries
    /// isolation — `self.tenant_id` has no single value to assert). See
    /// `crate::pools_shared` and the postgres adapter.
    pub(super) shared_pool: bool,
    pub(super) pool: Pool,
    /// `Some("tenant_<id>")` for `schema_per_tenant` mounts: the per-tenant
    /// database selected via `USE` on every checkout. `None` (shared_rls /
    /// db_per_tenant) means no `USE` — the DSN-default database, as before G5.
    pub(super) namespace: Option<String>,
    /// F1 per-table isolation: NAMED tables that skip owner-scoping (a shared
    /// catalog readable across owners). Empty unless `DATA_PLANE_PER_TABLE_ISOLATION`
    /// is ON and the mount opted in → byte-parity (every table owner-scoped).
    pub(super) shared_resources: std::sync::Arc<[String]>,
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
            DataOperationKind::Batch => {
                run_batch(&mut tx, &operation, &identity, &self.shared_resources).await
            }
            _ => dispatch_single(&mut tx, &operation, &identity, &self.shared_resources).await,
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
        conn.query_drop("START TRANSACTION")
            .await
            .map_err(backend)?;

        let tx_id = uuid::Uuid::now_v7().to_string();
        Ok(Box::new(MysqlTxHandle {
            tx_id,
            mount_id: self.mount_id.clone(),
            // Bind the txn to the tenant that BEGAN it — not the pool's opener,
            // which differs under SHARE_POOLS. On a per-tenant pool this is
            // byte-identical (the dispatcher guarantees identity == pool tenant);
            // on a shared pool it is the only correct owner of this transaction.
            tenant_id: request.identity.tenant_id.clone(),
            shared_resources: self.shared_resources.clone(),
            conn: Mutex::new(Some(conn)),
        }))
    }

    async fn close(&self) -> DataPlaneResult<()> {
        // `mysql_async::Pool::disconnect` consumes the pool but Pool is a cheap
        // Arc so cloning is fine; outstanding connections drop independently.
        let pool = self.pool.clone();
        pool.disconnect()
            .await
            .map_err(|e| DataPlaneError::Backend {
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
    // ponytail: fixed migration sequence (ensure DB → marker table → idempotency
    //   check → run statements → record) — one ordered transaction-of-record,
    //   not separable without leaking the marker-row invariant across calls.
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
    // ponytail: irreducible introspection — three information_schema queries
    //   (PK, FK, columns) each feeding one accumulator, then assembled; the
    //   three are sequential data dependencies, not independently extractable.
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
            fks.insert(
                (table, column),
                ForeignKeyRef {
                    table: ref_table,
                    column: ref_column,
                },
            );
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

/// Pinned MySQL transaction. Holds the checked-out connection across
/// execute calls; releases it when commit/rollback consumes the handle.
///
/// `conn` is `Option<Conn>` inside the Mutex so commit/rollback can take
/// ownership and drop the Conn (the deadpool reclaim happens on drop).
pub struct MysqlTxHandle {
    tx_id: String,
    mount_id: String,
    tenant_id: String,
    shared_resources: std::sync::Arc<[String]>,
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
            DataOperationKind::Batch => {
                run_batch(conn, &operation, &identity, &self.shared_resources).await
            }
            _ => dispatch_single(conn, &operation, &identity, &self.shared_resources).await,
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
