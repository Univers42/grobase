/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   pool.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:27:35 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:27:37 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The pooled SQL Server connection set ([`MssqlPool`]) plus plan execution
//! (`run_plan`) and the atomic batch (`run_batch`) — the `EnginePool` surface.

use super::convert::{json_to_param, normalize_mssql_type, row_to_json};
use super::dial::DialManager;
use super::error::backend;
use super::query::{build_plan, owner_of, SqlPlan, P};
use super::*;
use data_plane_core::{normalise_version, EngineProbe, TlsPosture};

pub struct MssqlPool {
    // Fields are `pub(super)` so the sibling `adapter` module can construct the
    // pool in `open_pool` (module-private would not cross the submodule split).
    pub(super) mount_id: String,
    pub(super) tenant_id: String,
    pub(super) owner_scoped: bool,
    /// True for a SHARE_POOLS shared_rls pool serving many tenants: the
    /// single-owner `check_tenant` assertion is skipped (the `owner_id`
    /// predicate from each request's identity carries isolation). See
    /// `crate::pools_shared`.
    pub(super) shared_pool: bool,
    pub(super) pool: Pool<DialManager>,
    /// TLS posture selected when this pool was opened.
    pub(super) tls: TlsPosture,
}

impl MssqlPool {
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

    async fn conn(&self) -> DataPlaneResult<bb8::PooledConnection<'_, DialManager>> {
        self.pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("mssql checkout failed: {e}"),
        })
    }
}

#[async_trait]
impl EnginePool for MssqlPool {
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
                feature: format!("operation {:?} on mssql", operation.op),
            });
        }
        let owner = self.owner(&identity);

        if operation.op == DataOperationKind::Batch {
            let items = operation
                .batch_items()
                .map_err(|message| DataPlaneError::InvalidRequest { message })?;
            let mut plans: Vec<SqlPlan> = Vec::with_capacity(items.len());
            for sub in &items {
                plans.push(build_plan(sub, owner.as_deref())?);
            }
            return self.run_batch(plans).await;
        }

        let plan = build_plan(&operation, owner.as_deref())?;
        let mut conn = self.conn().await?;
        run_plan(&mut conn, &plan).await
    }

    async fn begin(&self, _request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        Err(DataPlaneError::NotImplemented {
            feature: "multi-statement transactions on mssql".to_string(),
        })
    }

    async fn close(&self) -> DataPlaneResult<()> {
        Ok(())
    }

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
        let bound: Vec<P> = params.iter().map(json_to_param).collect();
        let plan = SqlPlan {
            sql,
            params: bound,
            returns_rows: expect_rows,
        };
        let mut conn = self.conn().await?;
        run_plan(&mut conn, &plan).await
    }

    // Three catalog reads (columns, primary keys, foreign keys) joined in memory:
    // describe is an admin path, not the query hot path.
    // Caveat: tables match by bare name across schemas — two schemas holding a
    //   same-named table merge their columns and keys into one entry.
    async fn describe_schema(
        &self,
        identity: RequestIdentity,
    ) -> DataPlaneResult<SchemaDescriptor> {
        self.check_tenant(&identity)?;
        let mut conn = self.conn().await?;
        let rows = conn
            .query(
                "SELECT t.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE, c.IS_NULLABLE \
                 FROM INFORMATION_SCHEMA.TABLES t \
                 JOIN INFORMATION_SCHEMA.COLUMNS c ON c.TABLE_NAME = t.TABLE_NAME \
                 WHERE t.TABLE_TYPE = 'BASE TABLE' \
                 ORDER BY t.TABLE_NAME, c.ORDINAL_POSITION",
                &[],
            )
            .await
            .map_err(backend)?
            .into_first_result()
            .await
            .map_err(backend)?;
        let pks = key_columns(&mut conn, PK_SQL, 2).await?;
        let mut fks: BTreeMap<(String, String), ForeignKeyRef> = BTreeMap::new();
        for cols in key_columns(&mut conn, FK_SQL, 4).await? {
            if let [table, column, ref_table, ref_column] = cols.as_slice() {
                let target = ForeignKeyRef {
                    table: ref_table.clone(),
                    column: ref_column.clone(),
                };
                fks.insert((table.clone(), column.clone()), target);
            }
        }

        let mut tables: BTreeMap<String, Vec<ColumnSchema>> = BTreeMap::new();
        for row in rows {
            let table: &str = row.get(0).unwrap_or("");
            let col: &str = row.get(1).unwrap_or("");
            let native: &str = row.get(2).unwrap_or("");
            let nullable: &str = row.get(3).unwrap_or("YES");
            tables
                .entry(table.to_string())
                .or_default()
                .push(ColumnSchema {
                    name: col.to_string(),
                    native_type: native.to_string(),
                    normalized_type: normalize_mssql_type(native),
                    nullable: nullable.eq_ignore_ascii_case("YES"),
                    default: None,
                    enum_values: None,
                    references: fks.remove(&(table.to_string(), col.to_string())),
                    inferred: false,
                });
        }
        Ok(SchemaDescriptor {
            engine: "mssql".to_string(),
            tables: tables
                .into_iter()
                .map(|(name, columns)| TableSchema {
                    primary_key: pks
                        .iter()
                        .filter(|k| k[0] == name)
                        .map(|k| k[1].clone())
                        .collect(),
                    name,
                    columns,
                })
                .collect(),
        })
    }

    async fn probe(&self) -> DataPlaneResult<EngineProbe> {
        let mut conn = self.pool.get().await.map_err(|_| DataPlaneError::Backend {
            message: "probe: pool checkout failed".into(),
        })?;
        let server_version = match conn
            .simple_query("SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(32))")
            .await
        {
            Ok(stream) => match stream.into_row().await {
                Ok(Some(row)) => row
                    .try_get::<&str, _>(0)
                    .ok()
                    .flatten()
                    .map_or_else(|| "unknown".into(), normalise_version),
                _ => "unknown".into(),
            },
            Err(_) => "unknown".into(),
        };
        Ok(EngineProbe {
            server_version,
            tls: self.tls,
            tls_version: None,
        })
    }
}

