/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:30:12 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:30:14 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Structured schema DDL (typed collections) — pure SQL builders.
//!
//! Mirrors the MySQL/PG lowering (`build_mysql_ddl`) in SQLite's dialect.
//! Identifiers via the shared `quote_ident` ("…"); enum has no native type, so
//! it lowers to TEXT + a CHECK(col IN (…)) constraint (enforced, even though
//! introspection reports it back as text affinity); DEFAULT expressions pass
//! the shared `validate_default_expr` guard before interpolation.

use data_plane_core::{
    validate_default_expr, DataPlaneError, DataPlaneResult, DdlColumnDef, NormalizedType,
    SchemaDdlOp, SchemaDdlRequest,
};

use super::columns::quote_ident;

/// `'…'`-quoted SQLite string literal (quote doubling only — SQLite never
/// treats backslash as an escape).
fn sqlite_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

/// Lowers a [`DdlColumnDef`] to its SQLite column type. SQLite stores by type
/// affinity, so date/datetime/json/uuid land in TEXT and decimal in NUMERIC —
/// honest round-trip caveat: introspection reports the affinity, not the
/// declared intent. `objectid`/`unknown` are describe-only and rejected.
pub(crate) fn sqlite_sql_type(def: &DdlColumnDef) -> DataPlaneResult<String> {
    Ok(match def.normalized_type {
        NormalizedType::Text
        | NormalizedType::Date
        | NormalizedType::Datetime
        | NormalizedType::Json
        | NormalizedType::Uuid
        | NormalizedType::Array => "TEXT".to_string(),
        NormalizedType::Integer | NormalizedType::Boolean => "INTEGER".to_string(),
        NormalizedType::Float => "REAL".to_string(),
        NormalizedType::Decimal => "NUMERIC".to_string(),
        NormalizedType::Enum => {
            // Type + constraint are composed in `sqlite_column_clause` (the
            // CHECK needs the quoted column name).
            "TEXT".to_string()
        }
        NormalizedType::Objectid | NormalizedType::Unknown => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!(
                    "column '{}': normalized_type '{:?}' cannot be created on sqlite",
                    def.name, def.normalized_type
                ),
            })
        }
    })
}

/// One full column clause: `"name" TYPE [NOT NULL] [DEFAULT expr] [CHECK …]`.
fn sqlite_column_clause(def: &DdlColumnDef) -> DataPlaneResult<String> {
    let col = quote_ident(&def.name)?;
    let ty = sqlite_sql_type(def)?;
    let mut clause = format!("{col} {ty}");
    if !def.nullable {
        clause.push_str(" NOT NULL");
    }
    if let Some(default) = def.default.as_deref() {
        validate_default_expr(default)?;
        clause.push_str(&format!(" DEFAULT {default}"));
    }
    if def.normalized_type == NormalizedType::Enum {
        let values = def
            .enum_values
            .as_deref()
            .filter(|v| !v.is_empty())
            .ok_or_else(|| DataPlaneError::InvalidRequest {
                message: format!("enum column '{}' requires non-empty enum_values", def.name),
            })?;
        let literals: Vec<String> = values.iter().map(|v| sqlite_literal(v)).collect();
        clause.push_str(&format!(" CHECK ({col} IN ({}))", literals.join(", ")));
    }
    Ok(clause)
}

