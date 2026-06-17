//! Engine-agnostic schema DDL contract (M22 live-database mode, step 2).
//!
//! [`SchemaDdlRequest`] is the wire shape consumed by `POST /v1/schema/ddl`
//! and every [`crate::EnginePool::apply_schema_ddl`] implementation:
//! relational engines lower it to `ALTER TABLE` / `CREATE TABLE` SQL through
//! pure, unit-tested builders; the document engine rewrites the collection's
//! `$jsonSchema` validator. ONE operation per request — deliberate, because
//! MySQL DDL is auto-commit/non-transactional, so a multi-op batch would fake
//! an atomicity the engine cannot deliver.

use crate::{DataPlaneError, DataPlaneResult, NormalizedType};
use serde::{Deserialize, Serialize};

/// One column definition for DDL: a [`crate::ColumnSchema`] minus the
/// describe-only fields (`native_type`, `references`, `inferred`). For
/// `alter_column_type` the caller composes the FULL target definition
/// (name + new type + nullability + default + enum values) — engines like
/// MySQL (`MODIFY COLUMN`) reset every attribute, so a partial def would
/// silently drop constraints.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DdlColumnDef {
    pub name: String,
    pub normalized_type: NormalizedType,
    pub nullable: bool,
    /// Raw engine default expression (`0`, `'pending'`, `now()`).
    /// Interpolated into DDL (DEFAULT cannot bind parameters), so it is
    /// guarded by [`validate_default_expr`] before any rendering.
    #[serde(default)]
    pub default: Option<String>,
    /// Allowed values when `normalized_type` is `enum`.
    #[serde(default)]
    pub enum_values: Option<Vec<String>>,
}

/// The single supported DDL operation kinds. Snake_case on the wire.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SchemaDdlOp {
    AddColumn,
    DropColumn,
    AlterColumnType,
    CreateTable,
    DropTable,
}

/// The `ddl` object of `POST /v1/schema/ddl`. Which optional field is
/// required depends on `op` — enforced by the `require_*` helpers so every
/// engine shares one validation surface (and one error message).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SchemaDdlRequest {
    pub op: SchemaDdlOp,
    pub table: String,
    /// `add_column`: the new column; `alter_column_type`: the FULL target def.
    #[serde(default)]
    pub column: Option<DdlColumnDef>,
    /// `drop_column`: the column to drop.
    #[serde(default)]
    pub column_name: Option<String>,
    /// `create_table`: the table's columns.
    #[serde(default)]
    pub columns: Option<Vec<DdlColumnDef>>,
    /// `create_table`: the primary key column(s) — required.
    #[serde(default)]
    pub primary_key: Option<Vec<String>>,
}

impl SchemaDdlRequest {
    /// The full column def for `add_column` / `alter_column_type`.
    pub fn require_column(&self) -> DataPlaneResult<&DdlColumnDef> {
        self.column.as_ref().ok_or_else(|| DataPlaneError::InvalidRequest {
            message: format!("ddl op '{}' requires `column`", self.op.as_str()),
        })
    }

    /// The column name for `drop_column`.
    pub fn require_column_name(&self) -> DataPlaneResult<&str> {
        self.column_name
            .as_deref()
            .filter(|n| !n.trim().is_empty())
            .ok_or_else(|| DataPlaneError::InvalidRequest {
                message: format!("ddl op '{}' requires `column_name`", self.op.as_str()),
            })
    }

    /// Columns + primary key for `create_table`. Both must be non-empty, and
    /// every PK column must be a declared column (or `owner_id`, which the
    /// engines auto-append) — catching typos here instead of as an engine 5xx.
    pub fn require_create_spec(&self) -> DataPlaneResult<(&[DdlColumnDef], &[String])> {
        let columns = self
            .columns
            .as_deref()
            .filter(|c| !c.is_empty())
            .ok_or_else(|| DataPlaneError::InvalidRequest {
                message: "ddl op 'create_table' requires non-empty `columns`".to_string(),
            })?;
        let primary_key = self
            .primary_key
            .as_deref()
            .filter(|pk| !pk.is_empty())
            .ok_or_else(|| DataPlaneError::InvalidRequest {
                message: "ddl op 'create_table' requires non-empty `primary_key`".to_string(),
            })?;
        for pk in primary_key {
            if pk != "owner_id" && !columns.iter().any(|c| &c.name == pk) {
                return Err(DataPlaneError::InvalidRequest {
                    message: format!("primary_key column '{pk}' is not in `columns`"),
                });
            }
        }
        Ok((columns, primary_key))
    }
}

impl SchemaDdlOp {
    /// The wire (snake_case) name, for error messages.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::AddColumn => "add_column",
            Self::DropColumn => "drop_column",
            Self::AlterColumnType => "alter_column_type",
            Self::CreateTable => "create_table",
            Self::DropTable => "drop_table",
        }
    }
}

/// Wire status of an applied DDL operation (closed set, like
/// [`crate::MigrationStatus`]).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SchemaDdlStatus {
    Applied,
}

