/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   pool.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:30:07 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:30:08 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The mount-scoped [`SqlitePool`] and its [`EnginePool`] surface: per-request
//! tenant cross-check, the writer-thread submit channel, and the CRUD / raw-SQL
//! / introspection / structured-DDL endpoints. Mutations queue to the single
//! writer thread ([`super::writer`]); reads run parallel on the deadpool under
//! WAL.

use async_trait::async_trait;
use data_plane_core::{
    BatchItemStatus, DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult,
    EnginePool, RawStatement, RequestIdentity, SchemaDdlRequest, SchemaDdlResult, SchemaDdlStatus,
    SchemaDescriptor, TxBeginRequest, TxHandle,
};
use deadpool_sqlite::Pool;
use rusqlite::types::Value as SqlValue;

use super::convert::json_to_sql;
use super::exec::{describe_schema_blocking, query_rows, run_plan};
use super::query::{build_plan, SqlPlan};
use super::schema::build_sqlite_ddl;
use super::writer::WriteJob;

pub struct SqlitePool {
    pub(super) mount_id: String,
    pub(super) tenant_id: String,
    /// `true` for `shared_rls` (the default) — every read/write is scoped to the
    /// caller's `owner_id`. `false` for `tenant_owned` (the whole file is one
    /// tenant's, scoped at mount resolution) — no per-row owner predicate.
    pub(super) owner_scoped: bool,
    /// True for a SHARE_POOLS shared_rls pool serving many tenants from one
    /// SQLite file: the single-owner `check_tenant` assertion is skipped (the
    /// `owner_id` predicate from each request's identity carries isolation).
    /// See `crate::pools_shared`.
    pub(super) shared_pool: bool,
    pub(super) pool: Pool,
    /// SQLite allows exactly ONE writer per database. N pooled connections
    /// fighting for the file lock collapse under load (measured: 48 req/s at
    /// c=64, p99 pinned at the 5 s busy_timeout); even a fair semaphore pays
    /// a full commit per write (57 req/s at c=64). The answer — the one
    /// high-throughput SQLite servers use — is this queue to a dedicated
    /// writer thread that GROUP-COMMITS: up to [`super::writer`]'s `GROUP_MAX`
    /// queued writes execute inside one transaction (a savepoint per job
    /// preserves per-job atomicity), so one commit is amortized across the
    /// whole group. WAL readers stay fully parallel on the pool.
    pub(super) writer: tokio::sync::mpsc::UnboundedSender<WriteJob>,
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

    async fn checkout(&self) -> DataPlaneResult<deadpool_sqlite::Object> {
        self.pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("sqlite checkout failed: {e}"),
        })
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
        if !super::SUPPORTED_OPS.contains(&operation.op) {
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
                affected_rows: summary
                    .items
                    .iter()
                    .filter(|i| i.status == BatchItemStatus::Ok)
                    .count() as u64,
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
        let RawStatement {
            statement: sql,
            params,
            expect_rows,
        } = statement;
        let sql_params: Vec<SqlValue> = params.iter().map(json_to_sql).collect();
        // `expect_rows=false` is the write/DDL shape — writer-thread queue;
        // row-returning raw SQL reads in parallel off the pool.
        if !expect_rows {
            return self
                .submit(|reply| WriteJob::Raw {
                    sql,
                    params: sql_params,
                    reply,
                })
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

    async fn describe_schema(
        &self,
        identity: RequestIdentity,
    ) -> DataPlaneResult<SchemaDescriptor> {
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

fn owner_of(identity: &RequestIdentity) -> String {
    identity.owner_principal().to_string()
}
