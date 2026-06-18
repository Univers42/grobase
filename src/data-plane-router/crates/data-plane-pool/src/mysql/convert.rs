//! JSON ↔ native `mysql_async::Value` conversion + row materialization.

use super::*;

pub(super) fn json_to_mysql_value(v: &Value) -> MysqlValue {
    match v {
        Value::Null => MysqlValue::NULL,
        Value::Bool(b) => MysqlValue::Int(i64::from(*b)),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                MysqlValue::Int(i)
            } else if let Some(u) = n.as_u64() {
                MysqlValue::UInt(u)
            } else {
                MysqlValue::Double(n.as_f64().unwrap_or(0.0))
            }
        }
        Value::String(s) => MysqlValue::Bytes(s.clone().into_bytes()),
        // Arrays + objects become JSON strings — MySQL 5.7+ has a JSON type
        // that accepts string literals.
        other => MysqlValue::Bytes(serde_json::to_vec(other).unwrap_or_default()),
    }
}

// ponytail: irreducible value-conversion match — one arm per `mysql_async::Value`
//   variant (date/time formatting included); each arm is the canonical mapping,
//   nothing to factor out.
pub(super) fn mysql_value_to_json(v: MysqlValue) -> Value {
    match v {
        MysqlValue::NULL => Value::Null,
        MysqlValue::Int(i) => Value::Number(i.into()),
        MysqlValue::UInt(u) => Value::Number(u.into()),
        MysqlValue::Float(f) => json_number_from_f64(f64::from(f)),
        MysqlValue::Double(d) => json_number_from_f64(d),
        MysqlValue::Bytes(bytes) => match String::from_utf8(bytes) {
            Ok(s) => Value::String(s),
            // Non-UTF8 BLOB: surface as a JSON null rather than panic; the
            // adapter is JSON-shaped on purpose and binary columns should be
            // base64-encoded by the schema-service before they ever land here.
            Err(_) => Value::Null,
        },
        MysqlValue::Date(y, mo, d, h, mi, s, us) => Value::String(format!(
            "{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{us:06}Z"
        )),
        MysqlValue::Time(neg, days, h, mi, s, us) => {
            let sign = if neg { "-" } else { "" };
            let total_h = u64::from(days) * 24 + u64::from(h);
            Value::String(format!("{sign}{total_h:02}:{mi:02}:{s:02}.{us:06}"))
        }
    }
}

pub(super) fn json_number_from_f64(f: f64) -> Value {
    serde_json::Number::from_f64(f)
        .map(Value::Number)
        .unwrap_or(Value::Null)
}

pub(super) fn row_to_json(mut row: Row) -> Value {
    let columns: Vec<Column> = row.columns_ref().to_vec();
    let mut out = JsonMap::with_capacity(columns.len());
    for (idx, col) in columns.iter().enumerate() {
        let name = col.name_str().into_owned();
        let raw: MysqlValue = row.take(idx).unwrap_or(MysqlValue::NULL);
        out.insert(name, mysql_value_to_json(raw));
    }
    Value::Object(out)
}
