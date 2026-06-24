/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   convert.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:27:47 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:27:48 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! JSON↔BSON conversion and schema-shape mapping (pure, no DB access).
//!
//! Two directions: client `serde_json::Value` → wire `bson` (`json_to_doc`,
//! `value_to_bson`) and wire BSON → uniform JSON (`normalize_doc`), plus the
//! `$jsonSchema`/sample → engine-neutral column mappers describe_schema reads.
//
// ponytail: file >300 lines is co-located unit tests (~190 lines of code, the
//   rest is the per-type conversion/inference matrix). Implementation stays
//   under the limit.

use bson::{Bson, Document};
use data_plane_core::{ColumnSchema, DataPlaneError, DataPlaneResult, NormalizedType};
use serde_json::Value;

/// Maps a BSON type *name* (a `bsonType` string, or [`bson_value_type_name`]
/// output) to the engine-neutral [`NormalizedType`]. Pure.
pub(super) fn bson_type_to_normalized(bson_type: &str) -> NormalizedType {
    match bson_type {
        "objectId" => NormalizedType::Objectid,
        "string" => NormalizedType::Text,
        "int" | "long" => NormalizedType::Integer,
        "double" => NormalizedType::Float,
        "decimal" => NormalizedType::Decimal,
        "bool" => NormalizedType::Boolean,
        "date" => NormalizedType::Datetime,
        "array" => NormalizedType::Array,
        "object" => NormalizedType::Json,
        _ => NormalizedType::Unknown,
    }
}

/// The `bsonType` name of a live BSON value, matching the names a
/// `$jsonSchema` validator uses. Pure.
fn bson_value_type_name(value: &Bson) -> &'static str {
    match value {
        Bson::Double(_) => "double",
        Bson::String(_) => "string",
        Bson::Array(_) => "array",
        Bson::Document(_) => "object",
        Bson::Boolean(_) => "bool",
        Bson::Null => "null",
        Bson::Int32(_) => "int",
        Bson::Int64(_) => "long",
        Bson::ObjectId(_) => "objectId",
        Bson::DateTime(_) => "date",
        Bson::Decimal128(_) => "decimal",
        _ => "unknown",
    }
}

/// Derives columns from a `$jsonSchema` validator document — the collection's
/// *declared* contract, so `inferred: false`. Handles `bsonType` as a string
/// or an array of strings (a `"null"` entry means nullable), `required` for
/// nullability, and `enum` for allowed values. Pure (unit-tested without a DB).
pub(super) fn jsonschema_to_columns(schema: &Document) -> Vec<ColumnSchema> {
    let required: std::collections::BTreeSet<&str> = schema
        .get_array("required")
        .map(|arr| arr.iter().filter_map(Bson::as_str).collect())
        .unwrap_or_default();
    let Ok(props) = schema.get_document("properties") else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(props.len());
    for (name, spec) in props {
        let spec_doc = spec.as_document();
        // bsonType: "string" | ["string", "null"] | absent.
        let mut nullable_by_type = false;
        let bson_type = match spec_doc.and_then(|d| d.get("bsonType")) {
            Some(Bson::String(s)) => s.clone(),
            Some(Bson::Array(items)) => {
                nullable_by_type = items.iter().any(|b| b.as_str() == Some("null"));
                items
                    .iter()
                    .filter_map(Bson::as_str)
                    .find(|s| *s != "null")
                    .unwrap_or("unknown")
                    .to_string()
            }
            _ => "unknown".to_string(),
        };
        let enum_values: Option<Vec<String>> =
            spec_doc.and_then(|d| d.get_array("enum").ok()).map(|arr| {
                arr.iter()
                    .map(|b| match b {
                        Bson::String(s) => s.clone(),
                        other => other.to_string(),
                    })
                    .collect()
            });
        let normalized_type = if enum_values.is_some() {
            NormalizedType::Enum
        } else {
            bson_type_to_normalized(&bson_type)
        };
        out.push(ColumnSchema {
            name: name.clone(),
            native_type: bson_type,
            normalized_type,
            nullable: !required.contains(name.as_str()) || nullable_by_type,
            default: None,
            enum_values,
            references: None,
            inferred: false,
        });
    }
    out
}