/// Response of `POST /v1/schema/ddl`:
/// `{ "op": "...", "table": "...", "status": "applied" }`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SchemaDdlResult {
    pub op: SchemaDdlOp,
    pub table: String,
    pub status: SchemaDdlStatus,
}

/// Guard for caller-supplied DEFAULT expressions, which must be interpolated
/// into DDL text (a DEFAULT clause cannot bind parameters). The drivers
/// already enforce single-statement execution (PG extended query protocol;
/// mysql_async ships with multi-statements disabled), so this is defense in
/// depth: no statement separators, no SQL comments, no control characters.
/// Legitimate defaults (`0`, `'pending'`, `now()`, `CURRENT_TIMESTAMP`) pass.
pub fn validate_default_expr(expr: &str) -> DataPlaneResult<()> {
    let forbidden =
        expr.contains(';') || expr.contains("--") || expr.contains("/*") || expr.chars().any(char::is_control);
    if forbidden {
        return Err(DataPlaneError::InvalidRequest {
            message: format!(
                "default expression '{expr}' contains forbidden characters (';', '--', '/*', control)"
            ),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn ddl_request_serde_round_trip_matches_wire_contract() {
        // The FIXED wire contract: snake_case op, ColumnDef with nullable
        // default / enum_values, op-specific optional fields.
        let wire = json!({
            "op": "add_column",
            "table": "orders",
            "column": {
                "name": "status",
                "normalized_type": "enum",
                "nullable": false,
                "default": "'pending'",
                "enum_values": ["pending", "paid"]
            },
            "column_name": null,
            "columns": null,
            "primary_key": null
        });
        let parsed: SchemaDdlRequest = serde_json::from_value(wire.clone()).expect("deserializes");
        assert_eq!(parsed.op, SchemaDdlOp::AddColumn);
        assert_eq!(parsed.table, "orders");
        let col = parsed.column.as_ref().expect("column present");
        assert_eq!(col.normalized_type, NormalizedType::Enum);
        assert_eq!(col.enum_values.as_deref(), Some(&["pending".to_string(), "paid".to_string()][..]));
        assert_eq!(serde_json::to_value(&parsed).expect("serializes"), wire);
    }

    #[test]
    fn ddl_request_optional_fields_may_be_absent() {
        // A minimal drop_table payload (no column/columns keys at all) parses.
        let parsed: SchemaDdlRequest =
            serde_json::from_value(json!({ "op": "drop_table", "table": "orders" })).unwrap();
        assert_eq!(parsed.op, SchemaDdlOp::DropTable);
        assert!(parsed.column.is_none() && parsed.columns.is_none());
    }

    #[test]
    fn ddl_result_serializes_to_the_fixed_response_shape() {
        let result = SchemaDdlResult {
            op: SchemaDdlOp::CreateTable,
            table: "orders".to_string(),
            status: SchemaDdlStatus::Applied,
        };
        assert_eq!(
            serde_json::to_value(&result).unwrap(),
            json!({ "op": "create_table", "table": "orders", "status": "applied" })
        );
    }

    fn req(op: SchemaDdlOp) -> SchemaDdlRequest {
        SchemaDdlRequest {
            op,
            table: "t".into(),
            column: None,
            column_name: None,
            columns: None,
            primary_key: None,
        }
    }

    #[test]
    fn require_helpers_reject_missing_op_specific_fields() {
        for (op, err_of) in [
            (SchemaDdlOp::AddColumn, req(SchemaDdlOp::AddColumn).require_column().err()),
            (SchemaDdlOp::DropColumn, req(SchemaDdlOp::DropColumn).require_column_name().err()),
        ] {
            let err = err_of.unwrap_or_else(|| panic!("{op:?} should fail"));
            assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{op:?}: {err:?}");
        }
        // create_table: missing columns, missing pk, and a pk typo all fail.
        let mut r = req(SchemaDdlOp::CreateTable);
        assert!(r.require_create_spec().is_err(), "no columns");
        r.columns = Some(vec![DdlColumnDef {
            name: "id".into(),
            normalized_type: NormalizedType::Integer,
            nullable: false,
            default: None,
            enum_values: None,
        }]);
        assert!(r.require_create_spec().is_err(), "no primary_key");
        r.primary_key = Some(vec!["nope".into()]);
        assert!(r.require_create_spec().is_err(), "pk references unknown column");
        r.primary_key = Some(vec!["id".into()]);
        assert!(r.require_create_spec().is_ok());
        // owner_id is always a legal PK column (engines auto-append it).
        r.primary_key = Some(vec!["owner_id".into()]);
        assert!(r.require_create_spec().is_ok());
    }

    #[test]
    fn default_expr_guard_blocks_separators_comments_and_control() {
        for bad in ["0; DROP TABLE x", "1 -- evil", "1 /* evil */", "a\nb"] {
            assert!(validate_default_expr(bad).is_err(), "{bad:?}");
        }
        for ok in ["0", "'pending'", "now()", "CURRENT_TIMESTAMP", "gen_random_uuid()"] {
            assert!(validate_default_expr(ok).is_ok(), "{ok:?}");
        }
    }
}
