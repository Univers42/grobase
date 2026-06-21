/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:28:47 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:28:48 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Schema introspection type-mapping + the pure DDL SQL builders (M22 step 2).
//!
//! All pure (testable without a DB). Identifiers via `quote_mysql_ident`; enum
//! VALUES are escaped string literals (`mysql_literal`, which doubles quotes
//! AND escapes backslash — MySQL's default sql_mode treats `\` as an escape);
//! caller DEFAULT expressions pass the shared `validate_default_expr` guard.

use super::*;

/// Maps a MySQL `COLUMN_TYPE` (the full rendered type, e.g. `varchar(255)`,
/// `enum('a','b')`, `tinyint(1) unsigned`) to the engine-neutral
/// [`NormalizedType`], returning the parsed enum labels for `enum(...)` types.
/// Pure — testable without a DB.
pub(super) fn normalize_mysql_type(column_type: &str) -> (NormalizedType, Option<Vec<String>>) {
    let lower = column_type.trim().to_ascii_lowercase();
    if lower.starts_with("enum(") {
        return (
            NormalizedType::Enum,
            Some(parse_mysql_enum_values(column_type)),
        );
    }
    // `tinyint(1)` (the MySQL boolean convention) before the generic int arm.
    if lower == "tinyint(1)" || lower.starts_with("tinyint(1) ") {
        return (NormalizedType::Boolean, None);
    }
    let base = lower.split(['(', ' ']).next().unwrap_or("");
    let ty = match base {
        "int" | "integer" | "bigint" | "smallint" | "mediumint" | "tinyint" => {
            NormalizedType::Integer
        }
        "float" | "double" => NormalizedType::Float,
        "decimal" | "numeric" => NormalizedType::Decimal,
        "date" => NormalizedType::Date,
        "datetime" | "timestamp" => NormalizedType::Datetime,
        "json" => NormalizedType::Json,
        "char" | "varchar" | "text" | "tinytext" | "mediumtext" | "longtext" => {
            NormalizedType::Text
        }
        _ => NormalizedType::Unknown,
    };
    (ty, None)
}

/// `'…'`-quoted MySQL string literal.
pub(super) fn mysql_literal(value: &str) -> String {
    format!("'{}'", value.replace('\\', "\\\\").replace('\'', "''"))
}

/// Reverse type mapping (the inverse of [`normalize_mysql_type`]): lowers a
/// [`DdlColumnDef`] to its MySQL column type SQL. `in_primary_key` switches
/// text to `VARCHAR(255)` — `TEXT` cannot be a PK without a prefix length.
/// `objectid`/`unknown` are describe-only and rejected.
pub(super) fn mysql_sql_type(def: &DdlColumnDef, in_primary_key: bool) -> DataPlaneResult<String> {
    Ok(match def.normalized_type {
        NormalizedType::Text => {
            if in_primary_key {
                "VARCHAR(255)".to_string()
            } else {
                "TEXT".to_string()
            }
        }
        NormalizedType::Integer => "BIGINT".to_string(),
        NormalizedType::Float => "DOUBLE".to_string(),
        NormalizedType::Decimal => "DECIMAL(18,6)".to_string(),
        NormalizedType::Boolean => "TINYINT(1)".to_string(),
        NormalizedType::Date => "DATE".to_string(),
        NormalizedType::Datetime => "DATETIME".to_string(),
        NormalizedType::Json => "JSON".to_string(),
        NormalizedType::Uuid => "CHAR(36)".to_string(),
        // v1: arrays land in JSON (MySQL has no array type).
        NormalizedType::Array => "JSON".to_string(),
        NormalizedType::Enum => {
            let values = def
                .enum_values
                .as_deref()
                .filter(|v| !v.is_empty())
                .ok_or_else(|| DataPlaneError::InvalidRequest {
                    message: format!("enum column '{}' requires non-empty enum_values", def.name),
                })?;
            let literals: Vec<String> = values.iter().map(|v| mysql_literal(v)).collect();
            format!("ENUM({})", literals.join(", "))
        }
        NormalizedType::Objectid | NormalizedType::Unknown => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!(
                    "column '{}': normalized_type '{:?}' cannot be created on mysql",
                    def.name, def.normalized_type
                ),
            })
        }
    })
}

