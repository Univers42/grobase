//! Engine-agnostic schema introspection contract (M22, live-database mode).
//!
//! [`SchemaDescriptor`] is the wire shape returned by `POST /v1/schema` and
//! produced by every [`crate::EnginePool::describe_schema`] implementation:
//! relational engines read their information_schema / catalogs, document
//! engines derive it from a `$jsonSchema` validator or sample-based inference
//! (`inferred: true`). The TS query-router forwards it verbatim, so this file
//! is the single source of truth for the contract.

use serde::{Deserialize, Serialize};

/// Engine-neutral column type. Snake_case on the wire (`"datetime"`,
/// `"objectid"`, …). Engines map their native types onto this set via pure,
/// unit-tested normalizer functions; anything unmappable is `Unknown` —
/// honesty over guessing.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NormalizedType {
    Text,
    Integer,
    Float,
    Decimal,
    Boolean,
    Date,
    Datetime,
    Json,
    Uuid,
    Enum,
    Array,
    Objectid,
    Unknown,
}

/// Foreign-key target of a column. Present only for FK columns.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ForeignKeyRef {
    pub table: String,
    pub column: String,
}

/// One column (or document field) of a table/collection.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ColumnSchema {
    pub name: String,
    /// The engine's own type name (`order_status`, `varchar(255)`, `string`).
    pub native_type: String,
    pub normalized_type: NormalizedType,
    pub nullable: bool,
    /// Engine-rendered default expression, when one exists.
    pub default: Option<String>,
    /// Allowed values when `normalized_type` is `enum`.
    pub enum_values: Option<Vec<String>>,
    /// FK target, only for foreign-key columns.
    pub references: Option<ForeignKeyRef>,
    /// `true` only for sample-based inference (Mongo without a `$jsonSchema`
    /// validator) — the shape is a statistical guess, not a declared contract.
    pub inferred: bool,
}

/// One table / collection.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TableSchema {
    pub name: String,
    pub primary_key: Vec<String>,
    pub columns: Vec<ColumnSchema>,
}

/// The full per-mount schema returned by `POST /v1/schema`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SchemaDescriptor {
    pub engine: String,
    pub tables: Vec<TableSchema>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn schema_descriptor_serde_round_trip_matches_wire_contract() {
        // The FIXED wire contract from the M22 plan: snake_case normalized
        // types, nullable `default` / `enum_values` / `references`, `inferred`.
        let wire = json!({
            "engine": "postgresql",
            "tables": [
                {
                    "name": "orders",
                    "primary_key": ["id"],
                    "columns": [
                        {
                            "name": "status",
                            "native_type": "order_status",
                            "normalized_type": "enum",
                            "nullable": false,
                            "default": null,
                            "enum_values": ["pending", "paid", "shipped", "cancelled"],
                            "references": { "table": "customers", "column": "id" },
                            "inferred": false
                        }
                    ]
                }
            ]
        });
        let parsed: SchemaDescriptor = serde_json::from_value(wire.clone()).expect("deserializes");
        assert_eq!(parsed.engine, "postgresql");
        assert_eq!(parsed.tables[0].primary_key, vec!["id".to_string()]);
        let col = &parsed.tables[0].columns[0];
        assert_eq!(col.normalized_type, NormalizedType::Enum);
        assert_eq!(
            col.references,
            Some(ForeignKeyRef { table: "customers".into(), column: "id".into() })
        );
        assert!(!col.inferred);
        // Round trip: serializing back yields the exact same JSON.
        assert_eq!(serde_json::to_value(&parsed).expect("serializes"), wire);
    }

    #[test]
    fn normalized_type_is_snake_case_on_the_wire() {
        for (ty, wire) in [
            (NormalizedType::Text, "\"text\""),
            (NormalizedType::Datetime, "\"datetime\""),
            (NormalizedType::Objectid, "\"objectid\""),
            (NormalizedType::Unknown, "\"unknown\""),
        ] {
            assert_eq!(serde_json::to_string(&ty).unwrap(), wire);
        }
    }
}
