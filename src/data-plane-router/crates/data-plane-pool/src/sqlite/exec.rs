/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   exec.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:30:02 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:30:03 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Blocking executors (run inside `interact` / the writer thread, sync
//! rusqlite): run a built [`SqlPlan`], query/execute raw SQL, and the schema
//! introspection that maps `PRAGMA table_info` back to engine-neutral columns.

use data_plane_core::{
    ColumnSchema, DataPlaneResult, DataResult, NormalizedType, SchemaDescriptor, TableSchema,
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
    // (the per-connection cache is sized in `tune_read_conn`), removing a SQL
    // parse + recompile from every read — what PocketBase already amortizes.
    // Results are byte-identical to `prepare`.
    let mut stmt = conn.prepare_cached(sql).map_err(backend)?;
    let col_names: Vec<String> = stmt.column_names().into_iter().map(String::from).collect();
    let mapped = stmt
        .query_map(params_from_iter(params.iter()), move |row| {
            let mut obj = JsonMap::with_capacity(col_names.len());
            for (i, name) in col_names.iter().enumerate() {
                obj.insert(name.clone(), sql_to_json(row.get::<_, SqlValue>(i)?));
            }
            Ok(Value::Object(obj))
        })
        .map_err(backend)?;
    let mut out = Vec::new();
    for r in mapped {
        out.push(r.map_err(backend)?);
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
            columns.push(ColumnSchema {
                name,
                native_type: native,
                normalized_type: normalized,
                nullable,
                default,
                enum_values: None,
                references: None,
                inferred: false,
            });
        }
        primary_key.sort_by_key(|(rank, _)| *rank);
        tables.push(TableSchema {
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
    if t.contains("int") {
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
        NormalizedType::Unknown
    } else if t.contains("date") || t.contains("time") {
        NormalizedType::Datetime
    } else {
        NormalizedType::Unknown
    }
}