/// One full column clause: `` `name` TYPE NULL|NOT NULL [DEFAULT expr] ``.
/// Nullability is ALWAYS rendered (`NULL` explicitly) because `MODIFY COLUMN`
/// resets every attribute — the caller sends the full target def precisely so
/// nothing is silently lost.
pub(super) fn mysql_column_clause(
    def: &DdlColumnDef,
    in_primary_key: bool,
) -> DataPlaneResult<String> {
    let col = quote_mysql_ident(&def.name)?;
    let ty = mysql_sql_type(def, in_primary_key)?;
    let mut clause = format!(
        "{col} {ty} {}",
        if def.nullable { "NULL" } else { "NOT NULL" }
    );
    if let Some(default) = def.default.as_deref() {
        validate_default_expr(default)?;
        clause.push_str(&format!(" DEFAULT {default}"));
    }
    Ok(clause)
}

/// Lowers a [`SchemaDdlRequest`] to its single MySQL DDL statement
/// (namespace selection happens at the connection via `USE`, mirroring the
/// request path, so statements stay unqualified).
// ponytail: irreducible DDL builder — one arm per `SchemaDdlOp`; the CREATE arm
//   carries the owner_id-injection invariant (every owner-scoped table gets the
//   column) which must stay co-located with the column assembly.
pub(super) fn build_mysql_ddl(ddl: &SchemaDdlRequest) -> DataPlaneResult<String> {
    let table = quote_mysql_ident(&ddl.table)?;
    Ok(match ddl.op {
        SchemaDdlOp::AddColumn => format!(
            "ALTER TABLE {table} ADD COLUMN {}",
            mysql_column_clause(ddl.require_column()?, false)?
        ),
        SchemaDdlOp::DropColumn => format!(
            "ALTER TABLE {table} DROP COLUMN {}",
            quote_mysql_ident(ddl.require_column_name()?)?
        ),
        // MODIFY COLUMN resets attributes — full target def by contract.
        SchemaDdlOp::AlterColumnType => format!(
            "ALTER TABLE {table} MODIFY COLUMN {}",
            mysql_column_clause(ddl.require_column()?, false)?
        ),
        SchemaDdlOp::CreateTable => {
            let (columns, primary_key) = ddl.require_create_spec()?;
            let pk_set: std::collections::BTreeSet<&str> =
                primary_key.iter().map(String::as_str).collect();
            let mut clauses = Vec::with_capacity(columns.len() + 2);
            let mut has_owner = false;
            for def in columns {
                if def.name == "owner_id" {
                    has_owner = true;
                }
                clauses.push(mysql_column_clause(
                    def,
                    pk_set.contains(def.name.as_str()),
                )?);
            }
            if !has_owner {
                // The MySQL adapter owner-scopes every read/write on owner_id
                // — a table without the column would fail its first request.
                // VARCHAR(64), not CHAR(36): API-key principals are the
                // synthetic `api-key:<uuid>` string (44 chars), not a uuid.
                clauses.push(format!("{} VARCHAR(64)", quote_mysql_ident("owner_id")?));
            }
            let pk: Vec<String> = primary_key
                .iter()
                .map(|c| quote_mysql_ident(c))
                .collect::<DataPlaneResult<_>>()?;
            clauses.push(format!("PRIMARY KEY ({})", pk.join(", ")));
            format!("CREATE TABLE {table} ({})", clauses.join(", "))
        }
        SchemaDdlOp::DropTable => format!("DROP TABLE {table}"),
    })
}

/// Parses the labels out of a MySQL `enum('a','b','it''s')` COLUMN_TYPE.
/// Handles the `''` escape for a literal quote. Pure helper for
/// [`normalize_mysql_type`].
pub(super) fn parse_mysql_enum_values(column_type: &str) -> Vec<String> {
    let inner = column_type
        .find('(')
        .and_then(|start| {
            column_type
                .rfind(')')
                .map(|end| &column_type[start + 1..end])
        })
        .unwrap_or("");
    let mut values = Vec::new();
    let mut current = String::new();
    let mut in_quote = false;
    let mut chars = inner.chars().peekable();
    while let Some(c) = chars.next() {
        if in_quote {
            if c == '\'' {
                if chars.peek() == Some(&'\'') {
                    current.push('\'');
                    chars.next();
                } else {
                    in_quote = false;
                    values.push(std::mem::take(&mut current));
                }
            } else {
                current.push(c);
            }
        } else if c == '\'' {
            in_quote = true;
        }
        // Anything outside quotes (commas, spaces) is a separator — skipped.
    }
    values
}
