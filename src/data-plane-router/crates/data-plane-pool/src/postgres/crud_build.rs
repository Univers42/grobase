/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   crud_build.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:29:02 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:29:03 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Pure mutating-op SQL builders — the testable-without-a-DB half of [`super::crud`].
//!
//! Each assembles the SQL + bound params for a mutating op. Invariants enforced
//! here (so they're testable without a live DB):
//!   * identifiers via `quote_ident` (allowlist), values via bound `$n` params;
//!   * column order canonicalised (sorted) → one cached prepared statement per
//!     shape regardless of JSON key order (serde_json preserves wire order here);
//!   * `owner_id` server-controlled — stripped from client `data`, injected as
//!     the trusted value, kept out of any SET, and added as a WHERE / conflict
//!     predicate (defense in depth alongside RLS, matching the Mongo/MySQL
//!     adapters);
//!   * target table aliased `t` so `to_jsonb(t)` is correct even for a
//!     schema-qualified resource;
//!   * `returning=false` omits RETURNING (count-only, no row materialisation) —
//!     honoring `ReturningMode::None`.

use super::convert::json_param;
use super::filter::build_where;
use super::BoxedParam;
use crate::ident::quote_ident;
use data_plane_core::{DataPlaneError, DataPlaneResult};
use serde_json::Value;

/// Sorted, owner_id-stripped (column, value) pairs from a JSON object.
pub(super) fn writable_columns(data: &serde_json::Map<String, Value>) -> Vec<(&str, &Value)> {
    let mut cols: Vec<(&str, &Value)> = data
        .iter()
        .filter(|(k, _)| k.as_str() != "owner_id")
        .map(|(k, v)| (k.as_str(), v))
        .collect();
    cols.sort_by(|a, b| a.0.cmp(b.0));
    cols
}

/// ` AND owner_id = $n` for owner-scoped mounts; empty for `tenant_owned`
/// (`owner: None`) — the tables are the tenant's own schema, no such column.
fn owner_predicate(owner: Option<&str>, params: &mut Vec<BoxedParam>) -> DataPlaneResult<String> {
    match owner {
        Some(principal) => {
            params.push(Box::new(principal.to_string()));
            Ok(format!(
                " AND {} = ${}",
                quote_ident("owner_id")?,
                params.len()
            ))
        }
        None => Ok(String::new()),
    }
}

pub(super) fn build_update_sql(
    table: &str,
    data: &serde_json::Map<String, Value>,
    filter: Option<&Value>,
    owner: Option<&str>,
    returning: bool,
) -> DataPlaneResult<(String, Vec<BoxedParam>)> {
    let mut params: Vec<BoxedParam> = Vec::with_capacity(data.len() + 2);
    let mut assignments: Vec<String> = Vec::with_capacity(data.len());
    for (col, val) in writable_columns(data) {
        let ident = quote_ident(col)?;
        params.push(json_param(val));
        assignments.push(format!("{ident} = ${}", params.len()));
    }
    if assignments.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "update `data` has no updatable columns".to_string(),
        });
    }
    let where_sql = build_where(filter, &mut params)?;
    if where_sql.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "update requires a non-empty `filter` (refusing full-table update)"
                .to_string(),
        });
    }
    let owner_pred = owner_predicate(owner, &mut params)?;
    let ret = if returning {
        " RETURNING to_jsonb(t) AS row"
    } else {
        ""
    };
    let sql = format!(
        "UPDATE {table} AS t SET {}{where_sql}{owner_pred}{ret}",
        assignments.join(", ")
    );
    Ok((sql, params))
}

pub(super) fn build_delete_sql(
    table: &str,
    filter: Option<&Value>,
    owner: Option<&str>,
    returning: bool,
) -> DataPlaneResult<(String, Vec<BoxedParam>)> {
    let mut params: Vec<BoxedParam> = Vec::with_capacity(4);
    let where_sql = build_where(filter, &mut params)?;
    if where_sql.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "delete requires a non-empty `filter` (refusing full-table delete)"
                .to_string(),
        });
    }
    let owner_pred = owner_predicate(owner, &mut params)?;
    let ret = if returning {
        " RETURNING to_jsonb(t) AS row"
    } else {
        ""
    };
    let sql = format!("DELETE FROM {table} AS t{where_sql}{owner_pred}{ret}");
    Ok((sql, params))
}

