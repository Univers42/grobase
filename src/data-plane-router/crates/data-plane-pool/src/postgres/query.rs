/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:29:17 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:29:18 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Read operations: list, get, grouped aggregate — plus the full-text and
//! pgvector search builders the list path layers on.

use super::adapter::PostgresPool;
use super::convert::{as_param_refs, backend};
use super::filter::{append_owner_predicate, build_order_by, build_where, compile_filter, Pred};
use super::search::{build_search, build_vector_order};
use super::BoxedParam;
use crate::ident::quote_ident;
use data_plane_core::{
    AggFunc, Aggregate, DataOperation, DataPlaneError, DataPlaneResult, DataResult, RequestIdentity,
};
use serde_json::Value;

/// Grouped aggregation:
/// `SELECT to_jsonb(g) FROM (SELECT <group cols>, <agg exprs> FROM t WHERE <filter>
/// [GROUP BY <group cols>]) g`. Group columns and the filter are scoped by the
/// per-tenant RLS context (this is a read, like `run_list`). **Safety:** every
/// identifier (group column, aggregate field, alias) goes through `quote_ident`;
/// the aggregate function comes from the allowlisted [`AggFunc`] enum, never
/// client text; filter values are bound parameters.
pub(super) async fn run_aggregate<C: tokio_postgres::GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
    identity: &RequestIdentity,
    scoped: bool,
) -> DataPlaneResult<DataResult> {
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
    // Output column names (group columns + aggregate aliases) must be unique:
    // a collision would make `to_jsonb` silently drop one value.
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
        let ident = quote_ident(col)?;
        select_cols.push(ident.clone());
        group_cols.push(ident);
    }
    for agg in &spec.aggregates {
        select_cols.push(build_aggregate_expr(agg)?);
    }

    let mut params: Vec<BoxedParam> = Vec::new();
    let where_sql = build_where(op.filter.as_ref(), &mut params)?;
    // F1/F2 read owner-scoping: append before LIMIT so the owner `$n` precedes it.
    let owner = scoped.then(|| PostgresPool::principal(identity));
    let where_sql = append_owner_predicate(where_sql, owner, &mut params)?;
    let group_sql = if group_cols.is_empty() {
        String::new()
    } else {
        format!(" GROUP BY {}", group_cols.join(", "))
    };
    // `op.sort` orders the output (a group column or an aggregate alias); `LIMIT`
    // bounds the result so a high-cardinality `group_by` can't return unbounded
    // rows.
    let order_sql = build_order_by(op.sort.as_ref())?;
    let limit = op.limit.unwrap_or(1000).min(10_000) as i64;
    params.push(Box::new(limit));
    let limit_idx = params.len();
    let sql = format!(
        "SELECT to_jsonb(g) AS row FROM (SELECT {} FROM {table} t{where_sql}{group_sql}) g{order_sql} LIMIT ${limit_idx}",
        select_cols.join(", ")
    );
    let rows = client
        .query(sql.as_str(), &as_param_refs(&params))
        .await
        .map_err(|e| backend(&e))?;
    let data: Vec<Value> = rows.iter().map(|r| r.get::<_, Value>("row")).collect();
    let affected = data.len() as u64;
    Ok(DataResult::new(data, affected))
}

/// Builds one `func(arg) AS alias` aggregate expression. `func` is the
/// allowlisted enum; `arg` is `*` for `count` with no field, else the quoted
/// `field`; `sum`/`avg`/`min`/`max` require a field.
pub(super) fn build_aggregate_expr(agg: &Aggregate) -> DataPlaneResult<String> {
    let alias = quote_ident(&agg.alias)?;
    let func = match agg.func {
        AggFunc::Count => "count",
        AggFunc::Sum => "sum",
        AggFunc::Avg => "avg",
        AggFunc::Min => "min",
        AggFunc::Max => "max",
    };
    let arg = match (&agg.field, agg.func) {
        (Some(field), _) => quote_ident(field)?,
        // `count(*)` only without DISTINCT; everything else needs a field.
        (None, AggFunc::Count) if !agg.distinct => "*".to_string(),
        (None, _) => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("aggregate '{func}' requires a `field`"),
            })
        }
    };
    let distinct = if agg.distinct { "DISTINCT " } else { "" };
    Ok(format!("{func}({distinct}{arg}) AS {alias}"))
}

