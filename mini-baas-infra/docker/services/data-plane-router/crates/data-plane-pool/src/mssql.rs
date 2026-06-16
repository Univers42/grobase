//! Microsoft SQL Server engine adapter (R-mssql, Phase 3d).
//!
//! Pure-Rust TDS via `tiberius` + a `bb8` pool (async, no spawn_blocking). The
//! dialect diverges from the other SQL engines in four ways handled here:
//!   * parameters are `@P1, @P2, …` (1-indexed), not `?`;
//!   * identifiers quote with `[brackets]`, escaping `]` as `]]`;
//!   * pagination is `OFFSET n ROWS FETCH NEXT m ROWS ONLY` (requires an
//!     ORDER BY — we synthesize `ORDER BY (SELECT NULL)` when none is given);
//!   * upsert is a `MERGE` arbitrated on `(owner_id, key…)`.
//!
//! Owner scoping is server-side (`owner_id` predicate + owner-stamped writes),
//! exactly like MySQL/SQLite — SQL Server's row-level security is not assumed.
//! Honest descriptor (`EngineCapabilities::mssql`): CRUD + upsert + ATOMIC batch
//! (BEGIN TRAN on one pooled connection) + aggregate + introspection.
//! `transactions:false` — no cross-request pinned TxHandle (same call as SQLite).

use crate::resolver::MountResolver;
use async_trait::async_trait;
use bb8::Pool;
use bb8_tiberius::ConnectionManager;
use data_plane_core::{
    AggFunc, Aggregate, BatchItemOutcome, BatchItemStatus, BatchSummary, CmpOp, ColumnSchema,
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult, DatabaseMount,
    EngineAdapter, EngineCapabilities, EngineHealth, EnginePool, Filter, Folded, NormalizedType,
    RawStatement, RequestIdentity, SchemaDescriptor, TableSchema, TxBeginRequest, TxHandle,
};
use serde_json::{Map as JsonMap, Value};
use std::borrow::Cow;
use std::collections::BTreeMap;
use std::sync::Arc;
use tiberius::{AuthMethod, ColumnData, Config, ToSql};

const RESERVED_COLUMNS: &[&str] = &["owner_id", "tenant_id"];

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

pub struct MssqlEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl MssqlEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

#[async_trait]
impl EngineAdapter for MssqlEngineAdapter {
    fn engine(&self) -> &str {
        "mssql"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::mssql()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        let config = mssql_config(&dsn)?;
        let manager = ConnectionManager::new(config);
        let pool = Pool::builder()
            .max_size(mount.pool_policy.max.max(1))
            .build(manager)
            .await
            .map_err(|e| DataPlaneError::Backend {
                message: format!("mssql pool build failed: {e}"),
            })?;
        Ok(Box::new(MssqlPool {
            mount_id: mount.id.clone(),
            tenant_id: mount.tenant_id.clone(),
            owner_scoped: mount.isolation().owner_scoped(),
            shared_pool: crate::pools_shared(&mount),
            pool,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth {
            engine: "mssql".to_string(),
            mount_id: pool.mount_id().to_string(),
            status: "unknown".to_string(),
        })
    }
}

pub struct MssqlPool {
    mount_id: String,
    tenant_id: String,
    owner_scoped: bool,
    /// True for a SHARE_POOLS shared_rls pool serving many tenants: the
    /// single-owner `check_tenant` assertion is skipped (the `owner_id`
    /// predicate from each request's identity carries isolation). See
    /// `crate::pools_shared`.
    shared_pool: bool,
    pool: Pool<ConnectionManager>,
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

    async fn conn(&self) -> DataPlaneResult<bb8::PooledConnection<'_, ConnectionManager>> {
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
        let RawStatement { statement: sql, params, expect_rows } = statement;
        let bound: Vec<P> = params.iter().map(json_to_param).collect();
        let plan = SqlPlan { sql, params: bound, returns_rows: expect_rows };
        let mut conn = self.conn().await?;
        run_plan(&mut conn, &plan).await
    }

    async fn describe_schema(&self, identity: RequestIdentity) -> DataPlaneResult<SchemaDescriptor> {
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

        let mut tables: BTreeMap<String, Vec<ColumnSchema>> = BTreeMap::new();
        for row in rows {
            let table: &str = row.get(0).unwrap_or("");
            let col: &str = row.get(1).unwrap_or("");
            let native: &str = row.get(2).unwrap_or("");
            let nullable: &str = row.get(3).unwrap_or("YES");
            tables.entry(table.to_string()).or_default().push(ColumnSchema {
                name: col.to_string(),
                native_type: native.to_string(),
                normalized_type: normalize_mssql_type(native),
                nullable: nullable.eq_ignore_ascii_case("YES"),
                default: None,
                enum_values: None,
                references: None,
                inferred: false,
            });
        }
        Ok(SchemaDescriptor {
            engine: "mssql".to_string(),
            tables: tables
                .into_iter()
                .map(|(name, columns)| TableSchema {
                    name,
                    primary_key: vec![],
                    columns,
                })
                .collect(),
        })
    }
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
                    return Err(DataPlaneError::prefix_message(&format!("batch item {idx}: "), e));
                }
            }
        }
        conn.simple_query("COMMIT").await.map_err(backend)?;
        let affected = items.iter().filter(|i| i.status == BatchItemStatus::Ok).count() as u64;
        Ok(DataResult {
            rows: vec![],
            affected_rows: affected,
            next_cursor: None,
            batch: Some(BatchSummary { atomic: true, items }),
        })
    }
}