pub(super) fn build_upsert_sql(
    table: &str,
    data: &serde_json::Map<String, Value>,
    filter: &serde_json::Map<String, Value>,
    owner: Option<&str>,
    returning: bool,
) -> DataPlaneResult<(String, Vec<BoxedParam>)> {
    let cap = data.len() + filter.len() + 1;
    let mut columns: Vec<String> = Vec::with_capacity(cap);
    let mut placeholders: Vec<String> = Vec::with_capacity(cap);
    let mut params: Vec<BoxedParam> = Vec::with_capacity(cap);
    // owner_id is part of the conflict target so ON CONFLICT arbitration (done
    // at the unique index, below RLS) is tenant-local — a tenant cannot collide
    // with another tenant's row. Requires a UNIQUE index on (owner_id, key…).
    // `tenant_owned` mounts (owner: None) arbitrate on the caller's keys only:
    // the whole database is one tenant's, so there is no cross-tenant index.
    let mut conflict_cols: Vec<String> = match owner {
        Some(_) => vec![quote_ident("owner_id")?],
        None => Vec::new(),
    };
    let mut seen: std::collections::BTreeSet<&str> = std::collections::BTreeSet::new();
    seen.insert("owner_id");

    let mut keys: Vec<(&str, &Value)> = filter
        .iter()
        .filter(|(k, _)| k.as_str() != "owner_id")
        .map(|(k, v)| (k.as_str(), v))
        .collect();
    keys.sort_by(|a, b| a.0.cmp(b.0));
    let first_key_ident = keys.first().map(|(col, _)| quote_ident(col)).transpose()?;
    for (col, val) in keys {
        let ident = quote_ident(col)?;
        conflict_cols.push(ident.clone());
        columns.push(ident);
        params.push(json_param(val));
        placeholders.push(format!("${}", params.len()));
        seen.insert(col);
    }
    let Some(first_key_ident) = first_key_ident else {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert `filter` (conflict key) must not be empty".to_string(),
        });
    };

    let mut assignments: Vec<String> = Vec::new();
    for (col, val) in writable_columns(data) {
        if seen.contains(col) {
            continue;
        }
        let ident = quote_ident(col)?;
        columns.push(ident.clone());
        params.push(json_param(val));
        placeholders.push(format!("${}", params.len()));
        assignments.push(format!("{ident} = EXCLUDED.{ident}"));
        seen.insert(col);
    }

    // owner_id value, server-injected (immutable on conflict → not in SET).
    if let Some(principal) = owner {
        columns.push(quote_ident("owner_id")?);
        params.push(Box::new(principal.to_string()));
        placeholders.push(format!("${}", params.len()));
    }

    if assignments.is_empty() {
        // Only key columns supplied → re-assert a conflict key (no-op SET) so
        // DO UPDATE fires and RETURNING still yields the row.
        assignments.push(format!("{first_key_ident} = EXCLUDED.{first_key_ident}"));
    }

    let ret = if returning {
        " RETURNING to_jsonb(t) AS row"
    } else {
        ""
    };
    let sql = format!(
        "INSERT INTO {table} AS t ({}) VALUES ({}) ON CONFLICT ({}) DO UPDATE SET {}{ret}",
        columns.join(", "),
        placeholders.join(", "),
        conflict_cols.join(", "),
        assignments.join(", ")
    );
    Ok((sql, params))
}

#[cfg(test)]
mod tests {
    use super::super::ddl::build_pg_ddl;
    use super::*;
    use data_plane_core::{DdlColumnDef, NormalizedType, SchemaDdlOp, SchemaDdlRequest};
    use serde_json::json;

