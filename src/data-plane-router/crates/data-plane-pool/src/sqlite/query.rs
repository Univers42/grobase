/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:30:10 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:30:11 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Pure `(sql, params)` plan building, no DB access — the CRUD/aggregate
//! lowering. SQL-building primitives (identifier quoting, owner-scoped filter,
//! column rendering) live in [`super::columns`]; the executors that run these
//! plans live in [`super::exec`] / [`super::writer`].

use data_plane_core::{
    AggFunc, Aggregate, DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult,
};
use rusqlite::types::Value as SqlValue;

use super::columns::{
    build_order_by, build_owned_columns, build_owner_filter, build_safe_columns, quote_ident,
    render_columns, require_object,
};
use super::convert::json_to_sql;
use super::RESERVED_COLUMNS;

/// A built statement: its SQL, positional params, and whether it returns rows.
pub(super) struct SqlPlan {
    pub(super) sql: String,
    pub(super) params: Vec<SqlValue>,
    pub(super) returns_rows: bool,
}

pub(super) fn build_plan(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
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
    let conflict_set: std::collections::BTreeSet<&str> = keys
        .iter()
        .copied()
        .chain(std::iter::once("owner_id"))
        .collect();

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