// Primary-key columns in key order, (table, column).
const PK_SQL: &str = "SELECT kcu.TABLE_NAME, kcu.COLUMN_NAME \
     FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc \
     JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu \
       ON kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME AND kcu.TABLE_NAME = tc.TABLE_NAME \
     WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY' \
     ORDER BY kcu.TABLE_NAME, kcu.ORDINAL_POSITION";

// Foreign-key column pairs, (table, column, referenced table, referenced column).
const FK_SQL: &str = "SELECT OBJECT_NAME(fkc.parent_object_id), \
       COL_NAME(fkc.parent_object_id, fkc.parent_column_id), \
       OBJECT_NAME(fkc.referenced_object_id), \
       COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id) \
     FROM sys.foreign_key_columns fkc";

/// Runs a catalog query whose first `width` columns are all names.
async fn key_columns(
    conn: &mut bb8::PooledConnection<'_, DialManager>,
    sql: &str,
    width: usize,
) -> DataPlaneResult<Vec<Vec<String>>> {
    let rows = conn
        .query(sql, &[])
        .await
        .map_err(backend)?
        .into_first_result()
        .await
        .map_err(backend)?;
    Ok(rows
        .iter()
        .map(|row| {
            (0..width)
                .map(|i| row.get::<&str, _>(i).unwrap_or("").to_string())
                .collect()
        })
        .collect())
}

impl MssqlPool {
    /// Atomic batch: BEGIN TRAN on ONE pooled connection, run every item, COMMIT.
    /// A failure rolls back and surfaces an error so `execute` returns Err —
    /// nothing persisted (matches the BatchSummary `atomic:true` contract).
    async fn run_batch(&self, plans: Vec<SqlPlan>) -> DataPlaneResult<DataResult> {
        let mut conn = self.conn().await?;
        conn.simple_query("BEGIN TRAN").await.map_err(backend)?;
        let mut items: Vec<BatchItemOutcome> = Vec::with_capacity(plans.len());
        for (idx, plan) in plans.iter().enumerate() {
            match run_plan(&mut conn, plan).await {
                Ok(res) => items.push(BatchItemOutcome {
                    index: idx as u32,
                    status: BatchItemStatus::Ok,
                    affected_rows: res.affected_rows,
                    error: None,
                }),
                Err(e) => {
                    let _ = conn.simple_query("ROLLBACK").await;
                    return Err(DataPlaneError::prefix_message(
                        &format!("batch item {idx}: "),
                        e,
                    ));
                }
            }
        }
        conn.simple_query("COMMIT").await.map_err(backend)?;
        let affected = items
            .iter()
            .filter(|i| i.status == BatchItemStatus::Ok)
            .count() as u64;
        Ok(DataResult {
            rows: vec![],
            affected_rows: affected,
            next_cursor: None,
            batch: Some(BatchSummary {
                atomic: true,
                items,
            }),
        })
    }
}

async fn run_plan(
    conn: &mut bb8::PooledConnection<'_, DialManager>,
    plan: &SqlPlan,
) -> DataPlaneResult<DataResult> {
    let refs: Vec<&dyn ToSql> = plan.params.iter().map(|p| p as &dyn ToSql).collect();
    if plan.returns_rows {
        let rows = conn
            .query(&plan.sql, &refs)
            .await
            .map_err(backend)?
            .into_first_result()
            .await
            .map_err(backend)?;
        let data: Vec<Value> = rows.into_iter().map(row_to_json).collect();
        let affected = data.len() as u64;
        Ok(DataResult::new(data, affected))
    } else {
        let result = conn.execute(&plan.sql, &refs).await.map_err(backend)?;
        let affected: u64 = result.rows_affected().iter().sum();
        Ok(DataResult::new(vec![], affected))
    }
}
