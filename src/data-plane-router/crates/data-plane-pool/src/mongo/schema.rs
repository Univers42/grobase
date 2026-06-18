//! M22 step 2: engine-agnostic schema DDL over a collection's `$jsonSchema`
//! validator — pure transforms ([`columns_to_jsonschema`] +
//! `jsonschema_with_*`), the exact inverse of the describe-side mappers in
//! [`super::convert`], so DDL and introspection stay one source of truth.
//
// ponytail: file >300 lines is co-located unit tests (~165 lines of code, the
//   rest is the add/alter/drop transform matrix). Implementation stays under
//   the limit.

use bson::Document;
use data_plane_core::{DataPlaneError, DataPlaneResult, DdlColumnDef, NormalizedType};

/// Whether [`jsonschema_with_column_set`] adds a new column (must NOT exist)
/// or alters an existing one (must exist).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ColumnMode {
    Add,
    Alter,
}

/// The `bsonType` name for a creatable DDL column. The exact inverse of
/// [`super::convert::bson_type_to_normalized`] over the creatable set;
/// `objectid`/`unknown` are describe-only and rejected (enums use `enum:`
/// instead of `bsonType`).
fn ddl_bson_type(def: &DdlColumnDef) -> DataPlaneResult<&'static str> {
    Ok(match def.normalized_type {
        NormalizedType::Text | NormalizedType::Uuid => "string",
        NormalizedType::Integer => "long",
        NormalizedType::Float => "double",
        NormalizedType::Decimal => "decimal",
        NormalizedType::Boolean => "bool",
        NormalizedType::Date | NormalizedType::Datetime => "date",
        NormalizedType::Json => "object",
        NormalizedType::Array => "array",
        NormalizedType::Enum => "string",
        NormalizedType::Objectid | NormalizedType::Unknown => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!(
                    "column '{}': normalized_type '{:?}' cannot be created on mongodb",
                    def.name, def.normalized_type
                ),
            })
        }
    })
}

/// One `$jsonSchema` property document for a DDL column. Nullable columns
/// declare `bsonType: [ty, "null"]` (absent OR explicit null both validate);
/// enum columns declare `enum: [...]` — exactly the shapes
/// [`super::convert::jsonschema_to_columns`] reads back.
fn ddl_column_to_property(def: &DdlColumnDef) -> DataPlaneResult<Document> {
    if def.normalized_type == NormalizedType::Enum {
        let values = def
            .enum_values
            .as_deref()
            .filter(|v| !v.is_empty())
            .ok_or_else(|| DataPlaneError::InvalidRequest {
                message: format!("enum column '{}' requires non-empty enum_values", def.name),
            })?;
        return Ok(bson::doc! { "enum": values });
    }
    let ty = ddl_bson_type(def)?;
    Ok(if def.nullable {
        bson::doc! { "bsonType": [ty, "null"] }
    } else {
        bson::doc! { "bsonType": ty }
    })
}

/// Builds the full `$jsonSchema` for `create_table` from its columns,
/// auto-appending a nullable `owner_id` string when the caller didn't declare
/// one — matching the platform's owner-scoped write path (every Mongo write
/// injects `owner_id`/`tenant_id`).
pub(super) fn columns_to_jsonschema(columns: &[DdlColumnDef]) -> DataPlaneResult<Document> {
    let mut properties = Document::new();
    let mut required: Vec<String> = Vec::new();
    let mut has_owner = false;
    for def in columns {
        if def.name == "owner_id" {
            has_owner = true;
        }
        properties.insert(def.name.clone(), ddl_column_to_property(def)?);
        if !def.nullable {
            required.push(def.name.clone());
        }
    }
    if !has_owner {
        properties.insert("owner_id", bson::doc! { "bsonType": ["string", "null"] });
    }
    let mut schema = bson::doc! { "bsonType": "object", "properties": properties };
    if !required.is_empty() {
        schema.insert("required", required);
    }
    Ok(schema)
}