pub(super) async fn run_list<C: tokio_postgres::GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
    identity: &RequestIdentity,
    scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    let mut params: Vec<BoxedParam> = Vec::new();

    // Client filter (a Pred), optionally AND'd with a full-text predicate.
    // Param push order is the source of $n truth: filter params, then the FTS
    // query param, then the owner predicate, then the vector embedding param,
    // then limit/offset.
    let client_pred = compile_filter(op.filter.as_ref(), &mut params)?;
    let fts = op
        .search
        .as_ref()
        .map(|s| build_search(s, &mut params))
        .transpose()?; // Option<(predicate, rank_expr)>
    let where_sql = combine_where(client_pred, fts.as_ref().map(|(p, _)| p.as_str()));
    // F1/F2 read owner-scoping: append after the client/FTS predicate and before
    // the vector + limit/offset params so every `$n` stays monotonic.
    let owner = scoped.then(|| PostgresPool::principal(identity));
    let where_sql = append_owner_predicate(where_sql, owner, &mut params)?;

    // ORDER BY precedence: vector k-NN distance > explicit sort > FTS rank > none.
    let vec_order = op
        .vector
        .as_ref()
        .map(|v| build_vector_order(v, &mut params))
        .transpose()?; // Option<distance_expr>
    let order_sql = if let Some(ord) = &vec_order {
        // nearest first: <=>/<->/<#> are "smaller = closer".
        format!(" ORDER BY {ord} ASC")
    } else if op.sort.as_ref().is_some_and(|s| !s.is_empty()) {
        build_order_by(op.sort.as_ref())?
    } else if let Some((_, rank)) = &fts {
        format!(" ORDER BY {rank} DESC")
    } else {
        String::new()
    };

    // Vector search uses its own `k` as LIMIT; otherwise the usual list paging.
    let limit = op
        .vector
        .as_ref()
        .and_then(|v| v.k)
        .map(|k| k.min(1000))
        .unwrap_or_else(|| op.limit.unwrap_or(100).min(1000)) as i64;
    let offset = op.offset.unwrap_or(0) as i64;
    params.push(Box::new(limit));
    let limit_idx = params.len();
    params.push(Box::new(offset));
    let offset_idx = params.len();

    let sql = format!(
        "SELECT to_jsonb(t) AS row FROM {table} t{where_sql}{order_sql} LIMIT ${limit_idx} OFFSET ${offset_idx}"
    );
    let rows = client
        .query(sql.as_str(), &as_param_refs(&params))
        .await
        .map_err(|e| backend(&e))?;

    let data: Vec<Value> = rows.iter().map(|r| r.get::<_, Value>("row")).collect();
    let affected = data.len() as u64;
    Ok(DataResult::new(data, affected))
}

/// Combine the client filter [`Pred`] with an optional full-text predicate into a
/// single ` WHERE …` clause. The owner predicate is NOT added here — the caller
/// appends it via [`append_owner_predicate`] (gated by F1; OFF → RLS-GUC-only).
fn combine_where(client: Pred, fts: Option<&str>) -> String {
    match (client, fts) {
        (Pred::AlwaysFalse, _) => " WHERE FALSE".to_string(),
        (Pred::Sql(c), Some(f)) => format!(" WHERE ({c}) AND ({f})"),
        (Pred::Sql(c), None) => format!(" WHERE ({c})"),
        (Pred::Unconstrained, Some(f)) => format!(" WHERE ({f})"),
        (Pred::Unconstrained, None) => String::new(),
    }
}

pub(super) async fn run_get<C: tokio_postgres::GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
    identity: &RequestIdentity,
    scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    let mut params: Vec<BoxedParam> = Vec::new();
    let where_sql = build_where(op.filter.as_ref(), &mut params)?;
    let owner = scoped.then(|| PostgresPool::principal(identity));
    let where_sql = append_owner_predicate(where_sql, owner, &mut params)?;

    let sql = format!("SELECT to_jsonb(t) AS row FROM {table} t{where_sql} LIMIT 1");
    let row = client
        .query_opt(sql.as_str(), &as_param_refs(&params))
        .await
        .map_err(|e| backend(&e))?;

    let data: Vec<Value> = row
        .map(|r| vec![r.get::<_, Value>("row")])
        .unwrap_or_default();
    let affected = data.len() as u64;
    Ok(DataResult::new(data, affected))
}

#[cfg(test)]
mod tests {
    use super::*;
    use data_plane_core::DataPlaneError;

    #[test]
    fn aggregate_expr_builds_safe_sql() {
        let agg = |func, field: Option<&str>, alias: &str| Aggregate {
            func,
            field: field.map(str::to_string),
            distinct: false,
            alias: alias.to_string(),
        };
        assert_eq!(
            build_aggregate_expr(&agg(AggFunc::Count, None, "cnt")).unwrap(),
            "count(*) AS \"cnt\""
        );
        assert_eq!(
            build_aggregate_expr(&agg(AggFunc::Sum, Some("amount"), "total")).unwrap(),
            "sum(\"amount\") AS \"total\""
        );
        assert_eq!(
            build_aggregate_expr(&agg(AggFunc::Avg, Some("age"), "avg_age")).unwrap(),
            "avg(\"age\") AS \"avg_age\""
        );
        assert_eq!(
            build_aggregate_expr(&agg(AggFunc::Count, Some("id"), "n")).unwrap(),
            "count(\"id\") AS \"n\""
        );
        // DISTINCT
        let cd = Aggregate {
            func: AggFunc::Count,
            field: Some("email".into()),
            distinct: true,
            alias: "uniq".into(),
        };
        assert_eq!(
            build_aggregate_expr(&cd).unwrap(),
            "count(DISTINCT \"email\") AS \"uniq\""
        );
        // count(DISTINCT *) is invalid → distinct requires a field
        let cd_nofield = Aggregate {
            func: AggFunc::Count,
            field: None,
            distinct: true,
            alias: "x".into(),
        };
        assert!(matches!(
            build_aggregate_expr(&cd_nofield).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
        // sum/avg/min/max require a field
        assert!(matches!(
            build_aggregate_expr(&agg(AggFunc::Sum, None, "x")).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
        // injection in field or alias → InvalidIdentifier (allowlist), never SQL
        assert!(matches!(
            build_aggregate_expr(&agg(AggFunc::Count, Some("a); DROP TABLE t;--"), "x"))
                .unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
        assert!(matches!(
            build_aggregate_expr(&agg(AggFunc::Count, None, "a\" FROM secrets;--")).unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
    }
}
