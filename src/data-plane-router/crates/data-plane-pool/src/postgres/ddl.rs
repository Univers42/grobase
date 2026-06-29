/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ddl.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:29:08 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:29:09 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Pure schema-DDL SQL builders + the Postgres→neutral type normalizer.
//!
//! Everything here is pure (testable without a DB). Identifiers go through
//! `quote_ident` (allowlist + quoting); enum VALUES are SQL string literals
//! escaped by `pg_literal`; caller-supplied DEFAULT expressions pass the shared
//! `validate_default_expr` guard (no `;`, comments, or control chars — defense
//! in depth on top of the driver's single-statement extended protocol).

use crate::ident::quote_ident;
use data_plane_core::{
    validate_default_expr, DataPlaneError, DataPlaneResult, DdlColumnDef, NormalizedType,
    SchemaDdlOp, SchemaDdlRequest,
};

/// Maps a Postgres `udt_name` to the engine-neutral [`NormalizedType`]. Pure
/// (testable without a DB); enum resolution happens at the call site, which
/// holds the `pg_enum` rows. Array types surface as `_<element>` udt names (or
/// the literal `ARRAY` data_type, which callers pass through here unchanged).
pub(super) fn normalize_pg_type(native: &str) -> NormalizedType {
    match native {
        "int2" | "int4" | "int8" => NormalizedType::Integer,
        "float4" | "float8" => NormalizedType::Float,
        "numeric" => NormalizedType::Decimal,
        "bool" => NormalizedType::Boolean,
        "date" => NormalizedType::Date,
        "json" | "jsonb" => NormalizedType::Json,
        "uuid" => NormalizedType::Uuid,
        "text" | "varchar" | "char" | "bpchar" => NormalizedType::Text,
        "ARRAY" => NormalizedType::Array,
        n if n.starts_with("timestamp") => NormalizedType::Datetime,
        n if n.starts_with('_') => NormalizedType::Array,
        _ => NormalizedType::Unknown,
    }
}

/// The statement plan for one schema-DDL operation.
#[derive(Debug)]
pub(super) struct PgDdlPlan {
    /// `CREATE TYPE … AS ENUM (…)` statements run BEFORE the transactional
    /// DDL, auto-commit; a `duplicate_object` (42710) error means "reuse the
    /// existing type" (per contract).
    pub(super) ensure_enum_types: Vec<String>,
    /// The DDL statements, executed in order inside ONE transaction.
    pub(super) statements: Vec<String>,
}

/// `'…'`-quoted SQL string literal: single quotes double. Backslash is
/// literal under `standard_conforming_strings` (the PG default since 9.1).
fn pg_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

/// The schema-qualified, quoted name of the per-column enum type:
/// `"schema"."{table}_{column}_enum"`. Both parts go through `quote_ident`,
/// so an over-long or invalid combination fails closed (InvalidIdentifier)
/// instead of being silently truncated by the server.
fn pg_enum_type_name(schema: &str, table: &str, column: &str) -> DataPlaneResult<String> {
    quote_ident(&format!("{schema}.{table}_{column}_enum"))
}

/// Reverse type mapping (the inverse of [`normalize_pg_type`]): lowers a
/// [`DdlColumnDef`] to the PostgreSQL column type SQL. Enum columns map to a
/// named type `"{table}_{column}_enum"` (created/reused via the plan's
/// `ensure_enum_types`). `objectid`/`unknown` are describe-only and rejected.
pub(super) fn pg_sql_type(
    schema: &str,
    table: &str,
    def: &DdlColumnDef,
) -> DataPlaneResult<String> {
    Ok(match def.normalized_type {
        NormalizedType::Text => "text".to_string(),
        NormalizedType::Integer => "bigint".to_string(),
        NormalizedType::Float => "double precision".to_string(),
        NormalizedType::Decimal => "numeric".to_string(),
        NormalizedType::Boolean => "boolean".to_string(),
        NormalizedType::Date => "date".to_string(),
        NormalizedType::Datetime => "timestamptz".to_string(),
        NormalizedType::Json => "jsonb".to_string(),
        NormalizedType::Uuid => "uuid".to_string(),
        // v1: arrays are text[] — element typing is a follow-up.
        NormalizedType::Array => "text[]".to_string(),
        NormalizedType::Enum => pg_enum_type_name(schema, table, &def.name)?,
        NormalizedType::Objectid | NormalizedType::Unknown => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!(
                    "column '{}': normalized_type '{:?}' cannot be created on postgresql",
                    def.name, def.normalized_type
                ),
            })
        }
    })
}

