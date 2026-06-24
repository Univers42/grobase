/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:29:19 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:29:25 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Introspection, schema-DDL apply, and migration — the heavy `EnginePool`
//! method bodies, factored out so the trait impl in [`super::pool`] stays a
//! thin guard+delegate. Each is byte-for-byte the pre-split method body, with
//! the `self` fields it used passed in as parameters.

use super::convert::backend;
use super::ddl::{build_pg_ddl, ddl_backend, is_duplicate_object, normalize_pg_type};
use data_plane_core::{
    ColumnSchema, DataPlaneError, DataPlaneResult, DatabaseMount, ForeignKeyRef, MigrationRequest,
    MigrationResult, MigrationStatus, NormalizedType, SchemaDdlRequest, SchemaDdlResult,
    SchemaDdlStatus, SchemaDescriptor, TableSchema,
};

/// Admin-scoped migration runner. Identity is NOT applied as an RLS context
/// (admin operations explicitly bypass tenant scoping; the caller is authorised
/// at the route layer). `mount` supplies the `schema_per_tenant` target schema.
pub(super) async fn apply_migration(
    pool: &deadpool_postgres::Pool,
    mount: &DatabaseMount,
    request: MigrationRequest,
) -> DataPlaneResult<MigrationResult> {
    let mut client = pool.get().await.map_err(|e| DataPlaneError::Backend {
        message: format!("pool checkout failed: {e}"),
    })?;
    let tx = client.transaction().await.map_err(|e| backend(&e))?;

    // For schema_per_tenant, the migration (marker table + every DDL/DML
    // statement) targets the tenant schema: create it if absent and pin the
    // transaction's `search_path` so unqualified table names in the
    // migration body land there. For shared / db-per-tenant the schema is
    // `None` → behaviour is BYTE-IDENTICAL to before G5 (`public`).
    let schema = mount.tenant_schema();
    if let Some(schema) = schema.as_deref() {
        // `schema` is pre-sanitized to `[a-z0-9_]` by `safe_schema`, so
        // interpolating it (DDL/SET cannot bind parameters) is injection-safe.
        tx.batch_execute(&format!("CREATE SCHEMA IF NOT EXISTS {schema}"))
            .await
            .map_err(|e| backend(&e))?;
        tx.batch_execute(&format!("SET LOCAL search_path TO {schema}, public"))
            .await
            .map_err(|e| backend(&e))?;
    }
    // Marker table lives in the tenant schema for schema_per_tenant (so each
    // tenant tracks its own applied set), else in `public` as before.
    let marker = match schema.as_deref() {
        Some(schema) => format!("{schema}._baas_migrations"),
        None => "public._baas_migrations".to_string(),
    };
    // Ensure the marker table exists on the tenant DB. Name chosen to be
    // unlikely to collide with user tables.
    tx.batch_execute(&format!(
        "CREATE TABLE IF NOT EXISTS {marker} (
                name TEXT PRIMARY KEY,
                applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )"
    ))
    .await
    .map_err(|e| backend(&e))?;
    let already: Option<tokio_postgres::Row> = tx
        .query_opt(
            &format!("SELECT 1 FROM {marker} WHERE name = $1"),
            &[&request.name],
        )
        .await
        .map_err(|e| backend(&e))?;
    if already.is_some() {
        // No COMMIT needed (no mutating statements ran); ROLLBACK is fine.
        let _ = tx.rollback().await;
        return Ok(MigrationResult {
            name: request.name,
            status: MigrationStatus::Skipped,
            statements_run: 0,
        });
    }
    let mut run = 0u32;
    for stmt in &request.statements {
        tx.batch_execute(stmt).await.map_err(|e| backend(&e))?;
        run += 1;
    }
    tx.execute(
        &format!("INSERT INTO {marker} (name) VALUES ($1)"),
        &[&request.name],
    )
    .await
    .map_err(|e| backend(&e))?;
    tx.commit().await.map_err(|e| backend(&e))?;
    Ok(MigrationResult {
        name: request.name,
        status: MigrationStatus::Applied,
        statements_run: run,
    })
}

