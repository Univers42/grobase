//! Mutating operations: insert, update, delete, upsert — the effectful runners
//! that dispatch over a live connection. The pure SQL builders they call live
//! in [`super::crud_build`] (testable without a DB).

use super::adapter::PostgresPool;
use super::convert::{as_param_refs, backend, json_param};
use super::crud_build::{build_delete_sql, build_update_sql, build_upsert_sql};
use super::BoxedParam;
use crate::ident::quote_ident;
use data_plane_core::{
    DataOperation, DataPlaneError, DataPlaneResult, DataResult, RequestIdentity, ReturningMode,
};
use serde_json::Value;

pub(super) async fn run_insert<C: tokio_postgres::GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    let Some(Value::Object(map)) = op.data.as_ref() else {
        return Err(DataPlaneError::InvalidRequest {
            message: "insert requires a JSON object in `data`".to_string(),
        });
    };
    if map.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "insert `data` must not be empty".to_string(),
        });
    }

    // Strip any client-supplied owner_id (server controls tenant scope) and
    // re-inject the trusted value from the verified identity. Matches the
    // defensive posture of the Mongo + MySQL adapters. Required because
    // tenant tables typically declare `owner_id NOT NULL` and the per-row
    // RLS policy compares it against `auth.current_user_id()`.
    // On a `tenant_owned` mount the data passes through untouched: the
    // tables are the tenant's own pre-existing schema (no owner_id column)
    // and tenant gating already happened at key→mount resolution.
    let mut columns = Vec::with_capacity(map.len() + 1);
    let mut placeholders = Vec::with_capacity(map.len() + 1);
    let mut params: Vec<BoxedParam> = Vec::with_capacity(map.len() + 1);
    let mut saw_owner_id = false;
    for (col, val) in map {
        if owner_scoped && col == "owner_id" {
            // drop client override; trusted value injected below
            saw_owner_id = true;
            continue;
        }
        columns.push(quote_ident(col)?);
        params.push(json_param(val));
        placeholders.push(format!("${}", params.len()));
    }
    let _ = saw_owner_id; // reserved for future audit logging
    if owner_scoped {
        let owner = PostgresPool::principal(identity).to_string();
        columns.push(quote_ident("owner_id")?);
        params.push(Box::new(owner));
        placeholders.push(format!("${}", params.len()));
    }

    let sql = format!(
        "INSERT INTO {table} AS t ({}) VALUES ({}) RETURNING to_jsonb(t) AS row",
        columns.join(", "),
        placeholders.join(", ")
    );
    let row = client
        .query_one(sql.as_str(), &as_param_refs(&params))
        .await
        .map_err(|e| backend(&e))?;

    Ok(DataResult::new(vec![row.get::<_, Value>("row")], 1))
}

/// Run a mutating statement. With `want_rows`, RETURNING rows are collected and
/// counted; otherwise `execute` returns the affected count with no row
/// materialisation. Used by update/delete/upsert alike — so an RLS-suppressed
/// upsert `DO UPDATE` is an honest 0-row result, not a `query_one` 500.
async fn execute_mutation<C: tokio_postgres::GenericClient + Sync>(
    client: &C,
    sql: &str,
    params: &[BoxedParam],
    want_rows: bool,
) -> DataPlaneResult<DataResult> {
    if want_rows {
        let rows = client
            .query(sql, &as_param_refs(params))
            .await
            .map_err(|e| backend(&e))?;
        let data: Vec<Value> = rows.iter().map(|r| r.get::<_, Value>("row")).collect();
        let affected = data.len() as u64;
        Ok(DataResult::new(data, affected))
    } else {
        let affected = client
            .execute(sql, &as_param_refs(params))
            .await
            .map_err(|e| backend(&e))?;
        Ok(DataResult::new(vec![], affected))
    }
}

/// `UPDATE … SET … WHERE … AND owner_id = $ RETURNING` — single round-trip,
/// required filter, owner-scoped, owner_id immutable. Honors `ReturningMode`.
pub(super) async fn run_update<C: tokio_postgres::GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    let Some(Value::Object(data)) = op.data.as_ref() else {
        return Err(DataPlaneError::InvalidRequest {
            message: "update requires a JSON object in `data`".to_string(),
        });
    };
    // `tenant_owned` mounts pass None → no owner predicate/injection.
    let principal = PostgresPool::principal(identity).to_string();
    let owner = owner_scoped.then_some(principal.as_str());
    let want_rows = !matches!(op.returning, Some(ReturningMode::None));
    let (sql, params) = build_update_sql(&table, data, op.filter.as_ref(), owner, want_rows)?;
    execute_mutation(client, &sql, &params, want_rows).await
}

/// `DELETE … WHERE … AND owner_id = $ RETURNING` — owner-scoped, required
/// filter. Honors `ReturningMode`.
pub(super) async fn run_delete<C: tokio_postgres::GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    // `tenant_owned` mounts pass None → no owner predicate/injection.
    let principal = PostgresPool::principal(identity).to_string();
    let owner = owner_scoped.then_some(principal.as_str());
    let want_rows = !matches!(op.returning, Some(ReturningMode::None));
    let (sql, params) = build_delete_sql(&table, op.filter.as_ref(), owner, want_rows)?;
    execute_mutation(client, &sql, &params, want_rows).await
}

/// `INSERT … AS t ON CONFLICT (owner_id, key…) DO UPDATE …`. Conflict key(s)
/// from `filter`; written columns from `data`; `owner_id` server-injected, part
/// of the conflict target (tenant-local arbitration) and immutable on conflict.
/// Uses `execute_mutation` (not `query_one`) so an RLS-suppressed `DO UPDATE` is
/// an honest 0-row result. Target table must have a UNIQUE index on
/// (owner_id, <conflict key(s)>). Honors `ReturningMode`.
pub(super) async fn run_upsert<C: tokio_postgres::GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    let Some(Value::Object(data)) = op.data.as_ref() else {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert requires a JSON object in `data`".to_string(),
        });
    };
    let Some(Value::Object(filter)) = op.filter.as_ref() else {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert requires `filter` naming the conflict key column(s)".to_string(),
        });
    };
    // `tenant_owned` mounts pass None → no owner predicate/injection.
    let principal = PostgresPool::principal(identity).to_string();
    let owner = owner_scoped.then_some(principal.as_str());
    let want_rows = !matches!(op.returning, Some(ReturningMode::None));
    let (sql, params) = build_upsert_sql(&table, data, filter, owner, want_rows)?;
    execute_mutation(client, &sql, &params, want_rows).await
}
