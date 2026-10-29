/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   typed.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/29 23:10:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 23:10:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! A cell against its declared type, in both directions (pure, no DB access).
//!
//! JSON has no long, decimal, date or binary, so a client sends those as text
//! (`"9007199254740991"`, `"12.50"`, `"2026-10-29"`, `"\xdead"`) — the form
//! every SQL engine accepts. A `$jsonSchema` validator rejects that text
//! (code 121), so [`coerce_to_validator`] converts each top-level value to its
//! column's `bsonType`. [`render_cell`] is the way back: the same values read
//! as that text, not as `{"$numberDecimal": …}` extended-JSON wrappers.

use bson::spec::BinarySubtype;
use bson::{Binary, Bson, DateTime, Decimal128, Document};
use data_plane_core::binary::{hex_bytes, parse_hex_bytes};
use serde_json::Value;

/// The declared `bsonType` of `field` — the first non-`null` entry when the
/// validator lists several (`["long", "null"]`).
fn declared_type<'a>(schema: &'a Document, field: &str) -> Option<&'a str> {
    let spec = schema
        .get_document("properties")
        .ok()?
        .get_document(field)
        .ok()?;
    match spec.get("bsonType")? {
        Bson::String(ty) => Some(ty.as_str()),
        Bson::Array(types) => types.iter().find_map(|t| match t {
            Bson::String(ty) if ty != "null" => Some(ty.as_str()),
            _ => None,
        }),
        _ => None,
    }
}

/// `2026-10-29T12:34:56Z` or a bare `2026-10-29` (midnight UTC).
fn parse_date(text: &str) -> Option<DateTime> {
    DateTime::parse_rfc3339_str(text)
        .or_else(|_| DateTime::parse_rfc3339_str(format!("{text}T00:00:00Z")))
        .ok()
}

/// `value` as `bson_type`, or `None` when it already fits or cannot convert
/// (the validator then rejects it with its own message).
fn coerce(value: &Bson, bson_type: &str) -> Option<Bson> {
    match (bson_type, value) {
        ("long", Bson::String(s)) => s.trim().parse().ok().map(Bson::Int64),
        ("long", Bson::Int32(n)) => Some(Bson::Int64(i64::from(*n))),
        ("int", Bson::String(s)) => s.trim().parse().ok().map(Bson::Int32),
        ("int", Bson::Int64(n)) => i32::try_from(*n).ok().map(Bson::Int32),
        ("double", Bson::String(s)) => s.trim().parse().ok().map(Bson::Double),
        ("double", Bson::Int32(n)) => Some(Bson::Double(f64::from(*n))),
        // Caveat: an integer beyond 2^53 loses precision as a double — the
        // same loss the JSON client already took when it parsed the number.
        ("double", Bson::Int64(n)) => Some(Bson::Double(*n as f64)),
        ("decimal", Bson::String(s)) => s.trim().parse::<Decimal128>().ok().map(Bson::Decimal128),
        ("decimal", Bson::Int32(_) | Bson::Int64(_) | Bson::Double(_)) => render_number(value)
            .parse::<Decimal128>()
            .ok()
            .map(Bson::Decimal128),
        ("date", Bson::String(s)) => parse_date(s.trim()).map(Bson::DateTime),
        ("binData", Bson::String(s)) => parse_hex_bytes(s).map(|bytes| {
            Bson::Binary(Binary {
                subtype: BinarySubtype::Generic,
                bytes,
            })
        }),
        _ => None,
    }
}

fn render_number(value: &Bson) -> String {
    match value {
        Bson::Int32(n) => n.to_string(),
        Bson::Int64(n) => n.to_string(),
        Bson::Double(n) => n.to_string(),
        _ => String::new(),
    }
}

/// Converts each top-level field of `doc` to its declared `bsonType`; returns
/// whether anything changed (nothing changed → retrying the write is pointless).
///
/// Caveat: top-level fields only — a value nested in an `object` or `array`
/// column keeps its JSON type, so a nested date stays a string.
pub(super) fn coerce_to_validator(doc: &mut Document, schema: &Document) -> bool {
    let mut changed = false;
    for (field, value) in doc.iter_mut() {
        let Some(bson_type) = declared_type(schema, field) else {
            continue;
        };
        if let Some(converted) = coerce(value, bson_type) {
            *value = converted;
            changed = true;
        }
    }
    changed
}