    fn obj(v: Value) -> serde_json::Map<String, Value> {
        match v {
            Value::Object(m) => m,
            _ => panic!("expected a JSON object"),
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
    fn update_strips_owner_id_and_scopes_to_owner() {
        let data = obj(json!({ "owner_id": "attacker", "name": "ok" }));
        let filter = json!({ "id": 1 });
        let (sql, params) =
            build_update_sql("\"t\"", &data, Some(&filter), Some("u-trusted"), true).unwrap();
        assert!(sql.starts_with("UPDATE \"t\" AS t SET "), "{sql}");
        assert!(sql.contains("\"name\" = $1"), "{sql}");
        assert!(
            !sql.contains("SET \"owner_id\""),
            "owner_id must not be settable: {sql}"
        );
        assert!(
            sql.contains(" AND \"owner_id\" = $3"),
            "owner predicate missing: {sql}"
        );
        assert!(sql.contains("RETURNING to_jsonb(t)"), "{sql}");
        assert_eq!(params.len(), 3); // name, filter id, owner
    }

    #[test]
    fn tenant_owned_writes_have_no_owner_sql() {
        // `owner: None` (Isolation::TenantOwned): the tenant's own pre-existing
        // tables have no owner_id column — any owner SQL would 42703.
        let data = obj(json!({ "name": "ok" }));
        let filter = json!({ "id": 1 });
        let (sql, params) = build_update_sql("\"t\"", &data, Some(&filter), None, true).unwrap();
        assert!(!sql.contains("owner_id"), "{sql}");
        assert_eq!(params.len(), 2); // name + filter id only
                                     // The full-table refusals are isolation-independent.
        assert!(build_update_sql("\"t\"", &data, None, None, true).is_err());

        let (sql, params) = build_delete_sql("\"t\"", Some(&filter), None, true).unwrap();
        assert!(!sql.contains("owner_id"), "{sql}");
        assert_eq!(params.len(), 1);
        assert!(build_delete_sql("\"t\"", None, None, true).is_err());

        let (sql, _) = build_upsert_sql(
            "\"t\"",
            &obj(json!({ "name": "ok" })),
            &obj(json!({ "email": "a@b.c" })),
            None,
            true,
        )
        .unwrap();
        assert!(
            sql.contains("ON CONFLICT (\"email\")"),
            "caller keys only: {sql}"
        );
        assert!(!sql.contains("owner_id"), "{sql}");

        // CreateTable DDL: no owner_id synthesis on tenant_owned mounts.
        let mut req = ddl(SchemaDdlOp::CreateTable, "t");
        req.columns = Some(vec![DdlColumnDef {
            name: "id".into(),
            normalized_type: NormalizedType::Integer,
            nullable: false,
            default: None,
            enum_values: None,
        }]);
        req.primary_key = Some(vec!["id".into()]);
        let plan = build_pg_ddl("public", &req, false).unwrap();
        assert!(
            !plan.statements[0].contains("owner_id"),
            "{}",
            plan.statements[0]
        );
        let scoped = build_pg_ddl("public", &req, true).unwrap();
        assert!(
            scoped.statements[0].contains("owner_id"),
            "{}",
            scoped.statements[0]
        );
    }

    #[test]
    fn update_refuses_empty_filter() {
        let data = obj(json!({ "name": "x" }));
        // A refused mutation is a client error (400), never a 5xx backend error.
        let err = build_update_sql("\"t\"", &data, None, Some("u"), true).unwrap_err();
        assert!(
            matches!(err, DataPlaneError::InvalidRequest { .. }),
            "{err:?}"
        );
        assert!(build_update_sql("\"t\"", &data, Some(&json!({})), Some("u"), true).is_err());
    }

    #[test]
    fn update_rejects_injection_in_column_name() {
        let data = obj(json!({ "evil;--": 1 }));
        let err = build_update_sql("\"t\"", &data, Some(&json!({ "id": 1 })), Some("u"), true)
            .unwrap_err();
        assert!(
            matches!(err, DataPlaneError::InvalidIdentifier { .. }),
            "{err:?}"
        );
    }

    #[test]
    fn columns_sorted_for_statement_cache() {
        let data = obj(json!({ "b": 1, "a": 2 }));
        let (sql, _) =
            build_update_sql("\"t\"", &data, Some(&json!({ "id": 1 })), Some("u"), true).unwrap();
        assert!(
            sql.find("\"a\"").unwrap() < sql.find("\"b\"").unwrap(),
            "{sql}"
        );
    }

    #[test]
    fn returning_false_omits_returning_clause() {
        let data = obj(json!({ "name": "x" }));
        let (sql, _) =
            build_update_sql("\"t\"", &data, Some(&json!({ "id": 1 })), Some("u"), false).unwrap();
        assert!(!sql.contains("RETURNING"), "{sql}");
    }

    #[test]
    fn delete_scopes_owner_and_refuses_empty_filter() {
        let err = build_delete_sql("\"t\"", None, Some("u"), true).unwrap_err();
        assert!(
            matches!(err, DataPlaneError::InvalidRequest { .. }),
            "{err:?}"
        );
        let (sql, params) =
            build_delete_sql("\"t\"", Some(&json!({ "id": 1 })), Some("u-t"), true).unwrap();
        assert!(sql.starts_with("DELETE FROM \"t\" AS t"), "{sql}");
        assert!(sql.contains(" AND \"owner_id\" = $2"), "{sql}");
        assert_eq!(params.len(), 2);
    }

    #[test]
    fn upsert_forces_owner_into_conflict_target() {
        let data = obj(json!({ "name": "x" }));
        let filter = obj(json!({ "email": "a@b.c" }));
        let (sql, _) = build_upsert_sql("\"t\"", &data, &filter, Some("u"), true).unwrap();
        assert!(
            sql.contains("ON CONFLICT (\"owner_id\", \"email\")"),
            "{sql}"
        );
        assert!(sql.contains("\"name\" = EXCLUDED.\"name\""), "{sql}");
        assert!(
            !sql.contains("\"owner_id\" = EXCLUDED"),
            "owner must be immutable on conflict: {sql}"
        );
        assert!(sql.starts_with("INSERT INTO \"t\" AS t ("), "{sql}");
    }

    #[test]
    fn upsert_requires_a_real_conflict_key() {
        let data = obj(json!({ "name": "x" }));
        assert!(build_upsert_sql("\"t\"", &data, &obj(json!({})), Some("u"), true).is_err());
        assert!(build_upsert_sql(
            "\"t\"",
            &data,
            &obj(json!({ "owner_id": "x" })),
            Some("u"),
            true
        )
        .is_err());
    }

    #[test]
    fn upsert_key_only_data_uses_noop_set() {
        let data = obj(json!({}));
        let filter = obj(json!({ "id": 1 }));
        let (sql, _) = build_upsert_sql("\"t\"", &data, &filter, Some("u"), true).unwrap();
        assert!(
            sql.contains("DO UPDATE SET \"id\" = EXCLUDED.\"id\""),
            "{sql}"
        );
    }
}
