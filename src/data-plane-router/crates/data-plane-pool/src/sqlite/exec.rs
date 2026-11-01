/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   exec.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:30:02 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 22:40:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Blocking executors (run inside `interact` / the writer thread, sync
//! rusqlite): run a built [`SqlPlan`], query/execute raw SQL, and the schema
//! introspection that maps `PRAGMA table_info` back to engine-neutral columns.

use std::collections::BTreeMap;

use data_plane_core::{
    ColumnSchema, DataPlaneResult, DataResult, ForeignKeyRef, NormalizedType, SchemaDescriptor,
    TableSchema,
};
use rusqlite::types::Value as SqlValue;
use rusqlite::{params_from_iter, Connection};
use serde_json::{Map as JsonMap, Value};

use super::columns::quote_ident;
use super::convert::sql_to_json;
use super::error::backend;
use super::query::SqlPlan;

pub(super) fn run_plan(conn: &Connection, plan: &SqlPlan) -> DataPlaneResult<DataResult> {
    if plan.returns_rows {
        let rows = query_rows(conn, &plan.sql, &plan.params)?;
        let affected = rows.len() as u64;
        Ok(DataResult::new(rows, affected))
    } else {
        let affected = exec_write(conn, &plan.sql, &plan.params)?;
        Ok(DataResult::new(vec![], affected))
    }
}

pub(super) fn query_rows(
    conn: &Connection,
    sql: &str,
    params: &[SqlValue],
) -> DataPlaneResult<Vec<Value>> {
    // prepare_cached reuses the compiled VDBE program for a fixed query shape
    // (rusqlite's default per-connection cache, 16 statements), removing a SQL
    // parse + recompile from every read — what PocketBase already amortizes.
    // The names are read after the first step: a cached statement whose table
    // changed re-prepares inside that step, so names read before it describe
    // the old layout while the values follow the new one.
    let mut stmt = conn.prepare_cached(sql).map_err(backend)?;
    let mut rows = stmt
        .query(params_from_iter(params.iter()))
        .map_err(backend)?;
    let mut col_names: Vec<String> = Vec::new();
    let mut out = Vec::new();
    while let Some(row) = rows.next().map_err(backend)? {
        if col_names.is_empty() {
            col_names = row
                .as_ref()
                .column_names()
                .into_iter()
                .map(String::from)
                .collect();
        }
        let mut obj = JsonMap::with_capacity(col_names.len());
        for (i, name) in col_names.iter().enumerate() {
            obj.insert(
                name.clone(),
                sql_to_json(row.get::<_, SqlValue>(i).map_err(backend)?),
            );
        }
        out.push(Value::Object(obj));
    }
    Ok(out)
}

pub(super) fn exec_write(
    conn: &Connection,
    sql: &str,
    params: &[SqlValue],
) -> DataPlaneResult<u64> {
    let n = conn
        .execute(sql, params_from_iter(params.iter()))
        .map_err(backend)?;
    Ok(n as u64)
}

/// Column → referenced (table, column) for one table. A `REFERENCES parent`
/// without a column list stores `to` as NULL and means the parent's primary
/// key, so that case resolves to the parent's first PK column.
fn foreign_keys_of(
    conn: &Connection,
    table: &str,
) -> DataPlaneResult<BTreeMap<String, ForeignKeyRef>> {
    let mut stmt = conn
        .prepare("SELECT \"from\", \"table\", \"to\" FROM pragma_foreign_key_list(?1)")
        .map_err(backend)?;
    let rows = stmt
        .query_map([table], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        })
        .map_err(backend)?;
    let mut fks = BTreeMap::new();
    for r in rows {
        let (from, parent, to) = r.map_err(backend)?;
        let column = match to {
            Some(column) => column,
            None => conn
                .query_row(
                    "SELECT name FROM pragma_table_info(?1) WHERE pk = 1",
                    [&parent],
                    |row| row.get::<_, String>(0),
                )
                .map_err(backend)?,
        };
        fks.insert(
            from,
            ForeignKeyRef {
                table: parent,
                column,
            },
        );
    }
    Ok(fks)
}

