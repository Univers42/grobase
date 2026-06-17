//! JSON ↔ rusqlite value conversion (pure). SQLite has no native composite
//! types, so arrays/objects are stored as their JSON text and read back as a
//! string; non-finite reals and out-of-i64 numbers degrade to Null rather than
//! panic.

use rusqlite::types::Value as SqlValue;
use serde_json::Value;

pub(super) fn json_to_sql(value: &Value) -> SqlValue {
    match value {
        Value::Null => SqlValue::Null,
        Value::Bool(b) => SqlValue::Integer(i64::from(*b)),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                SqlValue::Integer(i)
            } else if let Some(f) = n.as_f64() {
                SqlValue::Real(f)
            } else {
                SqlValue::Null
            }
        }
        Value::String(s) => SqlValue::Text(s.clone()),
        // Arrays / objects are stored as their JSON text (SQLite has no native
        // composite types); reads return them as a string.
        other => SqlValue::Text(other.to_string()),
    }
}

pub(super) fn sql_to_json(value: SqlValue) -> Value {
    match value {
        SqlValue::Null => Value::Null,
        SqlValue::Integer(i) => Value::Number(i.into()),
        SqlValue::Real(f) => serde_json::Number::from_f64(f).map_or(Value::Null, Value::Number),
        SqlValue::Text(s) => Value::String(s),
        SqlValue::Blob(b) => Value::String(format!("blob:{} bytes", b.len())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── value conversion: json_to_sql / sql_to_json (round-trip & shape) ─────

    #[test]
    fn json_to_sql_null_bool_int_float_string() {
        assert!(matches!(json_to_sql(&Value::Null), SqlValue::Null));
        assert!(matches!(json_to_sql(&json!(true)), SqlValue::Integer(1)));
        assert!(matches!(json_to_sql(&json!(false)), SqlValue::Integer(0)));
        assert!(matches!(json_to_sql(&json!(42)), SqlValue::Integer(42)));
        assert!(matches!(json_to_sql(&json!(-7)), SqlValue::Integer(-7)));
        assert!(matches!(json_to_sql(&json!(0)), SqlValue::Integer(0)));
        let SqlValue::Real(f) = json_to_sql(&json!(3.5)) else {
            panic!("expected Real");
        };
        assert_eq!(f, 3.5);
        let SqlValue::Text(s) = json_to_sql(&json!("hi")) else {
            panic!("expected Text");
        };
        assert_eq!(s, "hi");
    }

    #[test]
    fn json_to_sql_i64_extremes_stay_integer() {
        assert!(matches!(
            json_to_sql(&json!(i64::MAX)),
            SqlValue::Integer(i) if i == i64::MAX
        ));
        assert!(matches!(
            json_to_sql(&json!(i64::MIN)),
            SqlValue::Integer(i) if i == i64::MIN
        ));
    }

    #[test]
    fn json_to_sql_u64_above_i64_max_falls_to_real() {
        // u64::MAX is not representable as i64, so as_i64() is None → Real path.
        let SqlValue::Real(f) = json_to_sql(&json!(u64::MAX)) else {
            panic!("expected Real for u64::MAX, got non-Real");
        };
        assert!(f > 0.0);
    }

    #[test]
    fn json_to_sql_empty_and_unicode_strings() {
        assert!(matches!(json_to_sql(&json!("")), SqlValue::Text(s) if s.is_empty()));
        let SqlValue::Text(s) = json_to_sql(&json!("héllo-🦀-世界")) else {
            panic!("expected Text");
        };
        assert_eq!(s, "héllo-🦀-世界");
    }

    #[test]
    fn json_to_sql_arrays_and_objects_become_json_text() {
        let SqlValue::Text(arr) = json_to_sql(&json!([1, 2, 3])) else {
            panic!("expected Text for array");
        };
        assert_eq!(arr, "[1,2,3]");
        let SqlValue::Text(obj) = json_to_sql(&json!({ "k": 1 })) else {
            panic!("expected Text for object");
        };
        assert_eq!(obj, r#"{"k":1}"#);
        // Nested composite also stringifies.
        let SqlValue::Text(nested) = json_to_sql(&json!({ "a": [true, null] })) else {
            panic!("expected Text for nested");
        };
        assert_eq!(nested, r#"{"a":[true,null]}"#);
    }

    #[test]
    fn json_to_sql_large_float_is_real() {
        let SqlValue::Real(f) = json_to_sql(&json!(1.7976931348623157e308_f64)) else {
            panic!("expected Real");
        };
        assert!(f.is_finite());
    }

    #[test]
    fn sql_to_json_round_trips_each_variant() {
        assert_eq!(sql_to_json(SqlValue::Null), Value::Null);
        assert_eq!(sql_to_json(SqlValue::Integer(9)), json!(9));
        assert_eq!(sql_to_json(SqlValue::Text("x".into())), json!("x"));
        let r = sql_to_json(SqlValue::Real(2.5));
        assert_eq!(r, json!(2.5));
        // A blob surfaces as a descriptive string (never panics).
        let b = sql_to_json(SqlValue::Blob(vec![1, 2, 3]));
        assert_eq!(b, json!("blob:3 bytes"));
    }

    #[test]
    fn sql_to_json_non_finite_real_becomes_null() {
        // from_f64 returns None for NaN/Inf, so the helper maps it to Null
        // rather than panicking.
        assert_eq!(sql_to_json(SqlValue::Real(f64::NAN)), Value::Null);
        assert_eq!(sql_to_json(SqlValue::Real(f64::INFINITY)), Value::Null);
    }

    #[test]
    fn json_to_sql_then_back_preserves_scalars() {
        for v in [json!(7), json!("str"), Value::Null, json!(true)] {
            let back = sql_to_json(json_to_sql(&v));
            // bool round-trips to its integer form (SQLite has no bool type).
            let expected = if v == json!(true) {
                json!(1)
            } else {
                v.clone()
            };
            assert_eq!(back, expected, "round-trip {v}");
        }
    }
}