/// Engine-agnostic schema introspection (M22). Scoped to `search_path_schema`
/// when `schema_per_tenant` (else `public`) so the descriptor never reveals
/// another tenant's tables. The internal `_baas_migrations` marker is excluded.
pub(super) async fn describe_schema(
    pool: &deadpool_postgres::Pool,
    search_path_schema: Option<&str>,
) -> DataPlaneResult<SchemaDescriptor> {
    let client = pool.get().await.map_err(|e| DataPlaneError::Backend {
        message: format!("pool checkout failed: {e}"),
    })?;
    // Same scoping rule as the per-request `apply_search_path`: the tenant
    // schema when isolation is schema_per_tenant, else `public`.
    let schema = search_path_schema
        .map(|s| s.to_string())
        .unwrap_or_else(|| "public".to_string());

    // Enum types and their labels (sorted by declared order). Keyed by
    // udt_name so a USER-DEFINED column can be resolved to its values.
    let mut enums: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    let enum_rows = client
        .query(
            "SELECT t.typname, e.enumlabel
                 FROM pg_type t
                 JOIN pg_enum e ON e.enumtypid = t.oid
                 ORDER BY t.typname, e.enumsortorder",
            &[],
        )
        .await
        .map_err(|e| backend(&e))?;
    for row in &enum_rows {
        enums
            .entry(row.get::<_, String>(0))
            .or_default()
            .push(row.get::<_, String>(1));
    }

    // Primary keys, per table, in key ordinal order.
    let mut pks: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    let pk_rows = client
        .query(
            "SELECT tc.table_name, kcu.column_name
                 FROM information_schema.table_constraints tc
                 JOIN information_schema.key_column_usage kcu
                   ON kcu.constraint_name = tc.constraint_name
                  AND kcu.table_schema = tc.table_schema
                 WHERE tc.table_schema = $1 AND tc.constraint_type = 'PRIMARY KEY'
                 ORDER BY tc.table_name, kcu.ordinal_position",
            &[&schema],
        )
        .await
        .map_err(|e| backend(&e))?;
    for row in &pk_rows {
        pks.entry(row.get::<_, String>(0))
            .or_default()
            .push(row.get::<_, String>(1));
    }

    // Foreign keys: (table, column) → referenced (table, column).
    let mut fks: std::collections::BTreeMap<(String, String), ForeignKeyRef> = Default::default();
    let fk_rows = client
        .query(
            "SELECT tc.table_name, kcu.column_name, ccu.table_name, ccu.column_name
                 FROM information_schema.table_constraints tc
                 JOIN information_schema.key_column_usage kcu
                   ON kcu.constraint_name = tc.constraint_name
                  AND kcu.table_schema = tc.table_schema
                 JOIN information_schema.constraint_column_usage ccu
                   ON ccu.constraint_name = tc.constraint_name
                  AND ccu.table_schema = tc.table_schema
                 WHERE tc.table_schema = $1 AND tc.constraint_type = 'FOREIGN KEY'",
            &[&schema],
        )
        .await
        .map_err(|e| backend(&e))?;
    for row in &fk_rows {
        fks.insert(
            (row.get::<_, String>(0), row.get::<_, String>(1)),
            ForeignKeyRef {
                table: row.get::<_, String>(2),
                column: row.get::<_, String>(3),
            },
        );
    }

    // Columns of every BASE TABLE in the scoped schema, in ordinal order.
    let mut tables: std::collections::BTreeMap<String, Vec<ColumnSchema>> = Default::default();
    let col_rows = client
        .query(
            "SELECT c.table_name, c.column_name, c.udt_name, c.data_type,
                        c.is_nullable, c.column_default
                 FROM information_schema.columns c
                 JOIN information_schema.tables t
                   ON t.table_schema = c.table_schema AND t.table_name = c.table_name
                 WHERE c.table_schema = $1
                   AND t.table_type = 'BASE TABLE'
                   AND c.table_name <> '_baas_migrations'
                 ORDER BY c.table_name, c.ordinal_position",
            &[&schema],
        )
        .await
        .map_err(|e| backend(&e))?;
    for row in &col_rows {
        let table: String = row.get(0);
        let name: String = row.get(1);
        let udt: String = row.get(2);
        let data_type: String = row.get(3);
        let is_nullable: String = row.get(4);
        let default: Option<String> = row.get(5);

        let (normalized_type, enum_values) = match enums.get(&udt) {
            // USER-DEFINED type with pg_enum rows → enum + its labels.
            Some(values) if data_type == "USER-DEFINED" => {
                (NormalizedType::Enum, Some(values.clone()))
            }
            _ => (normalize_pg_type(&udt), None),
        };
        let references = fks.get(&(table.clone(), name.clone())).cloned();
        tables.entry(table).or_default().push(ColumnSchema {
            name,
            native_type: udt,
            normalized_type,
            nullable: is_nullable.eq_ignore_ascii_case("yes"),
            default,
            enum_values,
            references,
            inferred: false,
        });
    }

    Ok(SchemaDescriptor {
        engine: "postgresql".to_string(),
        tables: tables
            .into_iter()
            .map(|(name, columns)| TableSchema {
                primary_key: pks.remove(&name).unwrap_or_default(),
                name,
                columns,
            })
            .collect(),
    })
}