/// The `required` list of a `$jsonSchema`, as owned strings.
fn jsonschema_required(schema: &Document) -> Vec<String> {
    schema
        .get_array("required")
        .map(|arr| {
            arr.iter()
                .filter_map(bson::Bson::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// Returns a new `$jsonSchema` with `def` set (added or altered). `Add`
/// refuses an existing column (409 — same conflict PG raises for a duplicate
/// column); `Alter` refuses a missing one (400).
pub(super) fn jsonschema_with_column_set(
    schema: &Document,
    def: &DdlColumnDef,
    mode: ColumnMode,
) -> DataPlaneResult<Document> {
    let mut out = schema.clone();
    let mut properties = out.get_document("properties").cloned().unwrap_or_default();
    let exists = properties.contains_key(&def.name);
    match mode {
        ColumnMode::Add if exists => {
            return Err(DataPlaneError::Conflict {
                message: format!("column '{}' already exists", def.name),
            })
        }
        ColumnMode::Alter if !exists => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("column '{}' does not exist", def.name),
            })
        }
        _ => {}
    }
    properties.insert(def.name.clone(), ddl_column_to_property(def)?);
    out.insert("bsonType", "object");
    out.insert("properties", properties);
    let mut required = jsonschema_required(&out);
    required.retain(|r| r != &def.name);
    if !def.nullable {
        required.push(def.name.clone());
    }
    if required.is_empty() {
        out.remove("required");
    } else {
        out.insert("required", required);
    }
    Ok(out)
}

/// Returns a new `$jsonSchema` with `name` removed (property + required).
/// A missing column is a client error.
pub(super) fn jsonschema_with_column_dropped(
    schema: &Document,
    name: &str,
) -> DataPlaneResult<Document> {
    let mut out = schema.clone();
    let mut properties = out.get_document("properties").cloned().unwrap_or_default();
    if properties.remove(name).is_none() {
        return Err(DataPlaneError::InvalidRequest {
            message: format!("column '{name}' does not exist"),
        });
    }
    out.insert("bsonType", "object");
    out.insert("properties", properties);
    let required: Vec<String> = jsonschema_required(&out)
        .into_iter()
        .filter(|r| r != name)
        .collect();
    if required.is_empty() {
        out.remove("required");
    } else {
        out.insert("required", required);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::super::convert::jsonschema_to_columns;
    use super::*;
    use data_plane_core::DdlColumnDef;

    fn col(name: &str, ty: NormalizedType, nullable: bool) -> DdlColumnDef {
        DdlColumnDef {
            name: name.to_string(),
            normalized_type: ty,
            nullable,
            default: None,
            enum_values: None,
        }
    }

    #[test]
    fn ddl_property_mapping_golden_table() {
        use NormalizedType as N;
        for (ty, bson_ty) in [
            (N::Text, "string"),
            (N::Uuid, "string"),
            (N::Integer, "long"),
            (N::Float, "double"),
            (N::Decimal, "decimal"),
            (N::Boolean, "bool"),
            (N::Date, "date"),
            (N::Datetime, "date"),
            (N::Json, "object"),
            (N::Array, "array"),
        ] {
            assert_eq!(
                ddl_column_to_property(&col("c", ty, false)).unwrap(),
                bson::doc! { "bsonType": bson_ty },
                "{ty:?}"
            );
            // nullable columns accept null explicitly (bsonType array).
            assert_eq!(
                ddl_column_to_property(&col("c", ty, true)).unwrap(),
                bson::doc! { "bsonType": [bson_ty, "null"] },
                "nullable {ty:?}"
            );
        }
        // enum → `enum:` (no bsonType), and requires values.
        let mut status = col("status", NormalizedType::Enum, false);
        status.enum_values = Some(vec!["a".into(), "b".into()]);
        assert_eq!(
            ddl_column_to_property(&status).unwrap(),
            bson::doc! { "enum": ["a", "b"] }
        );
        assert!(ddl_column_to_property(&col("status", NormalizedType::Enum, false)).is_err());
        // describe-only types are rejected.
        for ty in [NormalizedType::Objectid, NormalizedType::Unknown] {
            assert!(matches!(
                ddl_column_to_property(&col("c", ty, false)).unwrap_err(),
                DataPlaneError::InvalidRequest { .. }
            ));
        }
    }

    #[test]
    fn create_table_jsonschema_appends_owner_and_round_trips_describe() {
        let columns = vec![
            col("name", NormalizedType::Text, false),
            col("qty", NormalizedType::Integer, true),
        ];
        let schema = columns_to_jsonschema(&columns).unwrap();
        assert_eq!(
            schema,
            bson::doc! {
                "bsonType": "object",
                "properties": {
                    "name": { "bsonType": "string" },
                    "qty": { "bsonType": ["long", "null"] },
                    "owner_id": { "bsonType": ["string", "null"] },
                },
                "required": ["name"],
            }
        );
        // Round trip through the M22 describe mapper: DDL writes exactly the
        // shapes describe_schema reads back.
        let described = jsonschema_to_columns(&schema);
        let by_name = |n: &str| described.iter().find(|c| c.name == n).unwrap();
        assert_eq!(by_name("name").normalized_type, NormalizedType::Text);
        assert!(!by_name("name").nullable);
        assert_eq!(by_name("qty").normalized_type, NormalizedType::Integer);
        assert!(by_name("qty").nullable);
        assert!(by_name("owner_id").nullable);
        // An explicit owner_id is respected, never duplicated.
        let explicit =
            columns_to_jsonschema(&[col("owner_id", NormalizedType::Text, false)]).unwrap();
        let props = explicit.get_document("properties").unwrap();
        assert_eq!(
            props.get_document("owner_id").unwrap(),
            &bson::doc! { "bsonType": "string" }
        );
    }

    #[test]
    fn jsonschema_add_alter_drop_column_transforms() {
        let base = columns_to_jsonschema(&[col("name", NormalizedType::Text, false)]).unwrap();

        // add: new column lands in properties (+required when non-nullable).
        let added = jsonschema_with_column_set(
            &base,
            &col("qty", NormalizedType::Integer, false),
            ColumnMode::Add,
        )
        .unwrap();
        assert!(added
            .get_document("properties")
            .unwrap()
            .contains_key("qty"));
        assert_eq!(jsonschema_required(&added), vec!["name", "qty"]);
        // add of an existing column is a 409 conflict.
        assert!(matches!(
            jsonschema_with_column_set(
                &base,
                &col("name", NormalizedType::Text, true),
                ColumnMode::Add
            )
            .unwrap_err(),
            DataPlaneError::Conflict { .. }
        ));

        // alter: full target def replaces the property AND nullability.
        let altered = jsonschema_with_column_set(
            &added,
            &col("qty", NormalizedType::Text, true),
            ColumnMode::Alter,
        )
        .unwrap();
        assert_eq!(
            altered
                .get_document("properties")
                .unwrap()
                .get_document("qty")
                .unwrap(),
            &bson::doc! { "bsonType": ["string", "null"] }
        );
        assert_eq!(
            jsonschema_required(&altered),
            vec!["name"],
            "now nullable → not required"
        );
        // alter of a missing column is a 400.
        assert!(matches!(
            jsonschema_with_column_set(
                &base,
                &col("ghost", NormalizedType::Text, true),
                ColumnMode::Alter
            )
            .unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));

        // drop: property + required entry removed; missing column is a 400.
        let dropped = jsonschema_with_column_dropped(&added, "qty").unwrap();
        assert!(!dropped
            .get_document("properties")
            .unwrap()
            .contains_key("qty"));
        assert_eq!(jsonschema_required(&dropped), vec!["name"]);
        assert!(matches!(
            jsonschema_with_column_dropped(&added, "ghost").unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
        // dropping the LAST required column removes the (must-be-non-empty)
        // `required` key entirely instead of leaving an invalid empty array.
        let only = columns_to_jsonschema(&[col("name", NormalizedType::Text, false)]).unwrap();
        let none_required = jsonschema_with_column_dropped(&only, "name").unwrap();
        assert!(!none_required.contains_key("required"));
    }

    // ── ddl_bson_type: creatable mapping + describe-only rejection ────────────

    #[test]
    fn ddl_bson_type_maps_creatable_and_rejects_describe_only() {
        let mk = |ty: NormalizedType| DdlColumnDef {
            name: "c".into(),
            normalized_type: ty,
            nullable: true,
            default: None,
            enum_values: None,
        };
        use NormalizedType::*;
        for (ty, want) in [
            (Text, "string"),
            (Uuid, "string"),
            (Integer, "long"),
            (Float, "double"),
            (Decimal, "decimal"),
            (Boolean, "bool"),
            (Date, "date"),
            (Datetime, "date"),
            (Json, "object"),
            (Array, "array"),
            (Enum, "string"),
        ] {
            assert_eq!(ddl_bson_type(&mk(ty)).unwrap(), want, "type {ty:?}");
        }
        // objectid / unknown are describe-only → InvalidRequest.
        assert!(ddl_bson_type(&mk(Objectid)).is_err());
        assert!(ddl_bson_type(&mk(Unknown)).is_err());
    }
}