async fn run_plan(
    conn: &mut bb8::PooledConnection<'_, ConnectionManager>,
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
        Ok(DataResult { rows: data, affected_rows: affected, next_cursor: None, batch: None })
    } else {
        let result = conn.execute(&plan.sql, &refs).await.map_err(backend)?;
        let affected: u64 = result.rows_affected().iter().sum();
        Ok(DataResult { rows: vec![], affected_rows: affected, next_cursor: None, batch: None })
    }
}

// ── plan building (pure) ────────────────────────────────────────────────────

struct SqlPlan {
    sql: String,
    params: Vec<P>,
    returns_rows: bool,
}

/// A bound parameter (owned so it outlives the borrow tiberius needs).
enum P {
    Null,
    Int(i64),
    Real(f64),
    Bool(bool),
    Text(String),
}

impl ToSql for P {
    fn to_sql(&self) -> ColumnData<'_> {
        match self {
            P::Null => ColumnData::String(None),
            P::Int(i) => ColumnData::I64(Some(*i)),
            P::Real(f) => ColumnData::F64(Some(*f)),
            P::Bool(b) => ColumnData::Bit(Some(*b)),
            P::Text(s) => ColumnData::String(Some(Cow::Borrowed(s.as_str()))),
        }
    }
}

/// Accumulates params and emits `@PN` placeholders in bind order.
#[derive(Default)]
struct Binder {
    params: Vec<P>,
}

impl Binder {
    fn bind(&mut self, value: &Value) -> String {
        self.params.push(json_to_param(value));
        format!("@P{}", self.params.len())
    }
    fn bind_owned(&mut self, p: P) -> String {
        self.params.push(p);
        format!("@P{}", self.params.len())
    }
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
    let mut binder = Binder::default();
    let where_sql = build_owner_filter(&mut binder, op.filter.as_ref(), owner)?;
    // OFFSET/FETCH requires an ORDER BY; synthesize a stable no-op when absent.
    let order_sql = match build_order_by(op.sort.as_ref())? {
        Some(s) => s,
        None => " ORDER BY (SELECT NULL)".to_string(),
    };
    let limit = op.limit.unwrap_or(100).min(500);
    let offset = op.offset.unwrap_or(0);
    Ok(SqlPlan {
        sql: format!(
            "SELECT * FROM {table}{where_sql}{order_sql} OFFSET {offset} ROWS FETCH NEXT {limit} ROWS ONLY"
        ),
        params: binder.params,
        returns_rows: true,
    })
}

fn build_get(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let mut binder = Binder::default();
    let where_sql = build_owner_filter(&mut binder, op.filter.as_ref(), owner)?;
    Ok(SqlPlan {
        sql: format!("SELECT TOP 1 * FROM {table}{where_sql}"),
        params: binder.params,
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
    let mut binder = Binder::default();
    let (col_sql, ph) = render_columns(&mut binder, &columns)?;
    Ok(SqlPlan {
        sql: format!("INSERT INTO {table} ({col_sql}) VALUES ({ph})"),
        params: binder.params,
        returns_rows: false,
    })
}

fn build_update(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    guard_constraining_filter(op.filter.as_ref())?;
    let set_cols = build_safe_columns(op.data.as_ref())?;
    if set_cols.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "update `data` must not be empty".to_string(),
        });
    }
    let mut binder = Binder::default();
    let mut set_parts = Vec::with_capacity(set_cols.len());
    for (col, val) in &set_cols {
        let ph = binder.bind(val);
        set_parts.push(format!("{} = {ph}", quote_ident(col)?));
    }
    let where_sql = build_owner_filter(&mut binder, op.filter.as_ref(), owner)?;
    Ok(SqlPlan {
        sql: format!("UPDATE {table} SET {}{where_sql}", set_parts.join(", ")),
        params: binder.params,
        returns_rows: false,
    })
}

