/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:27:38 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:27:40 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! SQL plan model (`SqlPlan`/`P`/`Binder`) + the pure per-operation plan
//! builders and owner-scoping helpers. All pure (no DB) and testable.
//
// ponytail: ~424 lines, but the plan model, the 7 `build_*` builders, and their
//   owner-scope helpers are one cohesive concern bound by the `&mut Binder`
//   threaded through every builder — unlike the MySQL adapter (whose sink owns
//   its own buffer), the helpers here cannot move to a sibling without a
//   bidirectional `Binder`/`quote_ident` dependency, which would be worse.

use super::convert::json_to_param;
use super::*;

// ── plan model ───────────────────────────────────────────────────────────────

pub(super) struct SqlPlan {
    pub(super) sql: String,
    pub(super) params: Vec<P>,
    pub(super) returns_rows: bool,
}

/// A bound parameter (owned so it outlives the borrow tiberius needs).
pub(super) enum P {
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
pub(super) struct Binder {
    pub(super) params: Vec<P>,
}

impl Binder {
    /// Inherent binder: record a JSON value and return its `@PN` placeholder.
    /// Named distinctly from the trait method below so the trait `bind` can
    /// delegate here without recursing.
    pub(super) fn bind_value(&mut self, value: &Value) -> String {
        self.params.push(json_to_param(value));
        format!("@P{}", self.params.len())
    }
    fn bind_owned(&mut self, p: P) -> String {
        self.params.push(p);
        format!("@P{}", self.params.len())
    }
}

/// SQL Server binds named `@PN` params in declaration order (param order IS
/// binding order), so the shared filter lowerer drives the binder as its sink.
impl crate::sql_scope::SqlParamSink for Binder {
    fn bind(&mut self, value: &Value) -> String {
        self.bind_value(value)
    }
    fn quote_ident(&self, name: &str) -> DataPlaneResult<String> {
        quote_ident(name)
    }
}

// ── plan building (pure) ─────────────────────────────────────────────────────

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

pub(super) fn build_list(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
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
    crate::sql_scope::guard_constraining_filter(op.filter.as_ref(), RESERVED_COLUMNS)?;
    let set_cols = build_safe_columns(op.data.as_ref())?;
    if set_cols.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "update `data` must not be empty".to_string(),
        });
    }
    let mut binder = Binder::default();
    let mut set_parts = Vec::with_capacity(set_cols.len());
    for (col, val) in &set_cols {
        let ph = binder.bind_value(val);
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
    crate::sql_scope::guard_constraining_filter(op.filter.as_ref(), RESERVED_COLUMNS)?;
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
// ponytail: irreducible MERGE builder — conflict-key assembly, ON/UPDATE/INSERT
//   clauses and the cross-owner arbitration form one statement; splitting it
//   would scatter the owner-scoped MERGE invariant.
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
    let conflict_set: std::collections::BTreeSet<&str> =
        match_cols.iter().map(String::as_str).collect();

    let mut binder = Binder::default();
    // Build the source row (VALUES) as @P params with aliased columns.
    let mut src_cols: Vec<String> = Vec::with_capacity(columns.len());
    let mut src_vals: Vec<String> = Vec::with_capacity(columns.len());
    for (col, val) in &columns {
        src_cols.push(quote_ident(col)?);
        src_vals.push(binder.bind_value(val));
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
    let insert_vals = src_cols
        .iter()
        .map(|c| format!("src.{c}"))
        .collect::<Vec<_>>()
        .join(", ");
    let sql = format!(
        "MERGE {table} AS tgt USING (VALUES ({})) AS src ({}) ON {on_clause}{when_matched} \
         WHEN NOT MATCHED THEN INSERT ({insert_cols}) VALUES ({insert_vals});",
        src_vals.join(", "),
        src_cols.join(", ")
    );
    Ok(SqlPlan {
        sql,
        params: binder.params,
        returns_rows: false,
    })
}

// ponytail: irreducible aggregate builder — duplicate-alias guard, group/select
//   assembly and owner-scoped lowering form one query plan; extracting parts
//   would only add indirection without removing logic.
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

pub(super) fn owner_of(identity: &RequestIdentity) -> String {
    identity.owner_principal().to_string()
}

fn build_owner_filter(
    binder: &mut Binder,
    filter: Option<&Value>,
    owner: Option<&str>,
) -> DataPlaneResult<String> {
    let mut clauses: Vec<String> = Vec::new();
    if let Some(filter_value) = filter {
        let cleaned = crate::sql_scope::strip_reserved_top_level(filter_value, RESERVED_COLUMNS);
        let tree = Filter::parse(&cleaned)?;
        if let Some(sql) = crate::sql_scope::lower_filter(&tree, binder)? {
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

fn render_columns(
    binder: &mut Binder,
    columns: &[(String, Value)],
) -> DataPlaneResult<(String, String)> {
    let mut col_sql = Vec::with_capacity(columns.len());
    let mut ph = Vec::with_capacity(columns.len());
    for (col, val) in columns {
        col_sql.push(quote_ident(col)?);
        ph.push(binder.bind_value(val));
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
        let dir_sql = if dir.eq_ignore_ascii_case("desc") {
            "DESC"
        } else {
            "ASC"
        };
        parts.push(format!("{} {dir_sql}", quote_ident(col)?));
    }
    Ok(Some(format!(" ORDER BY {}", parts.join(", "))))
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

/// SQL Server identifier quoting (`[col]`, escaping `]` as `]]`).
pub(super) fn quote_ident(ident: &str) -> DataPlaneResult<String> {
    if ident.is_empty()
        || ident.len() > 128
        || ident.contains('\0')
        || ident.chars().any(char::is_control)
    {
        return Err(DataPlaneError::InvalidIdentifier {
            value: ident.to_string(),
        });
    }
    Ok(format!("[{}]", ident.replace(']', "]]")))
}