pub(super) fn describe_schema_blocking(conn: &Connection) -> DataPlaneResult<SchemaDescriptor> {
    let mut tables: Vec<TableSchema> = Vec::new();
    let table_names: Vec<String> = {
        let mut stmt = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .map_err(backend)?;
        let names = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(backend)?;
        names.filter_map(Result::ok).collect()
    };
    for table in table_names {
        let mut columns: Vec<ColumnSchema> = Vec::new();
        let mut primary_key: Vec<(i64, String)> = Vec::new();
        let mut fks = foreign_keys_of(conn, &table)?;
        let mut stmt = conn
            .prepare(&format!("PRAGMA table_info({})", quote_ident(&table)?))
            .map_err(backend)?;
        let rows = stmt
            .query_map([], |row| {
                let name: String = row.get(1)?;
                let native: String = row.get(2)?;
                let notnull: i64 = row.get(3)?;
                let dflt: Option<String> = row.get(4)?;
                let pk: i64 = row.get(5)?; // 0 = not pk, else 1-based position
                Ok((name, native, notnull == 0, dflt, pk))
            })
            .map_err(backend)?;
        for r in rows {
            let (name, native, nullable, default, pk) = r.map_err(backend)?;
            if pk > 0 {
                primary_key.push((pk, name.clone()));
            }
            let normalized = normalize_sqlite_type(&native);
            let references = fks.remove(&name);
            columns.push(ColumnSchema {
                name,
                native_type: native,
                normalized_type: normalized,
                nullable,
                default,
                enum_values: None,
                references,
                inferred: false,
            });
        }
        primary_key.sort_by_key(|(rank, _)| *rank);
        tables.push(TableSchema {
            read_only: false,
            name: table,
            primary_key: primary_key.into_iter().map(|(_, n)| n).collect(),
            columns,
        });
    }
    Ok(SchemaDescriptor {
        engine: "sqlite".to_string(),
        tables,
    })
}

fn normalize_sqlite_type(native: &str) -> NormalizedType {
    let t = native.to_ascii_lowercase();
    if t.contains("bigint") || t.contains("int8") {
        NormalizedType::Bigint
    } else if t.contains("int") {
        NormalizedType::Integer
    } else if t.contains("char") || t.contains("clob") || t.contains("text") {
        NormalizedType::Text
    } else if t.contains("real") || t.contains("floa") || t.contains("doub") {
        NormalizedType::Float
    } else if t.contains("num") || t.contains("dec") {
        NormalizedType::Decimal
    } else if t.contains("bool") {
        NormalizedType::Boolean
    } else if t.contains("blob") {
        NormalizedType::Binary
    } else if t.contains("date") || t.contains("time") {
        NormalizedType::Datetime
    } else {
        NormalizedType::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_sqlite_type_reads_declared_affinity() {
        use NormalizedType as N;
        for (native, want) in [
            ("INTEGER", N::Integer),
            ("BIGINT", N::Bigint),
            ("INT8", N::Bigint),
            ("VARCHAR(20)", N::Text),
            ("REAL", N::Float),
            ("NUMERIC", N::Decimal),
            ("BOOLEAN", N::Boolean),
            ("BLOB", N::Binary),
            ("DATETIME", N::Datetime),
            ("", N::Unknown),
        ] {
            assert_eq!(normalize_sqlite_type(native), want, "{native}");
        }
    }

    #[test]
    fn describe_reports_foreign_keys_explicit_and_implicit() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE parent (id INTEGER PRIMARY KEY, code TEXT UNIQUE); \
             CREATE TABLE child (id INTEGER PRIMARY KEY, \
               parent_id INTEGER REFERENCES parent(id), \
               parent_code TEXT REFERENCES parent(code), \
               implicit_id INTEGER REFERENCES parent, note TEXT)",
        )
        .unwrap();
        let schema = describe_schema_blocking(&conn).unwrap();
        let child = schema.tables.iter().find(|t| t.name == "child").unwrap();
        let refs: Vec<(&str, Option<(&str, &str)>)> = child
            .columns
            .iter()
            .map(|c| {
                let r = c.references.as_ref();
                (
                    c.name.as_str(),
                    r.map(|r| (r.table.as_str(), r.column.as_str())),
                )
            })
            .collect();
        assert_eq!(
            refs,
            vec![
                ("id", None),
                ("parent_id", Some(("parent", "id"))),
                ("parent_code", Some(("parent", "code"))),
                ("implicit_id", Some(("parent", "id"))),
                ("note", None),
            ]
        );
    }

    /// A cached `SELECT *` re-prepares inside its first step after a schema
    /// change; names read before that step belong to the old layout (seen live:
    /// an added column missing, a recreated table's values under other names).
    #[test]
    fn cached_select_star_follows_a_schema_change() {
        let conn = Connection::open_in_memory().unwrap();
        let sql = "SELECT * FROM t";
        conn.execute_batch("CREATE TABLE t (id INTEGER, a TEXT); INSERT INTO t VALUES (1, 'x')")
            .unwrap();
        assert_eq!(query_rows(&conn, sql, &[]).unwrap()[0]["a"], "x");

        conn.execute_batch("ALTER TABLE t ADD COLUMN b TEXT; UPDATE t SET b = 'y'")
            .unwrap();
        assert_eq!(query_rows(&conn, sql, &[]).unwrap()[0]["b"], "y");

        conn.execute_batch(
            "DROP TABLE t; CREATE TABLE t (id INTEGER, b TEXT, a TEXT); \
             INSERT INTO t VALUES (2, 'B', 'A')",
        )
        .unwrap();
        let row = &query_rows(&conn, sql, &[]).unwrap()[0];
        assert_eq!(
            (&row["a"], &row["b"]),
            (&Value::from("A"), &Value::from("B"))
        );
    }
}