/// One BSON value as uniform JSON: decimal, date and generic binary read in
/// the text form a write accepts; everything else as relaxed extended JSON.
pub(super) fn render_cell(value: Bson) -> Value {
    match value {
        Bson::Decimal128(d) => Value::String(d.to_string()),
        Bson::DateTime(dt) => match dt.try_to_rfc3339_string() {
            Ok(text) => Value::String(text),
            // Outside years 0–9999: no RFC 3339 form, keep the wrapper.
            Err(_) => Bson::DateTime(dt).into_relaxed_extjson(),
        },
        Bson::Binary(Binary {
            subtype: BinarySubtype::Generic,
            bytes,
        }) => Value::String(hex_bytes(&bytes)),
        Bson::Document(doc) => {
            Value::Object(doc.into_iter().map(|(k, v)| (k, render_cell(v))).collect())
        }
        Bson::Array(items) => Value::Array(items.into_iter().map(render_cell).collect()),
        other => other.into_relaxed_extjson(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bson::doc;
    use serde_json::json;

    fn schema() -> Document {
        doc! { "bsonType": "object", "properties": {
            "big": { "bsonType": ["long", "null"] },
            "small": { "bsonType": "int" },
            "ratio": { "bsonType": "double" },
            "price": { "bsonType": "decimal" },
            "day": { "bsonType": "date" },
            "at": { "bsonType": ["date", "null"] },
            "blob": { "bsonType": "binData" },
            "name": { "bsonType": "string" },
        } }
    }

    #[test]
    fn text_values_become_their_declared_types() {
        let mut row = doc! {
            "big": "9007199254740993", "small": 7_i64, "ratio": 3_i64,
            "price": "12.50", "day": "2026-10-29", "at": "2026-10-29T12:34:56Z",
            "blob": "\\xdead00ff", "name": "12.50", "undeclared": "1",
        };
        assert!(coerce_to_validator(&mut row, &schema()));
        assert_eq!(row.get("big"), Some(&Bson::Int64(9_007_199_254_740_993)));
        assert_eq!(row.get("small"), Some(&Bson::Int32(7)));
        assert_eq!(row.get("ratio"), Some(&Bson::Double(3.0)));
        assert_eq!(row.get_decimal128("price").unwrap().to_string(), "12.50");
        assert_eq!(
            row.get_datetime("day")
                .unwrap()
                .try_to_rfc3339_string()
                .unwrap(),
            "2026-10-29T00:00:00Z"
        );
        assert_eq!(
            row.get_datetime("at").unwrap().timestamp_millis(),
            1_793_277_296_000
        );
        assert_eq!(
            row.get_binary_generic("blob").unwrap(),
            &vec![0xde, 0xad, 0x00, 0xff]
        );
        assert_eq!(
            row.get_str("name").unwrap(),
            "12.50",
            "a string column stays text"
        );
        assert_eq!(row.get_str("undeclared").unwrap(), "1");
    }

    #[test]
    fn nothing_to_convert_reports_unchanged() {
        let mut fits = doc! { "big": 1_i64, "name": "x", "price": "not a number" };
        assert!(!coerce_to_validator(&mut fits, &schema()));
        assert_eq!(fits.get_str("price").unwrap(), "not a number");
        assert!(!coerce_to_validator(
            &mut fits,
            &doc! { "bsonType": "object" }
        ));
    }

    #[test]
    fn rendered_cells_read_back_as_the_text_a_write_accepts() {
        let mut row = doc! {
            "price": "12.50", "at": "2026-10-29T12:34:56Z", "blob": "\\xdead00ff",
        };
        coerce_to_validator(&mut row, &schema());
        row.insert(
            "nested",
            doc! { "price": row.get("price").unwrap().clone() },
        );
        row.insert("n", 42_i64);
        assert_eq!(
            render_cell(Bson::Document(row)),
            json!({
                "price": "12.50", "at": "2026-10-29T12:34:56Z", "blob": "\\xdead00ff",
                "nested": { "price": "12.50" }, "n": 42,
            })
        );
    }
}