fn build_delete(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    guard_constraining_filter(op.filter.as_ref())?;
    let mut binder = Binder::default();
    let where_sql = build_owner_filter(&mut binder, op.filter.as_ref(), owner)?;
    Ok(SqlPlan {
        sql: format!("DELETE FROM {table}{where_sql}"),
        params: binder.params,
        returns_rows: false,
    })
}

/// Upsert via MERGE arbitrated on (owner_id, sorted filter keys). A foreign
/// owner's id collision is NOT matched (different owner_id) → MERGE tries INSERT
/// → id PRIMARY KEY violation → error, never an overwrite (cross-owner guard).
fn build_upsert(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let filter = require_object(op.filter.as_ref(), "filter")?;
    let columns = build_owned_columns(op.data.as_ref(), owner)?;
    if columns.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert `data` must not be empty".to_string(),
        });
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
    let mut match_cols: Vec<String> = Vec::new();
    if owner.is_some() {
        match_cols.push("owner_id".to_string());
    }
    match_cols.extend(keys.iter().map(|k| (*k).to_string()));
    let conflict_set: std::collections::BTreeSet<&str> = match_cols.iter().map(String::as_str).collect();

    let mut binder = Binder::default();
    // Build the source row (VALUES) as @P params with aliased columns.
    let mut src_cols: Vec<String> = Vec::with_capacity(columns.len());
    let mut src_vals: Vec<String> = Vec::with_capacity(columns.len());
    for (col, val) in &columns {
        src_cols.push(quote_ident(col)?);
        src_vals.push(binder.bind(val));
    }
    let on_clause = match_cols
        .iter()
        .map(|c| {
            let q = quote_ident(c)?;
            Ok(format!("tgt.{q} = src.{q}"))
        })
        .collect::<DataPlaneResult<Vec<_>>>()?
        .join(" AND ");
    let update_set = columns
        .iter()
        .filter(|(c, _)| !conflict_set.contains(c.as_str()))
        .map(|(c, _)| {
            let q = quote_ident(c)?;
            Ok(format!("tgt.{q} = src.{q}"))
        })
        .collect::<DataPlaneResult<Vec<_>>>()?;
    let when_matched = if update_set.is_empty() {
        String::new()
    } else {
        format!(" WHEN MATCHED THEN UPDATE SET {}", update_set.join(", "))
    };
    let insert_cols = src_cols.join(", ");
    let insert_vals = src_cols.iter().map(|c| format!("src.{c}")).collect::<Vec<_>>().join(", ");
    let sql = format!(
        "MERGE {table} AS tgt USING (VALUES ({})) AS src ({}) ON {on_clause}{when_matched} \
         WHEN NOT MATCHED THEN INSERT ({insert_cols}) VALUES ({insert_vals});",
        src_vals.join(", "),
        src_cols.join(", ")
    );
    Ok(SqlPlan { sql, params: binder.params, returns_rows: false })
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
    let mut binder = Binder::default();
    let where_sql = build_owner_filter(&mut binder, op.filter.as_ref(), owner)?;
    let group_sql = if group_cols.is_empty() {
        String::new()
    } else {
        format!(" GROUP BY {}", group_cols.join(", "))
    };
    let limit = op.limit.unwrap_or(1000).min(10_000);
    Ok(SqlPlan {
        sql: format!(
            "SELECT TOP {limit} {} FROM {table}{where_sql}{group_sql}",
            select_cols.join(", ")
        ),
        params: binder.params,
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

// ── shared pure helpers ──────────────────────────────────────────────────────

fn owner_of(identity: &RequestIdentity) -> String {
    identity
        .user_id
        .clone()
        .unwrap_or_else(|| identity.tenant_id.clone())
}

fn build_owner_filter(
    binder: &mut Binder,
    filter: Option<&Value>,
    owner: Option<&str>,
) -> DataPlaneResult<String> {
    let mut clauses: Vec<String> = Vec::new();
    if let Some(filter_value) = filter {
        let cleaned = strip_reserved_top_level(filter_value);
        let tree = Filter::parse(&cleaned)?;
        if let Some(sql) = lower_filter(&tree, binder)? {
            clauses.push(format!("({sql})"));
        }
    }
    if let Some(owner) = owner {
        let ph = binder.bind_owned(P::Text(owner.to_string()));
        clauses.push(format!("[owner_id] = {ph}"));
    }
    if clauses.is_empty() {
        Ok(String::new())
    } else {
        Ok(format!(" WHERE {}", clauses.join(" AND ")))
    }
}

fn guard_constraining_filter(filter: Option<&Value>) -> DataPlaneResult<()> {
    let folded = match filter {
        Some(v) => Filter::parse(&strip_reserved_top_level(v))?.fold(),
        None => Folded::AlwaysTrue,
    };
    if folded == Folded::AlwaysTrue {
        return Err(DataPlaneError::InvalidRequest {
            message: "update/delete requires a constraining filter (refusing full-table mutation)"
                .to_string(),
        });
    }
    Ok(())
}

fn strip_reserved_top_level(filter: &Value) -> std::borrow::Cow<'_, Value> {
    if let Value::Object(map) = filter {
        if map.keys().any(|k| RESERVED_COLUMNS.contains(&k.as_str())) {
            let cleaned = map
                .iter()
                .filter(|(k, _)| !RESERVED_COLUMNS.contains(&k.as_str()))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect();
            return std::borrow::Cow::Owned(Value::Object(cleaned));
        }
    }
    std::borrow::Cow::Borrowed(filter)
}

fn cmp_op_sql(op: CmpOp) -> &'static str {
    match op {
        CmpOp::Eq => "=",
        CmpOp::Ne => "<>",
        CmpOp::Lt => "<",
        CmpOp::Lte => "<=",
        CmpOp::Gt => ">",
        CmpOp::Gte => ">=",
    }
}