/// The `CREATE TYPE … AS ENUM (…)` statement for an enum column, or `None`
/// for any other type. Values are escaped literals; an enum without values
/// is a client error.
fn pg_create_enum_stmt(
    schema: &str,
    table: &str,
    def: &DdlColumnDef,
) -> DataPlaneResult<Option<String>> {
    if def.normalized_type != NormalizedType::Enum {
        return Ok(None);
    }
    let values = def
        .enum_values
        .as_deref()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| DataPlaneError::InvalidRequest {
            message: format!("enum column '{}' requires non-empty enum_values", def.name),
        })?;
    let name = pg_enum_type_name(schema, table, &def.name)?;
    let literals: Vec<String> = values.iter().map(|v| pg_literal(v)).collect();
    Ok(Some(format!(
        "CREATE TYPE {name} AS ENUM ({})",
        literals.join(", ")
    )))
}

/// One column clause (`"name" type [NOT NULL] [DEFAULT expr]`), collecting
/// any enum-type prerequisite into the plan.
fn pg_column_clause(
    schema: &str,
    table: &str,
    def: &DdlColumnDef,
    plan: &mut PgDdlPlan,
) -> DataPlaneResult<String> {
    let col = quote_ident(&def.name)?;
    let ty = pg_sql_type(schema, table, def)?;
    if let Some(stmt) = pg_create_enum_stmt(schema, table, def)? {
        plan.ensure_enum_types.push(stmt);
    }
    let mut clause = format!("{col} {ty}");
    if !def.nullable {
        clause.push_str(" NOT NULL");
    }
    if let Some(default) = def.default.as_deref() {
        validate_default_expr(default)?;
        clause.push_str(&format!(" DEFAULT {default}"));
    }
    Ok(clause)
}