/// Lowers a [`SchemaDdlRequest`] to its single SQLite DDL statement.
/// `alter_column_type` is honestly rejected: SQLite has no `ALTER COLUMN`
/// (the official recipe is a 12-step table rebuild, out of this contract).
pub(crate) fn build_sqlite_ddl(ddl: &SchemaDdlRequest) -> DataPlaneResult<String> {
    let table = quote_ident(&ddl.table)?;
    Ok(match ddl.op {
        SchemaDdlOp::AddColumn => format!(
            "ALTER TABLE {table} ADD COLUMN {}",
            sqlite_column_clause(ddl.require_column()?)?
        ),
        SchemaDdlOp::DropColumn => format!(
            "ALTER TABLE {table} DROP COLUMN {}",
            quote_ident(ddl.require_column_name()?)?
        ),
        SchemaDdlOp::AlterColumnType => {
            return Err(DataPlaneError::InvalidRequest {
                message: "sqlite cannot alter a column's type in place; create a new column, copy, and drop the old one".to_string(),
            })
        }
        SchemaDdlOp::CreateTable => {
            let (columns, primary_key) = ddl.require_create_spec()?;
            let mut clauses = Vec::with_capacity(columns.len() + 2);
            let mut has_owner = false;
            for def in columns {
                if def.name == "owner_id" {
                    has_owner = true;
                }
                clauses.push(sqlite_column_clause(def)?);
            }
            if !has_owner {
                // The adapter owner-scopes every read/write on owner_id — a
                // table without the column would fail its first request.
                clauses.push(format!("{} TEXT", quote_ident("owner_id")?));
            }
            let pk: Vec<String> = primary_key
                .iter()
                .map(|c| quote_ident(c))
                .collect::<DataPlaneResult<_>>()?;
            clauses.push(format!("PRIMARY KEY ({})", pk.join(", ")));
            format!("CREATE TABLE {table} ({})", clauses.join(", "))
        }
        SchemaDdlOp::DropTable => format!("DROP TABLE {table}"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── structured DDL builders (typed collections) ─────────────────────────

    fn col(name: &str, ty: NormalizedType) -> DdlColumnDef {
        DdlColumnDef {
            name: name.into(),
            normalized_type: ty,
            nullable: true,
            default: None,
            enum_values: None,
        }
    }

    #[test]
    fn ddl_create_table_appends_owner_and_pk() {
        let req = SchemaDdlRequest {
            op: SchemaDdlOp::CreateTable,
            table: "posts".into(),
            column: None,
            column_name: None,
            columns: Some(vec![
                col("id", NormalizedType::Text),
                col("views", NormalizedType::Integer),
            ]),
            primary_key: Some(vec!["id".into()]),
        };
        let sql = build_sqlite_ddl(&req).unwrap();
        assert_eq!(
            sql,
            "CREATE TABLE \"posts\" (\"id\" TEXT, \"views\" INTEGER, \"owner_id\" TEXT, PRIMARY KEY (\"id\"))"
        );
    }

    #[test]
    fn ddl_enum_lowers_to_text_check() {
        let mut c = col("status", NormalizedType::Enum);
        c.enum_values = Some(vec!["new".into(), "it's".into()]);
        c.nullable = false;
        c.default = Some("'new'".into());
        let req = SchemaDdlRequest {
            op: SchemaDdlOp::AddColumn,
            table: "posts".into(),
            column: Some(c),
            column_name: None,
            columns: None,
            primary_key: None,
        };
        let sql = build_sqlite_ddl(&req).unwrap();
        assert_eq!(
            sql,
            "ALTER TABLE \"posts\" ADD COLUMN \"status\" TEXT NOT NULL DEFAULT 'new' CHECK (\"status\" IN ('new', 'it''s'))"
        );
    }

    #[test]
    fn ddl_alter_column_type_is_honestly_rejected() {
        let req = SchemaDdlRequest {
            op: SchemaDdlOp::AlterColumnType,
            table: "posts".into(),
            column: Some(col("views", NormalizedType::Text)),
            column_name: None,
            columns: None,
            primary_key: None,
        };
        assert!(matches!(
            build_sqlite_ddl(&req),
            Err(DataPlaneError::InvalidRequest { .. })
        ));
    }

    #[test]
    fn ddl_drop_column_and_table_quote_identifiers() {
        let drop_col = SchemaDdlRequest {
            op: SchemaDdlOp::DropColumn,
            table: "posts".into(),
            column: None,
            column_name: Some("views".into()),
            columns: None,
            primary_key: None,
        };
        assert_eq!(
            build_sqlite_ddl(&drop_col).unwrap(),
            "ALTER TABLE \"posts\" DROP COLUMN \"views\""
        );
        let drop_table = SchemaDdlRequest {
            op: SchemaDdlOp::DropTable,
            table: "posts".into(),
            column: None,
            column_name: None,
            columns: None,
            primary_key: None,
        };
        assert_eq!(
            build_sqlite_ddl(&drop_table).unwrap(),
            "DROP TABLE \"posts\""
        );
    }

    #[test]
    fn ddl_default_expr_guard_applies() {
        let mut c = col("n", NormalizedType::Integer);
        c.default = Some("0; DROP TABLE x".into());
        let req = SchemaDdlRequest {
            op: SchemaDdlOp::AddColumn,
            table: "posts".into(),
            column: Some(c),
            column_name: None,
            columns: None,
            primary_key: None,
        };
        assert!(build_sqlite_ddl(&req).is_err());
    }

    // ── sqlite_literal: quote-doubling, no backslash escapes ─────────────────

    #[test]
    fn sqlite_literal_doubles_single_quotes_only() {
        assert_eq!(sqlite_literal("plain"), "'plain'");
        assert_eq!(sqlite_literal("it's"), "'it''s'");
        assert_eq!(sqlite_literal("''"), "''''''");
        // backslash is NOT an escape char in SQLite — it passes through literally.
        assert_eq!(sqlite_literal("a\\b"), "'a\\b'");
        assert_eq!(sqlite_literal(""), "''");
    }
}