fn lower_filter(filter: &Filter, binder: &mut Binder) -> DataPlaneResult<Option<String>> {
    Ok(match filter {
        Filter::And(parts) => {
            let mut sqls = Vec::with_capacity(parts.len());
            for p in parts {
                if let Some(s) = lower_filter(p, binder)? {
                    sqls.push(s);
                }
            }
            if sqls.is_empty() { None } else { Some(sqls.join(" AND ")) }
        }
        Filter::Or(parts) => {
            let mut sqls = Vec::with_capacity(parts.len());
            for p in parts {
                if let Some(s) = lower_filter(p, binder)? {
                    sqls.push(format!("({s})"));
                }
            }
            Some(if sqls.is_empty() { "0 = 1".to_string() } else { sqls.join(" OR ") })
        }
        Filter::Not(inner) => lower_filter(inner, binder)?.map(|s| format!("NOT ({s})")),
        Filter::Cmp { field, op, value } => {
            let q = quote_ident(field)?;
            let ph = binder.bind(value);
            Some(format!("{q} {} {ph}", cmp_op_sql(*op)))
        }
        Filter::In { field, values } => {
            let q = quote_ident(field)?;
            if values.is_empty() {
                Some("0 = 1".to_string())
            } else {
                let ph: Vec<String> = values.iter().map(|v| binder.bind(v)).collect();
                Some(format!("{q} IN ({})", ph.join(", ")))
            }
        }
        Filter::Like { field, pattern, ci } => {
            let q = quote_ident(field)?;
            let ph = binder.bind(pattern);
            // SQL Server LIKE is case-insensitive under the default collation;
            // force case-sensitivity-independent matching with LOWER() for ci.
            Some(if *ci {
                format!("LOWER({q}) LIKE LOWER({ph})")
            } else {
                format!("{q} LIKE {ph}")
            })
        }
        Filter::Between { field, low, high } => {
            let q = quote_ident(field)?;
            let lo = binder.bind(low);
            let hi = binder.bind(high);
            Some(format!("{q} BETWEEN {lo} AND {hi}"))
        }
        Filter::IsNull { field, negate } => {
            let q = quote_ident(field)?;
            Some(format!("{q} IS {}NULL", if *negate { "NOT " } else { "" }))
        }
    })
}

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

fn render_columns(binder: &mut Binder, columns: &[(String, Value)]) -> DataPlaneResult<(String, String)> {
    let mut col_sql = Vec::with_capacity(columns.len());
    let mut ph = Vec::with_capacity(columns.len());
    for (col, val) in columns {
        col_sql.push(quote_ident(col)?);
        ph.push(binder.bind(val));
    }
    Ok((col_sql.join(", "), ph.join(", ")))
}