/// Lowers a [`SchemaDdlRequest`] to its PostgreSQL statement plan, targeting
/// `schema` explicitly (`"schema"."table"` on every statement).
pub(super) fn build_pg_ddl(
    schema: &str,
    ddl: &SchemaDdlRequest,
    owner_scoped: bool,
) -> DataPlaneResult<PgDdlPlan> {
    let table = quote_ident(&format!("{schema}.{}", ddl.table))?;
    let mut plan = PgDdlPlan {
        ensure_enum_types: Vec::new(),
        statements: Vec::new(),
    };
    match ddl.op {
        SchemaDdlOp::AddColumn => {
            let def = ddl.require_column()?;
            let clause = pg_column_clause(schema, &ddl.table, def, &mut plan)?;
            plan.statements
                .push(format!("ALTER TABLE {table} ADD COLUMN {clause}"));
        }
        SchemaDdlOp::DropColumn => {
            let col = quote_ident(ddl.require_column_name()?)?;
            plan.statements
                .push(format!("ALTER TABLE {table} DROP COLUMN {col}"));
        }
        SchemaDdlOp::AlterColumnType => {
            // The caller composed the FULL target definition; lower it as a
            // 4-step sequence (one tx → atomic):
            //   1. DROP DEFAULT — the old default may not be castable to the
            //      new type (PG would refuse the TYPE change otherwise);
            //   2. TYPE … USING — enums cast via ::text (every type reaches
            //      text; text reaches any enum);
            //   3. SET/DROP NOT NULL per the target def;
            //   4. SET DEFAULT per the target def (when one is declared).
            let def = ddl.require_column()?;
            let col = quote_ident(&def.name)?;
            let ty = pg_sql_type(schema, &ddl.table, def)?;
            if let Some(stmt) = pg_create_enum_stmt(schema, &ddl.table, def)? {
                plan.ensure_enum_types.push(stmt);
            }
            plan.statements.push(format!(
                "ALTER TABLE {table} ALTER COLUMN {col} DROP DEFAULT"
            ));
            let using = if def.normalized_type == NormalizedType::Enum {
                format!("{col}::text::{ty}")
            } else {
                format!("{col}::{ty}")
            };
            plan.statements.push(format!(
                "ALTER TABLE {table} ALTER COLUMN {col} TYPE {ty} USING {using}"
            ));
            plan.statements.push(format!(
                "ALTER TABLE {table} ALTER COLUMN {col} {} NOT NULL",
                if def.nullable { "DROP" } else { "SET" }
            ));
            if let Some(default) = def.default.as_deref() {
                validate_default_expr(default)?;
                plan.statements.push(format!(
                    "ALTER TABLE {table} ALTER COLUMN {col} SET DEFAULT {default}"
                ));
            }
        }
        SchemaDdlOp::CreateTable => {
            let (columns, primary_key) = ddl.require_create_spec()?;
            let auto_pk = data_plane_core::auto_increment_pk(columns, primary_key);
            let mut clauses = Vec::with_capacity(columns.len() + 2);
            let mut has_owner = false;
            for def in columns {
                if def.name == "owner_id" {
                    has_owner = true;
                }
                let mut clause = pg_column_clause(schema, &ddl.table, def, &mut plan)?;
                if Some(def.name.as_str()) == auto_pk {
                    clause.push_str(" GENERATED BY DEFAULT AS IDENTITY");
                }
                clauses.push(clause);
            }
            if owner_scoped && !has_owner {
                // The platform's write path owner-scopes every row (insert
                // injects owner_id; update/delete filter on it) — a table
                // without the column would 500 on its first write. The
                // principal is NOT always a uuid: API-key callers get the
                // synthetic `api-key:<uuid>` string and the insert path binds
                // it as text, so the column must be text. `tenant_owned`
                // mounts skip this: the schema is the tenant's own.
                clauses.push(format!("{} text", quote_ident("owner_id")?));
            }
            let pk: Vec<String> = primary_key
                .iter()
                .map(|c| quote_ident(c))
                .collect::<DataPlaneResult<_>>()?;
            clauses.push(format!("PRIMARY KEY ({})", pk.join(", ")));
            plan.statements
                .push(format!("CREATE TABLE {table} ({})", clauses.join(", ")));
        }
        SchemaDdlOp::DropTable => {
            plan.statements.push(format!("DROP TABLE {table}"));
        }
    }
    Ok(plan)
}

/// DDL-path error classifier. Class 22 data exceptions (invalid text
/// representation, numeric out of range, …) and 42804 datatype_mismatch
/// during `ALTER … USING` mean the EXISTING DATA is incompatible with the
/// requested type — the caller's conflict (409), not an engine failure (502).
/// Schema-shape mistakes are deterministic client errors too: a 5xx here
/// makes outbox-style clients retry a request that can never succeed —
/// 42701/42P07 (already exists) → 409, 42703/42P01 (no such column/table) →
/// 400. Scoped to the DDL path only (additive): `/v1/query` keeps the
/// existing [`super::convert::backend`] mapping, which this falls back to
/// (23xxx → Conflict, rest → Backend).
pub(super) fn ddl_backend(e: &tokio_postgres::Error) -> DataPlaneError {
    if let Some(db) = e.as_db_error() {
        let code = db.code().code();
        if code.starts_with("22") || code == "42804" || code == "42701" || code == "42P07" {
            return DataPlaneError::Conflict {
                message: db.message().to_string(),
            };
        }
        if code == "42703" || code == "42P01" {
            return DataPlaneError::InvalidRequest {
                message: db.message().to_string(),
            };
        }
    }
    super::convert::backend(e)
}