/// Infers columns from sampled documents: per-field majority (non-null) BSON
/// type; a field absent from some documents or carrying nulls is nullable.
/// Always `inferred: true` — a statistical guess, not a declared contract.
/// Pure (unit-tested without a DB).
pub(super) fn infer_columns_from_samples(docs: &[Document]) -> Vec<ColumnSchema> {
    use std::collections::BTreeMap;
    let total = docs.len();
    // field → (present count, null count, type → count)
    let mut fields: BTreeMap<String, (usize, usize, BTreeMap<&'static str, usize>)> =
        BTreeMap::new();
    for doc in docs {
        for (key, value) in doc {
            let entry = fields.entry(key.clone()).or_default();
            entry.0 += 1;
            let type_name = bson_value_type_name(value);
            if type_name == "null" {
                entry.1 += 1;
            } else {
                *entry.2.entry(type_name).or_default() += 1;
            }
        }
    }
    fields
        .into_iter()
        .map(|(name, (present, nulls, counts))| {
            // Majority vote over non-null types; BTreeMap iteration makes the
            // tie-break deterministic (first alphabetically wins).
            let majority = counts
                .iter()
                .max_by_key(|(_, count)| *count)
                .map(|(ty, _)| *ty)
                .unwrap_or("unknown");
            ColumnSchema {
                nullable: present < total || nulls > 0,
                native_type: majority.to_string(),
                normalized_type: bson_type_to_normalized(majority),
                name,
                default: None,
                enum_values: None,
                references: None,
                inferred: true,
            }
        })
        .collect()
}

pub(super) fn json_to_doc(value: &Value) -> DataPlaneResult<Document> {
    match value {
        Value::Object(_) => bson::to_document(value).map_err(|e| DataPlaneError::Backend {
            message: format!("json→bson document: {e}"),
        }),
        _ => Err(DataPlaneError::InvalidRequest {
            message: "expected JSON object".to_string(),
        }),
    }
}

pub(super) fn value_to_bson(value: &Value) -> DataPlaneResult<Bson> {
    bson::to_bson(value).map_err(|e| DataPlaneError::Backend {
        message: format!("json→bson: {e}"),
    })
}

pub(super) fn normalize_doc(mut doc: Document) -> Value {
    // Map Mongo's `_id` → `id` so downstream contracts (SDK, dashboard, the graph)
    // see a uniform `id`. But NEVER clobber a client-supplied logical `id`: the
    // graph addresses a node by its logical id (the NodeId pk) and edges reference
    // that same id — overwriting it with the auto-generated ObjectId would
    // disconnect the node from its edges in `/graph/overview`. Only synthesize
    // `id` from `_id` when the document has no logical `id` of its own.
    let had_logical_id = doc.contains_key("id");
    if let Some(id) = doc.remove("_id") {
        if !had_logical_id {
            let id_str = match id {
                Bson::ObjectId(o) => o.to_hex(),
                Bson::String(s) => s,
                other => other.to_string(),
            };
            doc.insert("id", id_str);
        }
    }
    Bson::Document(doc).into_relaxed_extjson()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── value_to_bson / json_to_doc: every JSON type ─────────────────────────

    #[test]
    fn value_to_bson_maps_each_scalar_type() {
        assert!(matches!(value_to_bson(&Value::Null).unwrap(), Bson::Null));
        assert!(matches!(
            value_to_bson(&json!(true)).unwrap(),
            Bson::Boolean(true)
        ));
        assert!(matches!(
            value_to_bson(&json!(false)).unwrap(),
            Bson::Boolean(false)
        ));
        // serde_json small integers become Int64 through bson.
        assert!(matches!(
            value_to_bson(&json!(42)).unwrap(),
            Bson::Int64(42)
        ));
        assert!(matches!(
            value_to_bson(&json!(-7)).unwrap(),
            Bson::Int64(-7)
        ));
        assert!(matches!(
            value_to_bson(&json!(i64::MAX)).unwrap(),
            Bson::Int64(i) if i == i64::MAX
        ));
        assert!(matches!(
            value_to_bson(&json!(i64::MIN)).unwrap(),
            Bson::Int64(i) if i == i64::MIN
        ));
        // floats become Double.
        let Bson::Double(d) = value_to_bson(&json!(3.5)).unwrap() else {
            panic!("expected Double");
        };
        assert_eq!(d, 3.5);
        // strings become String (incl. empty + unicode).
        assert_eq!(value_to_bson(&json!("")).unwrap(), Bson::String("".into()));
        assert_eq!(
            value_to_bson(&json!("héllo-🦀")).unwrap(),
            Bson::String("héllo-🦀".into())
        );
    }

    #[test]
    fn value_to_bson_handles_arrays_and_nested_objects() {
        let Bson::Array(arr) = value_to_bson(&json!([1, "two", true])).unwrap() else {
            panic!("expected Array");
        };
        assert_eq!(arr.len(), 3);
        let Bson::Document(d) = value_to_bson(&json!({ "a": { "b": [null] } })).unwrap() else {
            panic!("expected Document");
        };
        assert!(d.contains_key("a"));
    }

    #[test]
    fn value_to_bson_rejects_u64_above_i64_max_as_backend_error() {
        // bson 2.x has no unsigned-integer type, so a JSON number above i64::MAX
        // cannot serialize. The helper maps that to a Backend error (graceful) —
        // it must NEVER panic. (Values up to i64::MAX still round-trip as Int64.)
        let err = value_to_bson(&json!(u64::MAX)).unwrap_err();
        assert!(
            matches!(err, DataPlaneError::Backend { .. }),
            "u64::MAX → Backend error, got {err:?}"
        );
        // The largest value that DOES fit is i64::MAX.
        assert!(matches!(
            value_to_bson(&json!(i64::MAX as u64)).unwrap(),
            Bson::Int64(i) if i == i64::MAX
        ));
        // One past it (i64::MAX + 1) already fails.
        assert!(value_to_bson(&json!((i64::MAX as u64) + 1)).is_err());
    }

    #[test]
    fn json_to_doc_requires_an_object() {
        let d = json_to_doc(&json!({ "k": 1, "nested": { "x": [1, 2] } })).unwrap();
        assert_eq!(d.get_i64("k").unwrap(), 1);
        // non-objects are rejected as InvalidRequest (not Backend, not panic).
        for bad in [
            json!([1, 2]),
            json!("s"),
            json!(7),
            Value::Null,
            json!(true),
        ] {
            assert!(
                matches!(
                    json_to_doc(&bad),
                    Err(DataPlaneError::InvalidRequest { .. })
                ),
                "should reject {bad}"
            );
        }
    }

    #[test]
    fn json_to_doc_empty_object_is_empty_document() {
        let d = json_to_doc(&json!({})).unwrap();
        assert!(d.is_empty());
    }

    // ── normalize_doc: _id→id, ObjectId hex, logical-id preservation ─────────

    #[test]
    fn normalize_doc_promotes_objectid_id_to_hex_string() {
        let oid = bson::oid::ObjectId::new();
        let mut d = Document::new();
        d.insert("_id", oid);
        d.insert("name", "x");
        let Value::Object(m) = normalize_doc(d) else {
            panic!()
        };
        assert_eq!(m.get("id"), Some(&json!(oid.to_hex())));
        assert!(!m.contains_key("_id"), "_id is consumed");
        assert_eq!(m.get("name"), Some(&json!("x")));
    }

    #[test]
    fn normalize_doc_preserves_logical_id_and_drops_objectid() {
        // A document with BOTH a logical `id` and an `_id` keeps the logical id
        // (so graph edges stay connected); _id is removed, not promoted.
        let oid = bson::oid::ObjectId::new();
        let mut d = Document::new();
        d.insert("_id", oid);
        d.insert("id", "logical-123");
        let Value::Object(m) = normalize_doc(d) else {
            panic!()
        };
        assert_eq!(m.get("id"), Some(&json!("logical-123")));
        assert!(!m.contains_key("_id"));
    }

    #[test]
    fn normalize_doc_string_id_promotes_verbatim() {
        let mut d = Document::new();
        d.insert("_id", "string-id");
        let Value::Object(m) = normalize_doc(d) else {
            panic!()
        };
        assert_eq!(m.get("id"), Some(&json!("string-id")));
    }

    #[test]
    fn normalize_doc_without_id_is_unchanged_shape() {
        let mut d = Document::new();
        d.insert("name", "x");
        d.insert("n", 5_i64);
        let Value::Object(m) = normalize_doc(d) else {
            panic!()
        };
        assert!(!m.contains_key("id"));
        assert_eq!(m.get("name"), Some(&json!("x")));
    }

    // ── M22 schema introspection: pure mappers ───────────────────────────────

    #[test]
    fn jsonschema_maps_declared_columns_exactly() {
        let schema = bson::doc! {
            "bsonType": "object",
            "required": ["name", "qty"],
            "properties": {
                "name": { "bsonType": "string" },
                "qty": { "bsonType": "int" },
                "price": { "bsonType": "decimal" },
                "tags": { "bsonType": "array" },
                "meta": { "bsonType": "object" },
                "created_at": { "bsonType": "date" },
                "owner": { "bsonType": "objectId" },
                "active": { "bsonType": "bool" },
                "ratio": { "bsonType": "double" },
                "big": { "bsonType": "long" },
            }
        };
        let cols = jsonschema_to_columns(&schema);
        let by_name = |n: &str| {
            cols.iter()
                .find(|c| c.name == n)
                .unwrap_or_else(|| panic!("{n}"))
        };
        use NormalizedType as N;
        for (name, native, normalized, nullable) in [
            ("name", "string", N::Text, false),
            ("qty", "int", N::Integer, false),
            ("price", "decimal", N::Decimal, true),
            ("tags", "array", N::Array, true),
            ("meta", "object", N::Json, true),
            ("created_at", "date", N::Datetime, true),
            ("owner", "objectId", N::Objectid, true),
            ("active", "bool", N::Boolean, true),
            ("ratio", "double", N::Float, true),
            ("big", "long", N::Integer, true),
        ] {
            let col = by_name(name);
            assert_eq!(col.native_type, native, "{name}");
            assert_eq!(col.normalized_type, normalized, "{name}");
            assert_eq!(col.nullable, nullable, "{name}");
            assert!(
                !col.inferred,
                "{name}: jsonSchema columns are declared, not inferred"
            );
            assert!(col.references.is_none() && col.default.is_none(), "{name}");
        }
    }

    #[test]
    fn jsonschema_enum_and_nullable_type_arrays() {
        let schema = bson::doc! {
            "bsonType": "object",
            "required": ["status", "note"],
            "properties": {
                "status": { "enum": ["pending", "paid"] },
                // ["string","null"] → string but nullable, even though required.
                "note": { "bsonType": ["string", "null"] },
            }
        };
        let cols = jsonschema_to_columns(&schema);
        let status = cols.iter().find(|c| c.name == "status").unwrap();
        assert_eq!(status.normalized_type, NormalizedType::Enum);
        assert_eq!(
            status.enum_values,
            Some(vec!["pending".to_string(), "paid".to_string()])
        );
        let note = cols.iter().find(|c| c.name == "note").unwrap();
        assert_eq!(note.normalized_type, NormalizedType::Text);
        assert!(note.nullable, "a 'null' bsonType entry means nullable");
        // No properties → no columns (never a panic).
        assert!(jsonschema_to_columns(&bson::doc! { "bsonType": "object" }).is_empty());
    }

    #[test]
    fn sample_inference_majority_type_and_nullability() {
        let docs = vec![
            bson::doc! { "n": 1_i32, "s": "a", "maybe": Bson::Null },
            bson::doc! { "n": 2_i32, "s": "b" },
            bson::doc! { "n": "three", "s": "c", "maybe": 5_i32 },
        ];
        let cols = infer_columns_from_samples(&docs);
        let by_name = |n: &str| cols.iter().find(|c| c.name == n).unwrap();
        // Majority of `n` values are int.
        let n = by_name("n");
        assert_eq!(n.normalized_type, NormalizedType::Integer);
        assert_eq!(n.native_type, "int");
        assert!(!n.nullable, "present in every doc, never null");
        assert!(n.inferred, "sample-based columns are inferred");
        // `maybe` is missing from one doc AND null in another → nullable.
        assert!(by_name("maybe").nullable);
        // Empty sample set → no columns.
        assert!(infer_columns_from_samples(&[]).is_empty());
    }

    // ── bson_type_to_normalized / bson_value_type_name (inverse pair) ─────────

    #[test]
    fn bson_type_to_normalized_covers_the_creatable_set() {
        use NormalizedType::*;
        let cases = [
            ("objectId", Objectid),
            ("string", Text),
            ("int", Integer),
            ("long", Integer),
            ("double", Float),
            ("decimal", Decimal),
            ("bool", Boolean),
            ("date", Datetime),
            ("array", Array),
            ("object", Json),
            ("nonsense", Unknown),
            ("", Unknown),
        ];
        for (name, want) in cases {
            assert_eq!(bson_type_to_normalized(name), want, "bsonType {name}");
        }
    }

    #[test]
    fn bson_value_type_name_matches_jsonschema_names() {
        assert_eq!(bson_value_type_name(&Bson::Double(1.0)), "double");
        assert_eq!(bson_value_type_name(&Bson::String("x".into())), "string");
        assert_eq!(bson_value_type_name(&Bson::Array(vec![])), "array");
        assert_eq!(
            bson_value_type_name(&Bson::Document(Document::new())),
            "object"
        );
        assert_eq!(bson_value_type_name(&Bson::Boolean(true)), "bool");
        assert_eq!(bson_value_type_name(&Bson::Null), "null");
        assert_eq!(bson_value_type_name(&Bson::Int32(1)), "int");
        assert_eq!(bson_value_type_name(&Bson::Int64(1)), "long");
        assert_eq!(
            bson_value_type_name(&Bson::ObjectId(bson::oid::ObjectId::new())),
            "objectId"
        );
        assert_eq!(
            bson_value_type_name(&Bson::Decimal128("1".parse().unwrap())),
            "decimal"
        );
        // a variant outside the mapped set → "unknown" (never panics).
        assert_eq!(bson_value_type_name(&Bson::MinKey), "unknown");
    }
}