fn build_order_by(sort: Option<&BTreeMap<String, String>>) -> DataPlaneResult<Option<String>> {
    let Some(map) = sort else { return Ok(None) };
    if map.is_empty() {
        return Ok(None);
    }
    let mut parts: Vec<String> = Vec::with_capacity(map.len());
    for (col, dir) in map {
        let dir_sql = if dir.eq_ignore_ascii_case("desc") { "DESC" } else { "ASC" };
        parts.push(format!("{} {dir_sql}", quote_ident(col)?));
    }
    Ok(Some(format!(" ORDER BY {}", parts.join(", "))))
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

/// SQL Server identifier quoting (`[col]`, escaping `]` as `]]`).
fn quote_ident(ident: &str) -> DataPlaneResult<String> {
    if ident.is_empty()
        || ident.len() > 128
        || ident.contains('\0')
        || ident.chars().any(char::is_control)
    {
        return Err(DataPlaneError::InvalidIdentifier { value: ident.to_string() });
    }
    Ok(format!("[{}]", ident.replace(']', "]]")))
}

fn json_to_param(value: &Value) -> P {
    match value {
        Value::Null => P::Null,
        Value::Bool(b) => P::Bool(*b),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                P::Int(i)
            } else if let Some(f) = n.as_f64() {
                P::Real(f)
            } else {
                P::Null
            }
        }
        Value::String(s) => P::Text(s.clone()),
        other => P::Text(other.to_string()),
    }
}

fn row_to_json(row: tiberius::Row) -> Value {
    let names: Vec<String> = row.columns().iter().map(|c| c.name().to_string()).collect();
    let mut obj = JsonMap::with_capacity(names.len());
    for (name, cell) in names.into_iter().zip(row.into_iter()) {
        obj.insert(name, column_data_to_json(cell));
    }
    Value::Object(obj)
}

fn column_data_to_json(cell: ColumnData<'static>) -> Value {
    match cell {
        ColumnData::U8(v) => v.map_or(Value::Null, |x| Value::Number(x.into())),
        ColumnData::I16(v) => v.map_or(Value::Null, |x| Value::Number(x.into())),
        ColumnData::I32(v) => v.map_or(Value::Null, |x| Value::Number(x.into())),
        ColumnData::I64(v) => v.map_or(Value::Null, |x| Value::Number(x.into())),
        ColumnData::F32(v) => v.map_or(Value::Null, |x| f64_to_json(f64::from(x))),
        ColumnData::F64(v) => v.map_or(Value::Null, f64_to_json),
        ColumnData::Bit(v) => v.map_or(Value::Null, Value::Bool),
        ColumnData::String(v) => v.map_or(Value::Null, |s| Value::String(s.into_owned())),
        ColumnData::Guid(v) => v.map_or(Value::Null, |g| Value::String(g.to_string())),
        ColumnData::Numeric(v) => v.map_or(Value::Null, |n| Value::String(n.to_string())),
        ColumnData::Binary(v) => v.map_or(Value::Null, |b| Value::String(format!("blob:{} bytes", b.len()))),
        // Date/time/xml variants aren't exercised by the safe CRUD surface; map
        // any remaining variant to a stringified form rather than failing.
        _ => Value::String("<unsupported-column-type>".to_string()),
    }
}

fn f64_to_json(f: f64) -> Value {
    serde_json::Number::from_f64(f).map_or(Value::Null, Value::Number)
}

fn normalize_mssql_type(native: &str) -> NormalizedType {
    let t = native.to_ascii_lowercase();
    if t.contains("int") {
        NormalizedType::Integer
    } else if t.contains("char") || t.contains("text") {
        NormalizedType::Text
    } else if t.contains("real") || t.contains("float") {
        NormalizedType::Float
    } else if t.contains("decimal") || t.contains("numeric") || t.contains("money") {
        NormalizedType::Decimal
    } else if t.contains("bit") {
        NormalizedType::Boolean
    } else if t.contains("date") || t.contains("time") {
        NormalizedType::Datetime
    } else if t.contains("uniqueidentifier") {
        NormalizedType::Uuid
    } else {
        NormalizedType::Unknown
    }
}