/// SQLSTATE 42710 duplicate_object — the enum type already exists.
pub(super) fn is_duplicate_object(e: &tokio_postgres::Error) -> bool {
    e.as_db_error()
        .is_some_and(|db| db.code().code() == "42710")
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- M22 schema introspection: pure type normalizer (golden table) ---

    #[test]
    fn normalize_pg_type_golden_table() {
        use NormalizedType as N;
        for (native, expected) in [
            ("int2", N::Integer),
            ("int4", N::Integer),
            ("int8", N::Integer),
            ("float4", N::Float),
            ("float8", N::Float),
            ("numeric", N::Decimal),
            ("bool", N::Boolean),
            ("date", N::Date),
            ("timestamp", N::Datetime),
            ("timestamptz", N::Datetime),
            ("json", N::Json),
            ("jsonb", N::Json),
            ("uuid", N::Uuid),
            ("text", N::Text),
            ("varchar", N::Text),
            ("char", N::Text),
            ("bpchar", N::Text),
            ("ARRAY", N::Array),
            ("_int4", N::Array),
            ("_text", N::Array),
            // USER-DEFINED enums are resolved at the call site (needs pg_enum
            // rows); the bare normalizer honestly says Unknown.
            ("order_status", N::Unknown),
            ("bytea", N::Unknown),
            ("tsvector", N::Unknown),
        ] {
            assert_eq!(normalize_pg_type(native), expected, "udt_name {native}");
        }
    }

    // --- M22 step 2: schema DDL — pure SQL builders (golden tables) ---

    fn col(name: &str, ty: NormalizedType) -> DdlColumnDef {
        DdlColumnDef {
            name: name.to_string(),
            normalized_type: ty,
            nullable: true,
            default: None,
            enum_values: None,
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
    fn pg_sql_type_golden_table() {
        use NormalizedType as N;
        for (ty, expected) in [
            (N::Text, "text"),
            (N::Integer, "bigint"),
            (N::Float, "double precision"),
            (N::Decimal, "numeric"),
            (N::Boolean, "boolean"),
            (N::Date, "date"),
            (N::Datetime, "timestamptz"),
            (N::Json, "jsonb"),
            (N::Uuid, "uuid"),
            (N::Array, "text[]"),
        ] {
            assert_eq!(
                pg_sql_type("public", "orders", &col("c", ty)).unwrap(),
                expected,
                "{ty:?}"
            );
        }
        // enum → the per-column named type, schema-qualified + quoted.
        assert_eq!(
            pg_sql_type("public", "orders", &col("status", NormalizedType::Enum)).unwrap(),
            "\"public\".\"orders_status_enum\""
        );
        // describe-only types are rejected, not guessed.
        for ty in [NormalizedType::Objectid, NormalizedType::Unknown] {
            assert!(matches!(
                pg_sql_type("public", "orders", &col("c", ty)).unwrap_err(),
                DataPlaneError::InvalidRequest { .. }
            ));
        }
    }

    #[test]
    fn pg_ddl_add_column_with_default_and_not_null() {
        let mut req = ddl(SchemaDdlOp::AddColumn, "orders");
        req.column = Some(DdlColumnDef {
            name: "qty".into(),
            normalized_type: NormalizedType::Integer,
            nullable: false,
            default: Some("0".into()),
            enum_values: None,
        });
        let plan = build_pg_ddl("public", &req, true).unwrap();
        assert!(plan.ensure_enum_types.is_empty());
        assert_eq!(
            plan.statements,
            vec![
                "ALTER TABLE \"public\".\"orders\" ADD COLUMN \"qty\" bigint NOT NULL DEFAULT 0"
                    .to_string()
            ]
        );
    }

    #[test]
    fn pg_ddl_add_enum_column_ensures_named_type_with_escaped_literals() {
        let mut req = ddl(SchemaDdlOp::AddColumn, "orders");
        req.column = Some(DdlColumnDef {
            name: "status".into(),
            normalized_type: NormalizedType::Enum,
            nullable: true,
            default: None,
            enum_values: Some(vec!["pending".into(), "it's".into()]),
        });
        let plan = build_pg_ddl("public", &req, true).unwrap();
        // `''` escaping locks the literal quoting (injection cannot escape).
        assert_eq!(
            plan.ensure_enum_types,
            vec![
                "CREATE TYPE \"public\".\"orders_status_enum\" AS ENUM ('pending', 'it''s')"
                    .to_string()
            ]
        );
        assert_eq!(
            plan.statements,
            vec![
                "ALTER TABLE \"public\".\"orders\" ADD COLUMN \"status\" \"public\".\"orders_status_enum\""
                    .to_string()
            ]
        );
        // enum without values is a client error.
        let mut bad = ddl(SchemaDdlOp::AddColumn, "orders");
        bad.column = Some(col("status", NormalizedType::Enum));
        assert!(matches!(
            build_pg_ddl("public", &bad, true).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
    }

    #[test]
    fn pg_ddl_alter_column_type_emits_full_target_sequence() {
        // The contract: caller sends the FULL target def; the builder lowers
        // it to DROP DEFAULT → TYPE…USING → NOT NULL → SET DEFAULT, in one tx.
        let mut req = ddl(SchemaDdlOp::AlterColumnType, "orders");
        req.column = Some(DdlColumnDef {
            name: "qty".into(),
            normalized_type: NormalizedType::Integer,
            nullable: false,
            default: Some("0".into()),
            enum_values: None,
        });
        let plan = build_pg_ddl("public", &req, true).unwrap();
        assert_eq!(
            plan.statements,
            vec![
                "ALTER TABLE \"public\".\"orders\" ALTER COLUMN \"qty\" DROP DEFAULT".to_string(),
                "ALTER TABLE \"public\".\"orders\" ALTER COLUMN \"qty\" TYPE bigint USING \"qty\"::bigint"
                    .to_string(),
                "ALTER TABLE \"public\".\"orders\" ALTER COLUMN \"qty\" SET NOT NULL".to_string(),
                "ALTER TABLE \"public\".\"orders\" ALTER COLUMN \"qty\" SET DEFAULT 0".to_string(),
            ]
        );
        // nullable + no default → DROP NOT NULL, and no SET DEFAULT step.
        let mut relaxed = ddl(SchemaDdlOp::AlterColumnType, "orders");
        relaxed.column = Some(col("qty", NormalizedType::Text));
        let plan = build_pg_ddl("public", &relaxed, true).unwrap();
        assert!(
            plan.statements[2].ends_with("DROP NOT NULL"),
            "{:?}",
            plan.statements
        );
        assert_eq!(plan.statements.len(), 3, "no default → no SET DEFAULT");
    }

    #[test]
    fn pg_ddl_alter_to_enum_casts_via_text() {
        let mut req = ddl(SchemaDdlOp::AlterColumnType, "orders");
        req.column = Some(DdlColumnDef {
            name: "status".into(),
            normalized_type: NormalizedType::Enum,
            nullable: true,
            default: None,
            enum_values: Some(vec!["a".into(), "b".into()]),
        });
        let plan = build_pg_ddl("public", &req, true).unwrap();
        assert_eq!(plan.ensure_enum_types.len(), 1, "enum type ensured first");
        assert!(
            plan.statements[1]
                .contains("USING \"status\"::text::\"public\".\"orders_status_enum\""),
            "{:?}",
            plan.statements
        );
    }

    #[test]
    fn pg_ddl_create_table_appends_owner_id_and_primary_key() {
        let mut req = ddl(SchemaDdlOp::CreateTable, "orders");
        req.columns = Some(vec![
            DdlColumnDef {
                name: "id".into(),
                normalized_type: NormalizedType::Integer,
                nullable: false,
                default: None,
                enum_values: None,
            },
            col("note", NormalizedType::Text),
        ]);
        req.primary_key = Some(vec!["id".into()]);
        let plan = build_pg_ddl("public", &req, true).unwrap();
        assert_eq!(
            plan.statements,
            vec![
                "CREATE TABLE \"public\".\"orders\" (\"id\" bigint NOT NULL GENERATED BY DEFAULT AS IDENTITY, \"note\" text, \
                 \"owner_id\" text, PRIMARY KEY (\"id\"))"
                    .to_string()
            ]
        );
        // An explicit owner_id column is respected, never duplicated.
        let mut explicit = ddl(SchemaDdlOp::CreateTable, "orders");
        explicit.columns = Some(vec![
            DdlColumnDef {
                name: "id".into(),
                normalized_type: NormalizedType::Integer,
                nullable: false,
                default: None,
                enum_values: None,
            },
            col("owner_id", NormalizedType::Uuid),
        ]);
        explicit.primary_key = Some(vec!["id".into()]);
        let plan = build_pg_ddl("public", &explicit, true).unwrap();
        assert_eq!(
            plan.statements[0].matches("owner_id").count(),
            1,
            "{:?}",
            plan.statements
        );
    }

    #[test]
    fn pg_ddl_create_table_identity_guards() {
        let int_pk = |name: &str, default: Option<&str>| DdlColumnDef {
            name: name.into(),
            normalized_type: NormalizedType::Integer,
            nullable: false,
            default: default.map(str::to_string),
            enum_values: None,
        };
        let mut with_default = ddl(SchemaDdlOp::CreateTable, "orders");
        with_default.columns = Some(vec![int_pk("id", Some("0"))]);
        with_default.primary_key = Some(vec!["id".into()]);
        let sql = &build_pg_ddl("public", &with_default, false)
            .unwrap()
            .statements[0];
        assert!(
            !sql.contains("IDENTITY") && sql.contains("DEFAULT 0"),
            "{sql}"
        );

        let mut composite = ddl(SchemaDdlOp::CreateTable, "membership");
        composite.columns = Some(vec![int_pk("org_id", None), int_pk("user_id", None)]);
        composite.primary_key = Some(vec!["org_id".into(), "user_id".into()]);
        let sql = &build_pg_ddl("public", &composite, false)
            .unwrap()
            .statements[0];
        assert!(!sql.contains("IDENTITY"), "{sql}");

        let mut text_pk = ddl(SchemaDdlOp::CreateTable, "slugs");
        text_pk.columns = Some(vec![col("slug", NormalizedType::Text)]);
        text_pk.primary_key = Some(vec!["slug".into()]);
        let sql = &build_pg_ddl("public", &text_pk, false).unwrap().statements[0];
        assert!(!sql.contains("IDENTITY"), "{sql}");
    }

    #[test]
    fn pg_ddl_drop_ops_and_schema_scoping() {
        let mut drop_col = ddl(SchemaDdlOp::DropColumn, "orders");
        drop_col.column_name = Some("note".into());
        // schema_per_tenant: every statement targets the tenant schema.
        let plan = build_pg_ddl("tenant_acme_12345678", &drop_col, true).unwrap();
        assert_eq!(
            plan.statements,
            vec![
                "ALTER TABLE \"tenant_acme_12345678\".\"orders\" DROP COLUMN \"note\"".to_string()
            ]
        );
        let plan = build_pg_ddl("public", &ddl(SchemaDdlOp::DropTable, "orders"), true).unwrap();
        assert_eq!(
            plan.statements,
            vec!["DROP TABLE \"public\".\"orders\"".to_string()]
        );
    }

    #[test]
    fn pg_ddl_rejects_injection_and_unsafe_defaults() {
        // table name injection
        assert!(matches!(
            build_pg_ddl(
                "public",
                &ddl(SchemaDdlOp::DropTable, "orders; DROP TABLE x"),
                true
            )
            .unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
        // column name injection
        let mut bad_col = ddl(SchemaDdlOp::AddColumn, "orders");
        bad_col.column = Some(col("evil\"; --", NormalizedType::Text));
        assert!(matches!(
            build_pg_ddl("public", &bad_col, true).unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
        // unsafe default expression
        let mut bad_default = ddl(SchemaDdlOp::AddColumn, "orders");
        bad_default.column = Some(DdlColumnDef {
            name: "c".into(),
            normalized_type: NormalizedType::Text,
            nullable: true,
            default: Some("'x'; DROP TABLE orders".into()),
            enum_values: None,
        });
        assert!(matches!(
            build_pg_ddl("public", &bad_default, true).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
        // missing op-specific field surfaces the shared require_* error.
        assert!(matches!(
            build_pg_ddl("public", &ddl(SchemaDdlOp::AddColumn, "orders"), true).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
    }
}
