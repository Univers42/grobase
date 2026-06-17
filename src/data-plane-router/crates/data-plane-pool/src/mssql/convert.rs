//! JSON ↔ native conversion: bind-param building (`json_to_param`), row/cell
//! materialization, and the introspection type-name normalizer. All pure.

use super::*;
use super::query::P;

pub(super) fn json_to_param(value: &Value) -> P {
    match value {
        Value::Null => P::Null,
        Value::Bool(b) => P::Bool(*b),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                P::Int(i)
            } else if let Some(f) = n.as_f64() {
                P::Real(f)
            } else {
                P::Null
            }
        }
        Value::String(s) => P::Text(s.clone()),
        other => P::Text(other.to_string()),
    }
}

pub(super) fn row_to_json(row: tiberius::Row) -> Value {
    let names: Vec<String> = row.columns().iter().map(|c| c.name().to_string()).collect();
    let mut obj = JsonMap::with_capacity(names.len());
    for (name, cell) in names.into_iter().zip(row.into_iter()) {
        obj.insert(name, column_data_to_json(cell));
    }
    Value::Object(obj)
}

// ponytail: irreducible value-conversion match — one arm per `tiberius::ColumnData`
//   variant exercised by the safe CRUD surface; the catch-all stringifies the
//   rest. Nothing to factor out.
fn column_data_to_json(cell: ColumnData<'static>) -> Value {
    match cell {
        ColumnData::U8(v) => v.map_or(Value::Null, |x| Value::Number(x.into())),
        ColumnData::I16(v) => v.map_or(Value::Null, |x| Value::Number(x.into())),
        ColumnData::I32(v) => v.map_or(Value::Null, |x| Value::Number(x.into())),
        ColumnData::I64(v) => v.map_or(Value::Null, |x| Value::Number(x.into())),
        ColumnData::F32(v) => v.map_or(Value::Null, |x| f64_to_json(f64::from(x))),
        ColumnData::F64(v) => v.map_or(Value::Null, f64_to_json),
        ColumnData::Bit(v) => v.map_or(Value::Null, Value::Bool),
        ColumnData::String(v) => v.map_or(Value::Null, |s| Value::String(s.into_owned())),
        ColumnData::Guid(v) => v.map_or(Value::Null, |g| Value::String(g.to_string())),
        ColumnData::Numeric(v) => v.map_or(Value::Null, |n| Value::String(n.to_string())),
        ColumnData::Binary(v) => v.map_or(Value::Null, |b| Value::String(format!("blob:{} bytes", b.len()))),
        // Date/time/xml variants aren't exercised by the safe CRUD surface; map
        // any remaining variant to a stringified form rather than failing.
        _ => Value::String("<unsupported-column-type>".to_string()),
    }
}

pub(super) fn f64_to_json(f: f64) -> Value {
    serde_json::Number::from_f64(f).map_or(Value::Null, Value::Number)
}

pub(super) fn normalize_mssql_type(native: &str) -> NormalizedType {
    let t = native.to_ascii_lowercase();
    if t.contains("int") {
        NormalizedType::Integer
    } else if t.contains("char") || t.contains("text") {
        NormalizedType::Text
    } else if t.contains("real") || t.contains("float") {
        NormalizedType::Float
    } else if t.contains("decimal") || t.contains("numeric") || t.contains("money") {
        NormalizedType::Decimal
    } else if t.contains("bit") {
        NormalizedType::Boolean
    } else if t.contains("date") || t.contains("time") {
        NormalizedType::Datetime
    } else if t.contains("uniqueidentifier") {
        NormalizedType::Uuid
    } else {
        NormalizedType::Unknown
    }
}