fn backend<E: std::fmt::Display>(e: E) -> DataPlaneError {
    let msg = e.to_string();
    let lower = msg.to_ascii_lowercase();
    if lower.contains("unique")
        || lower.contains("duplicate key")
        || lower.contains("primary key")
        || lower.contains("foreign key")
        || lower.contains("cannot insert the value null")
        || lower.contains("constraint")
    {
        DataPlaneError::Conflict { message: format!("mssql constraint: {msg}") }
    } else {
        DataPlaneError::Backend { message: format!("mssql backend: {msg}") }
    }
}

/// Build a tiberius `Config` from a `mssql://user:pass@host:port/db` DSN. The
/// TLS posture is decided by [`apply_mssql_tls`] — tiberius verifies the server
/// cert by default; we only relax that deliberately (never silently).
fn mssql_config(dsn: &str) -> DataPlaneResult<Config> {
    let rest = dsn
        .strip_prefix("mssql://")
        .or_else(|| dsn.strip_prefix("sqlserver://"))
        .ok_or_else(|| DataPlaneError::Backend {
            message: "mssql DSN must start with mssql:// or sqlserver://".to_string(),
        })?;
    // user:pass@host:port/db
    let (creds, hostpart) = rest.split_once('@').ok_or_else(|| DataPlaneError::Backend {
        message: "mssql DSN missing '@' (user:pass@host:port/db)".to_string(),
    })?;
    let (user, pass) = creds.split_once(':').unwrap_or((creds, ""));
    let (host_port, db) = hostpart.split_once('/').unwrap_or((hostpart, "master"));
    let (host, port) = host_port.split_once(':').unwrap_or((host_port, "1433"));
    let port: u16 = port.parse().unwrap_or(1433);

    let mut config = Config::new();
    config.host(host);
    config.port(port);
    config.database(if db.is_empty() { "master" } else { db });
    config.authentication(AuthMethod::sql_server(user, pass));
    apply_mssql_tls(&mut config);
    Ok(config)
}

/// Phase B — the MSSQL TLS posture (closes the unconditional `trust_cert()`
/// hole, which accepted ANY server certificate even under `SECURITY_MODE=max`).
/// tiberius encrypts the connection and, by DEFAULT, verifies the certificate
/// against the native root store. We only override that explicitly:
///
///   * `SECURITY_MODE=max` → never blind-trust. Pin a custom CA when
///     `DATA_PLANE_TLS_CA_FILE` is set, otherwise verify against the native
///     roots. The insecure dev escape is ignored (a self-signed mount fails).
///   * baseline/dev        → a self-signed local SQL Server is accepted ONLY via
///     the explicit `DATA_PLANE_TLS_INSECURE=1` escape (or a pinned CA); without
///     it the chain is still verified.
fn apply_mssql_tls(config: &mut Config) {
    let max_security = std::env::var("SECURITY_MODE")
        .map(|v| v.eq_ignore_ascii_case("max"))
        .unwrap_or(false);
    let ca_file = std::env::var("DATA_PLANE_TLS_CA_FILE").unwrap_or_default();
    let insecure = !max_security
        && std::env::var("DATA_PLANE_TLS_INSECURE").ok().as_deref() == Some("1");
    if insecure {
        config.trust_cert();
    } else if !ca_file.is_empty() {
        config.trust_cert_ca(&ca_file);
    }
    // else: default tiberius behaviour — verify against the native root store.
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ident_quoting_brackets_and_escapes() {
        assert_eq!(quote_ident("name").unwrap(), "[name]");
        assert_eq!(quote_ident("a]b").unwrap(), "[a]]b]");
        assert!(quote_ident("").is_err());
    }

    #[test]
    fn binder_emits_sequential_placeholders() {
        let mut b = Binder::default();
        assert_eq!(b.bind(&serde_json::json!("x")), "@P1");
        assert_eq!(b.bind(&serde_json::json!(2)), "@P2");
        assert_eq!(b.params.len(), 2);
    }

    #[test]
    fn list_synthesizes_order_by_for_offset_fetch() {
        let op = DataOperation {
            op: DataOperationKind::List,
            resource: "t".into(),
            data: None,
            filter: None,
            sort: None,
            limit: Some(10),
            offset: Some(0),
            idempotency_key: None,
            expected_version: None,
            returning: None,
            aggregate: None,
            fields: None,
            search: None,
            vector: None,
        };
        let plan = build_list(&op, Some("u1")).unwrap();
        assert!(plan.sql.contains("ORDER BY (SELECT NULL)"), "{}", plan.sql);
        assert!(plan.sql.contains("OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY"), "{}", plan.sql);
        assert!(plan.sql.contains("[owner_id] = @P1"), "{}", plan.sql);
    }
}
