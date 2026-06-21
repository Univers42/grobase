/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   columns.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:29:54 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:29:55 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! SQL-building primitives shared by the plan builders: identifier quoting, the
//! owner-scoped `WHERE` intersection, column-set extraction/rendering, and
//! `ORDER BY` lowering. Pure — no DB access.

use data_plane_core::{DataPlaneError, DataPlaneResult, Filter};
use rusqlite::types::Value as SqlValue;
use serde_json::{Map as JsonMap, Value};
use std::collections::BTreeMap;

use super::convert::json_to_sql;
use super::RESERVED_COLUMNS;

/// `WHERE` clause that intersects the (reserved-stripped) client filter with the
/// trusted `owner_id` predicate. `owner: None` (tenant_owned) emits the client
/// filter only — but still requires a `WHERE` to avoid an unscoped statement
/// when a filter is present; an absent filter yields an empty clause (caller
/// guards mass mutations separately).
/// SQLite binds every value as a positional `?` (param order IS binding order),
/// so the shared filter lowerer pushes through this sink.
struct SqliteSink(Vec<SqlValue>);

impl crate::sql_scope::SqlParamSink for SqliteSink {
    fn bind(&mut self, value: &Value) -> String {
        self.0.push(json_to_sql(value));
        "?".to_string()
    }
    fn quote_ident(&self, name: &str) -> DataPlaneResult<String> {
        quote_ident(name)
    }
}

pub(super) fn build_owner_filter(
    filter: Option<&Value>,
    owner: Option<&str>,
) -> DataPlaneResult<(String, Vec<SqlValue>)> {
    let mut sink = SqliteSink(Vec::new());
    let mut clauses: Vec<String> = Vec::new();
    if let Some(filter_value) = filter {
        let cleaned = crate::sql_scope::strip_reserved_top_level(filter_value, RESERVED_COLUMNS);
        let tree = Filter::parse(&cleaned)?;
        if let Some(sql) = crate::sql_scope::lower_filter(&tree, &mut sink)? {
            clauses.push(format!("({sql})"));
        }
    }
    if let Some(owner) = owner {
        sink.0.push(SqlValue::Text(owner.to_string()));
        clauses.push("\"owner_id\" = ?".to_string());
    }
    let params = sink.0;
    if clauses.is_empty() {
        Ok((String::new(), params))
    } else {
        Ok((format!(" WHERE {}", clauses.join(" AND ")), params))
    }
}

/// INSERT/UPSERT column set: strip reserved client columns, re-inject the
/// trusted `owner_id` when owner-scoped.
pub(super) fn build_owned_columns(
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

pub(super) fn build_safe_columns(data: Option<&Value>) -> DataPlaneResult<Vec<(String, Value)>> {
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

/// Render `(col, col, …)`, `(?, ?, …)` and the matching param vector.
pub(super) fn render_columns(
    columns: &[(String, Value)],
) -> DataPlaneResult<(String, String, Vec<SqlValue>)> {
    let mut col_sql = Vec::with_capacity(columns.len());
    let mut ph = Vec::with_capacity(columns.len());
    let mut params = Vec::with_capacity(columns.len());
    for (col, val) in columns {
        col_sql.push(quote_ident(col)?);
        ph.push("?".to_string());
        params.push(json_to_sql(val));
    }
    Ok((col_sql.join(", "), ph.join(", "), params))
}

pub(super) fn build_order_by(sort: Option<&BTreeMap<String, String>>) -> DataPlaneResult<String> {
    let Some(map) = sort else {
        return Ok(String::new());
    };
    if map.is_empty() {
        return Ok(String::new());
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
    Ok(format!(" ORDER BY {}", parts.join(", ")))
}

pub(super) fn require_object<'a>(
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

/// SQLite identifier quoting (`"col"`). Rejects identifiers containing a double
/// quote, NUL, or control chars so a crafted field name can't break out.
pub(super) fn quote_ident(ident: &str) -> DataPlaneResult<String> {
    if ident.is_empty()
        || ident.len() > 128
        || ident.contains('"')
        || ident.contains('\0')
        || ident.chars().any(char::is_control)
    {
        return Err(DataPlaneError::InvalidIdentifier {
            value: ident.to_string(),
        });
    }
    Ok(format!("\"{ident}\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owner_filter_always_scopes_when_owner_present() {
        let (sql, params) =
            build_owner_filter(Some(&serde_json::json!({"id": "x"})), Some("u1")).unwrap();
        assert!(sql.contains("\"owner_id\" = ?"), "{sql}");
        assert_eq!(params.len(), 2);
    }

    // ── identifier quoting: valid + injection rejection ──────────────────────

    #[test]
    fn ident_quoting_rejects_injection() {
        assert_eq!(quote_ident("name").unwrap(), "\"name\"");
        assert!(quote_ident("a\"; DROP TABLE x; --").is_err());
        assert!(quote_ident("").is_err());
    }

    #[test]
    fn quote_ident_accepts_ordinary_names() {
        for ok in ["a", "name", "_x", "col1", "Owner_Id", "a b c", "select"] {
            // SQLite allows spaces inside a quoted identifier; only the quote/
            // NUL/control bytes are barred.
            assert_eq!(quote_ident(ok).unwrap(), format!("\"{ok}\""), "{ok}");
        }
    }

    #[test]
    fn quote_ident_rejects_quote_nul_and_control() {
        for bad in ["", "a\"b", "a\0b", "a\tb", "a\nb", "a\rb", "x\x07y"] {
            assert!(quote_ident(bad).is_err(), "should reject {bad:?}");
        }
    }

    #[test]
    fn quote_ident_rejects_overlong_identifier() {
        let ok = "a".repeat(128);
        assert!(quote_ident(&ok).is_ok(), "128 chars is the limit");
        let too_long = "a".repeat(129);
        assert!(quote_ident(&too_long).is_err(), "129 chars is rejected");
    }

    #[test]
    fn quote_ident_escapes_nothing_so_embedded_quote_is_refused() {
        // The contract is reject-not-escape for double quotes: a name with a "
        // never produces an escaped identifier, it errors.
        assert!(quote_ident("a\";DROP TABLE x;--").is_err());
        assert!(quote_ident("\"injected\"").is_err());
    }
}
