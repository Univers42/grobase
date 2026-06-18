//! CRUD operation implementations — the per-operation SQL statement builders.
//!
//! Each op owner-scopes via [`super::scope`] (every read intersects
//! `owner_id = ?`; every write re-stamps `owner_id`); the binding/filter
//! helpers live there, the statement assembly lives here.
//
// ponytail: ~326 lines, just over 300, but the 7 `run_*` builders + the
//   aggregate-expr helper are one concern (the engine's SQL surface); the
//   reusable owner-scope/bind helpers were already split to `scope`. Splitting
//   the builders further (read vs write) would scatter shared lowering.

use super::convert::{json_to_mysql_value, row_to_json};
use super::error::backend;
use super::scope::{
    build_order_by, build_owned_columns, build_owner_filter, build_safe_columns,
    render_insert_columns,
};
use super::*;

// ── operation implementations ───────────────────────────────────────────────

pub(super) async fn run_list(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
    scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), identity, scoped)?;
    let order_sql = build_order_by(op.sort.as_ref())?;
    let limit = op.limit.unwrap_or(100).min(500);
    let offset = op.offset.unwrap_or(0);

    let sql = format!("SELECT * FROM {table}{where_sql}{order_sql} LIMIT {limit} OFFSET {offset}");
    let rows: Vec<Row> = q
        .exec(sql.as_str(), Params::Positional(params))
        .await
        .map_err(backend)?;

    let data: Vec<Value> = rows.into_iter().map(row_to_json).collect();
    let affected = data.len() as u64;
    Ok(DataResult::new(data, affected))
}

pub(super) async fn run_get(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
    scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), identity, scoped)?;

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

pub(super) async fn run_insert(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
    scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let columns = build_owned_columns(op.data.as_ref(), identity, scoped)?;
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

pub(super) async fn run_update(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
    scoped: bool,
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

    let (where_sql, mut where_params) = build_owner_filter(op.filter.as_ref(), identity, scoped)?;
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

pub(super) async fn run_delete(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
    scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    crate::sql_scope::guard_constraining_filter(op.filter.as_ref(), &RESERVED_COLUMNS)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), identity, scoped)?;

    let sql = format!("DELETE FROM {table}{where_sql}");
    let result = q
        .exec_iter(sql.as_str(), Params::Positional(params))
        .await
        .map_err(backend)?;
    let affected = result.affected_rows();
    result.drop_result().await.map_err(backend)?;
    Ok(DataResult::new(vec![], affected))
}

// ponytail: irreducible CRUD builder — the cross-owner MERGE/ON-DUPLICATE-KEY
//   guard (no owner reassignment + `IF(owner_id = VALUES(...))` per column) is
//   one security-critical unit; splitting it would scatter the invariant.
pub(super) async fn run_upsert(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
    scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let columns = build_owned_columns(op.data.as_ref(), identity, scoped)?;
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
// ponytail: irreducible aggregate builder — duplicate-alias guard, group/select
//   assembly and owner-scoped lowering form one query plan; extracting parts
//   would only add indirection without removing logic.
pub(super) async fn run_aggregate(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
    scoped: bool,
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

    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), identity, scoped)?;
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