/// Engine-agnostic schema DDL (M22 step 2). Lowered by the pure [`build_pg_ddl`]
/// builder then executed in ONE transaction (PG DDL is transactional). Enum
/// types are ensured FIRST in auto-commit (`duplicate_object` = reuse existing).
/// Statements are schema-qualified to the SAME schema `describe_schema` reads.
pub(super) async fn apply_schema_ddl(
    pool: &deadpool_postgres::Pool,
    search_path_schema: Option<&str>,
    owner_scoped: bool,
    ddl: SchemaDdlRequest,
) -> DataPlaneResult<SchemaDdlResult> {
    let schema = search_path_schema
        .map(|s| s.to_string())
        .unwrap_or_else(|| "public".to_string());
    let plan = build_pg_ddl(&schema, &ddl, owner_scoped)?;

    let mut client = pool.get().await.map_err(|e| DataPlaneError::Backend {
        message: format!("pool checkout failed: {e}"),
    })?;
    // schema_per_tenant: the tenant schema may not exist yet (first DDL on
    // a fresh tenant). `schema` is pre-sanitized by `safe_schema`, so
    // interpolating it (DDL cannot bind parameters) is injection-safe.
    if search_path_schema.is_some() {
        client
            .batch_execute(&format!("CREATE SCHEMA IF NOT EXISTS {schema}"))
            .await
            .map_err(|e| backend(&e))?;
    }
    // Enum types auto-commit BEFORE the transactional DDL: an aborted
    // CREATE TYPE inside the tx would poison it, and `duplicate_object`
    // here means the named type already exists — reuse it.
    for stmt in &plan.ensure_enum_types {
        if let Err(e) = client.execute(stmt.as_str(), &[]).await {
            if !is_duplicate_object(&e) {
                return Err(ddl_backend(&e));
            }
        }
    }

    let tx = client.transaction().await.map_err(|e| backend(&e))?;
    for stmt in &plan.statements {
        tx.execute(stmt.as_str(), &[])
            .await
            .map_err(|e| ddl_backend(&e))?;
    }
    tx.commit().await.map_err(|e| backend(&e))?;
    Ok(SchemaDdlResult {
        op: ddl.op,
        table: ddl.table,
        status: SchemaDdlStatus::Applied,
    })
}
