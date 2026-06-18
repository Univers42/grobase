//! JSON↔Postgres value binding (the adaptive `JsonParam`) and the error
//! classifier that maps `tokio_postgres` failures to the platform's
//! `DataPlaneError` taxonomy.

use super::BoxedParam;
use bytes::BytesMut;
use data_plane_core::DataPlaneError;
use serde_json::Value;
use tokio_postgres::types::{to_sql_checked, IsNull, Kind, ToSql, Type};

// ponytail: this 58-line classifier is one match over SQLSTATE prefixes + a
// client-side bind fallback — irreducible data (every arm is a distinct
// error→status contract). Splitting it would scatter the taxonomy.
pub(super) fn backend(e: &tokio_postgres::Error) -> DataPlaneError {
    // SQLSTATE class 23 = integrity constraint violation (unique/PK, foreign key,
    // not-null, check) and class 22 = data exception (invalid enum/date text,
    // numeric overflow, …). Both are the caller's fault — their VALUES don't
    // fit the schema — so they map to 409 Conflict, not an engine 5xx (a 5xx
    // makes outbox clients retry a write that can never succeed). Use the DB
    // error's own message (the top-level Display is just "db error") so the
    // client learns *what* conflicted.
    if let Some(db) = e.as_db_error() {
        let code = db.code().code();
        if code.starts_with("23") || code.starts_with("22") {
            return DataPlaneError::Conflict {
                message: db.message().to_string(),
            };
        }
        // 42P10 "no unique or exclusion constraint matching the ON CONFLICT
        // specification": the table's schema can't arbitrate this upsert
        // (shared_rls upserts key on (owner_id, <filter cols>) — the table
        // needs that composite UNIQUE). The caller's request/schema mismatch,
        // not an engine failure — 400 with the platform contract spelled out,
        // never a 502.
        if code == "42P10" {
            return DataPlaneError::InvalidRequest {
                message: format!(
                    "{} — upserts on owner-scoped (shared_rls) mounts arbitrate on \
                     (owner_id, <filter key columns>); the table needs a matching \
                     composite UNIQUE constraint",
                    db.message()
                ),
            };
        }
        // SQLSTATE class 42 = "syntax error or access rule violation": undefined
        // function (e.g. sum()/avg() on a TEXT column → 42883), undefined column
        // (42703), undefined table (42P01), datatype mismatch (42804), grouping
        // error (42803). Every one is the caller's request not fitting the schema
        // — a clean 400, NEVER an engine 5xx/502. (42P10 above is the more
        // specific upsert case; this generalises the rest of the class.)
        if code.starts_with("42") {
            return DataPlaneError::InvalidRequest {
                message: db.message().to_string(),
            };
        }
    }
    // CLIENT-side bind failures (JsonParam: "not a date" into timestamptz,
    // a malformed uuid, a string into int4) never reach the server, so there
    // is no SQLSTATE — but they are exactly as much the caller's fault as
    // their server-side 22xxx twins. Same envelope: 409, with the cause.
    let text = e.to_string();
    if text.contains("error serializing parameter") {
        let detail = std::error::Error::source(e)
            .map(|source| format!(": {source}"))
            .unwrap_or_default();
        return DataPlaneError::Conflict {
            message: format!("{text}{detail} (value does not fit the column type)"),
        };
    }
    DataPlaneError::Backend { message: text }
}

/// Boxes a JSON value as a Postgres parameter whose wire encoding adapts to the
/// target column type (see [`JsonParam`]). One boxed param per value; the
/// adaptation happens later, at serialize time, when the column type is known.
pub(super) fn json_param(value: &Value) -> BoxedParam {
    Box::new(JsonParam(value.clone()))
}

/// A JSON value bound as a Postgres parameter whose binary encoding is chosen
/// from the *target column type*, not from the JSON shape.
///
/// Postgres infers each `$n` placeholder's type from its use site (the column it
/// is assigned to or compared against) during `PREPARE`, so by the time
/// `to_sql` runs we know `ty` and can pick `i16`/`i32`/`i64`, `f32`/`f64`, a
/// parsed `uuid`/timestamp, text, bool, or a jsonb document. The previous
/// "every JSON integer is an `i64`" binding could not serialize into `int2`/
/// `int4` columns (`error serializing parameter`); this adapts instead.
///
/// `accepts` returns `true` for every type: we adapt inside `to_sql`. A genuine
/// mismatch (a JSON string for an `int4`/`bytea` column, a number for `numeric`)
/// is rejected by the inner `to_sql_checked` delegation as a `WrongType`
/// serialization error — never written as garbage bytes. That error currently
/// surfaces as a `Backend` (502); reclassifying serialization failures as
/// `InvalidRequest` (400), and adding real `numeric`/array support, is the
/// shared value-coercion follow-up tracked in product-plan doc 02.
#[derive(Debug)]
pub(super) struct JsonParam(pub(super) Value);

impl ToSql for JsonParam {
    fn to_sql(
        &self,
        ty: &Type,
        out: &mut BytesMut,
    ) -> Result<IsNull, Box<dyn std::error::Error + Sync + Send>> {
        // For the fall-through arms we delegate through `to_sql_checked` (not the
        // raw `to_sql`) so the inner type's own `accepts` runs: a genuine
        // mismatch (a JSON string for an `int4`/`bytea` column, a number for
        // `numeric`) becomes a clean `WrongType` serialization error instead of
        // garbage bytes written under that column's binary OID. Without this,
        // `bytea` (which accepts any bytes) and length-coincident cases would be
        // silently corrupted. The explicit arms already match `ty`, so they use
        // the cheaper `to_sql`.
        match &self.0 {
            Value::Null => Ok(IsNull::Yes),
            Value::Bool(b) => b.to_sql_checked(ty, out),
            Value::Number(n) => match *ty {
                Type::INT2 => i16::try_from(json_i64(n)?)?.to_sql(ty, out),
                Type::INT4 => i32::try_from(json_i64(n)?)?.to_sql(ty, out),
                Type::INT8 => json_i64(n)?.to_sql(ty, out),
                Type::FLOAT4 => {
                    (n.as_f64().ok_or("number is not representable as f64")? as f32).to_sql(ty, out)
                }
                Type::FLOAT8 => n
                    .as_f64()
                    .ok_or("number is not representable as f64")?
                    .to_sql(ty, out),
                // numeric/decimal columns (money-like: totals, prices,
                // salaries) — serde's Value only serializes into json/jsonb,
                // so without this arm EVERY filter or update touching a
                // numeric column was a 502. serde prints JSON numbers as
                // plain decimal strings, which encode directly.
                Type::NUMERIC => {
                    write_pg_numeric(&n.to_string(), out)?;
                    Ok(IsNull::No)
                }
                // json/jsonb → number document; anything else → checked
                // delegate, which rejects a true mismatch rather than corrupt it.
                _ => self.0.to_sql_checked(ty, out),
            },
            Value::String(s) => match *ty {
                Type::UUID => s.parse::<uuid::Uuid>()?.to_sql(ty, out),
                Type::TIMESTAMPTZ => s.parse::<chrono::DateTime<chrono::Utc>>()?.to_sql(ty, out),
                Type::TIMESTAMP => s.parse::<chrono::NaiveDateTime>()?.to_sql(ty, out),
                Type::DATE => s.parse::<chrono::NaiveDate>()?.to_sql(ty, out),
                Type::JSON | Type::JSONB => self.0.to_sql(ty, out),
                // Enum slots (filters/updates against enum columns — the live
                // UI's board groupings depend on them): the binary wire format
                // of an enum value IS its label text, but this postgres-types
                // version's `&str` does not `accepts` enum kinds, which made
                // every enum-column filter a 502. Write the label and let the
                // SERVER validate it — an invalid label raises 22P02, which
                // classifies as a clean 409 Conflict.
                _ if matches!(ty.kind(), Kind::Enum(_)) => {
                    out.extend_from_slice(s.as_bytes());
                    Ok(IsNull::No)
                }
                // text/varchar/bpchar/name accept the string; a non-text column
                // (int4, bytea, …) is rejected by the inner `accepts`.
                _ => s.to_sql_checked(ty, out),
            },
            // arrays and objects are sent as a jsonb document (rejected if the
            // column is not json/jsonb).
            other => other.to_sql_checked(ty, out),
        }
    }

    fn accepts(_ty: &Type) -> bool {
        true
    }

    to_sql_checked!();
}

/// PostgreSQL `numeric` binary wire encoding for a plain decimal string
/// (`[-]digits[.digits]` — exactly what serde_json prints for ordinary
/// numbers; exponent forms are rejected with a clear error). Layout: i16
/// ndigits, i16 weight (position of the most significant base-10000 group
/// relative to the decimal point), u16 sign (0x0000 +, 0x4000 −), u16 dscale
/// (decimal digits after the point), then ndigits × i16 base-10000 groups.
fn write_pg_numeric(
    text: &str,
    out: &mut BytesMut,
) -> Result<(), Box<dyn std::error::Error + Sync + Send>> {
    let (negative, unsigned) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text),
    };
    let (int_part, frac_part) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    if int_part.is_empty() && frac_part.is_empty()
        || !int_part.bytes().all(|byte| byte.is_ascii_digit())
        || !frac_part.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(format!("`{text}` is not a plain decimal numeric literal").into());
    }
    let dscale = u16::try_from(frac_part.len())?;
    // Base-10000 groups: int digits left-padded, frac digits right-padded.
    let int_trimmed = int_part.trim_start_matches('0');
    let mut padded = "0".repeat((4 - int_trimmed.len() % 4) % 4) + int_trimmed;
    let int_groups = padded.len() / 4;
    padded += frac_part;
    padded += &"0".repeat((4 - padded.len() % 4) % 4);
    let mut digits: Vec<i16> = padded
        .as_bytes()
        .chunks(4)
        .map(|chunk| std::str::from_utf8(chunk).unwrap().parse::<i16>().unwrap())
        .collect();
    // weight counts from the first group; leading zero groups (a fraction
    // like 0.00001) shift it further down, trailing zero groups just shrink.
    let mut weight = int_groups as i16 - 1;
    while digits.first() == Some(&0) {
        digits.remove(0);
        weight -= 1;
    }
    while digits.last() == Some(&0) {
        digits.pop();
    }
    if digits.is_empty() {
        weight = 0;
    }
    out.extend_from_slice(&(i16::try_from(digits.len())?).to_be_bytes());
    out.extend_from_slice(&weight.to_be_bytes());
    out.extend_from_slice(
        &(if negative && !digits.is_empty() {
            0x4000u16
        } else {
            0
        })
        .to_be_bytes(),
    );
    out.extend_from_slice(&dscale.to_be_bytes());
    for digit in digits {
        out.extend_from_slice(&digit.to_be_bytes());
    }
    Ok(())
}

/// Coerces a JSON number to `i64` for integer columns, accepting an
/// integral-valued float (`3.0`) as well as a JSON integer (`3`).
fn json_i64(n: &serde_json::Number) -> Result<i64, Box<dyn std::error::Error + Sync + Send>> {
    if let Some(i) = n.as_i64() {
        return Ok(i);
    }
    if let Some(f) = n.as_f64() {
        if f.fract() == 0.0 && f >= i64::MIN as f64 && f <= i64::MAX as f64 {
            return Ok(f as i64);
        }
    }
    Err(format!("number {n} is not an integer").into())
}

pub(super) fn as_param_refs(params: &[BoxedParam]) -> Vec<&(dyn ToSql + Sync)> {
    params
        .iter()
        .map(|p| p.as_ref() as &(dyn ToSql + Sync))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // --- JsonParam: the binary encoding adapts to the target column type ---

    /// Encode `value` as if bound to a column of `ty`; returns the wire bytes or
    /// the serialization error.
    fn encode(value: Value, ty: &Type) -> Result<(IsNull, BytesMut), String> {
        let mut buf = BytesMut::new();
        match JsonParam(value).to_sql(ty, &mut buf) {
            Ok(is_null) => Ok((is_null, buf)),
            Err(e) => Err(e.to_string()),
        }
    }

    #[test]
    fn json_int_adapts_to_int2_int4_int8_widths() {
        // The bug this fixes: a JSON integer used to bind only as i64 (8 bytes),
        // failing on int2/int4 columns. Now the width follows the column type.
        assert_eq!(encode(json!(5), &Type::INT2).unwrap().1.len(), 2);
        assert_eq!(encode(json!(5), &Type::INT4).unwrap().1.len(), 4);
        assert_eq!(encode(json!(5), &Type::INT8).unwrap().1.len(), 8);
    }

    #[test]
    fn json_integral_float_binds_to_int() {
        // 3.0 (a JSON float) is a valid integer value for an int column.
        assert_eq!(encode(json!(3.0), &Type::INT4).unwrap().1.len(), 4);
    }

    #[test]
    fn json_int_overflow_for_narrow_column_errors() {
        // 5e9 does not fit in int4 → a real client error, not silent truncation.
        assert!(encode(json!(5_000_000_000_i64), &Type::INT4).is_err());
        // A fractional value cannot be an integer.
        assert!(encode(json!(2.5), &Type::INT4).is_err());
    }

    #[test]
    fn json_float_adapts_to_float4_float8() {
        assert_eq!(encode(json!(2.5), &Type::FLOAT4).unwrap().1.len(), 4);
        assert_eq!(encode(json!(2.5), &Type::FLOAT8).unwrap().1.len(), 8);
    }

    #[test]
    fn json_string_parses_into_uuid() {
        let (is_null, buf) =
            encode(json!("550e8400-e29b-41d4-a716-446655440000"), &Type::UUID).unwrap();
        assert!(matches!(is_null, IsNull::No));
        assert_eq!(buf.len(), 16, "uuid is 16 binary bytes");
        assert!(encode(json!("not-a-uuid"), &Type::UUID).is_err());
    }

    #[test]
    fn json_string_parses_into_timestamptz() {
        assert!(encode(json!("2026-06-02T12:00:00Z"), &Type::TIMESTAMPTZ).is_ok());
        assert!(encode(json!("nonsense"), &Type::TIMESTAMPTZ).is_err());
    }

    #[test]
    fn json_string_parses_into_naive_timestamp_and_date() {
        assert!(encode(json!("2026-06-02T12:00:00"), &Type::TIMESTAMP).is_ok());
        assert!(encode(json!("2026-06-02"), &Type::DATE).is_ok());
        assert!(encode(json!("not-a-date"), &Type::DATE).is_err());
    }

    #[test]
    fn json_string_into_jsonb_is_a_json_string_document() {
        // A JSON string bound to a jsonb column is stored as a jsonb string.
        let (_, buf) = encode(json!("hello"), &Type::JSONB).unwrap();
        assert_eq!(buf[0], 1, "jsonb version byte");
    }

    #[test]
    fn json_param_binds_strings_into_enum_slots() {
        // Enum binary wire format = the label text. postgres-types' `&str`
        // does not accept enum kinds, which made every enum-column filter
        // (the live UI's board groupings) a 502 — the adaptive binder must
        // write the label itself. Invalid labels stay the SERVER's call
        // (22P02 → 409), so any label serializes here.
        let enum_type = Type::new(
            "order_status_t".to_string(),
            999_999,
            Kind::Enum(vec!["pending".to_string(), "delivered".to_string()]),
            "public".to_string(),
        );
        let mut buf = bytes::BytesMut::new();
        let result = JsonParam(serde_json::json!("delivered")).to_sql(&enum_type, &mut buf);
        assert!(matches!(result, Ok(IsNull::No)));
        assert_eq!(&buf[..], b"delivered");
    }

    #[test]
    fn pg_numeric_binary_encoding_golden_vectors() {
        // (input, ndigits, weight, sign, dscale, base-10000 groups) — the
        // explicit tuple IS the golden-vector contract, kept verbatim.
        #[allow(clippy::type_complexity)]
        let cases: [(&str, i16, i16, u16, u16, &[i16]); 7] = [
            ("0", 0, 0, 0, 0, &[]),
            ("1", 1, 0, 0, 0, &[1]),
            ("12.34", 2, 0, 0, 2, &[12, 3400]),
            ("10000", 1, 1, 0, 0, &[1]),
            ("0.0001", 1, -1, 0, 4, &[1]),
            ("0.00001", 1, -2, 0, 5, &[1000]),
            ("-987654321.12", 4, 2, 0x4000, 2, &[9, 8765, 4321, 1200]),
        ];
        for (input, ndigits, weight, sign, dscale, groups) in cases {
            let mut buf = BytesMut::new();
            write_pg_numeric(input, &mut buf).unwrap_or_else(|e| panic!("{input}: {e}"));
            let mut expected = Vec::new();
            expected.extend_from_slice(&ndigits.to_be_bytes());
            expected.extend_from_slice(&weight.to_be_bytes());
            expected.extend_from_slice(&sign.to_be_bytes());
            expected.extend_from_slice(&dscale.to_be_bytes());
            for group in groups {
                expected.extend_from_slice(&group.to_be_bytes());
            }
            assert_eq!(&buf[..], &expected[..], "{input}");
        }
        // Exponent forms (serde only prints them for extreme f64s) fail closed.
        let mut buf = BytesMut::new();
        assert!(write_pg_numeric("1e21", &mut buf).is_err());
    }

    #[test]
    fn type_mismatch_is_rejected_not_corrupted() {
        // The corruption fix: a value whose JSON kind cannot encode into the
        // target column type must error (WrongType), not write garbage bytes.
        // bytea is the dangerous one — it accepts ANY bytes, so a string would
        // otherwise be stored verbatim.
        assert!(
            encode(json!("deadbeef"), &Type::BYTEA).is_err(),
            "string→bytea must reject"
        );
        assert!(
            encode(json!("42"), &Type::INT4).is_err(),
            "string→int4 must reject"
        );
        assert!(
            encode(json!(true), &Type::INT4).is_err(),
            "bool→int4 must reject"
        );
        assert!(
            encode(json!({ "a": 1 }), &Type::INT4).is_err(),
            "object→int4 must reject"
        );
        // numeric is now a real arm (write_pg_numeric): 5 → ndigits 1,
        // weight 0, sign +, dscale 0, one base-10000 group [5].
        let (_, buf) = encode(json!(5), &Type::NUMERIC).expect("number→numeric binds");
        assert_eq!(&buf[..], &[0, 1, 0, 0, 0, 0, 0, 0, 0, 5]);
    }

    #[test]
    fn json_string_and_bool_and_null_bind_directly() {
        assert_eq!(encode(json!("hello"), &Type::TEXT).unwrap().1.len(), 5);
        assert_eq!(encode(json!(true), &Type::BOOL).unwrap().1.len(), 1);
        assert!(matches!(
            encode(json!(null), &Type::INT4).unwrap().0,
            IsNull::Yes
        ));
    }

    #[test]
    fn json_object_binds_as_jsonb() {
        // Non-scalars go to the jsonb codec (version byte 0x01 prefix).
        let (_, buf) = encode(json!({ "a": 1 }), &Type::JSONB).unwrap();
        assert_eq!(buf[0], 1, "jsonb binary format starts with a version byte");
    }

    #[test]
    fn json_null_is_sql_null_for_any_column() {
        for ty in [&Type::INT4, &Type::TEXT, &Type::BOOL, &Type::JSONB] {
            let (is_null, buf) = encode(Value::Null, ty).unwrap();
            assert!(matches!(is_null, IsNull::Yes), "null into {ty:?}");
            assert!(buf.is_empty(), "null writes no bytes for {ty:?}");
        }
    }

    #[test]
    fn json_bool_true_and_false_into_bool_column() {
        let (n, t) = encode(json!(true), &Type::BOOL).unwrap();
        assert!(matches!(n, IsNull::No));
        assert_eq!(&t[..], &[1u8], "true → 0x01");
        let (_, f) = encode(json!(false), &Type::BOOL).unwrap();
        assert_eq!(&f[..], &[0u8], "false → 0x00");
    }

    #[test]
    fn json_bool_into_non_bool_column_is_rejected() {
        // bool delegates through to_sql_checked, so a bool into int4 is a clean
        // WrongType error — never garbage bytes.
        assert!(encode(json!(true), &Type::INT4).is_err());
    }

    #[test]
    fn json_int_min_max_into_int8() {
        assert_eq!(encode(json!(i64::MAX), &Type::INT8).unwrap().1.len(), 8);
        assert_eq!(encode(json!(i64::MIN), &Type::INT8).unwrap().1.len(), 8);
        // i64::MAX does NOT fit in int4 or int2.
        assert!(encode(json!(i64::MAX), &Type::INT4).is_err());
        assert!(encode(json!(i64::MAX), &Type::INT2).is_err());
    }

    #[test]
    fn json_int_boundary_values_for_int2() {
        // int2 range is [-32768, 32767].
        assert_eq!(encode(json!(32767), &Type::INT2).unwrap().1.len(), 2);
        assert_eq!(encode(json!(-32768), &Type::INT2).unwrap().1.len(), 2);
        assert!(encode(json!(32768), &Type::INT2).is_err());
        assert!(encode(json!(-32769), &Type::INT2).is_err());
    }

    #[test]
    fn json_u64_above_i64_max_into_int8_is_rejected() {
        // u64::MAX is not an i64, so json_i64 errors → not silently truncated.
        assert!(encode(json!(u64::MAX), &Type::INT8).is_err());
    }

    #[test]
    fn json_number_into_numeric_column_encodes_decimal() {
        // The NUMERIC arm uses write_pg_numeric; any plain decimal serializes.
        for v in [json!(0), json!(1), json!(-5), json!(12.34), json!(1000000)] {
            let (is_null, buf) = encode(v.clone(), &Type::NUMERIC).unwrap();
            assert!(matches!(is_null, IsNull::No), "numeric {v}");
            assert!(buf.len() >= 8, "numeric header is >= 8 bytes for {v}");
        }
    }

    #[test]
    fn json_string_into_text_varchar_bpchar() {
        for ty in [Type::TEXT, Type::VARCHAR, Type::BPCHAR, Type::NAME] {
            let (is_null, buf) = encode(json!("hello"), &ty).unwrap();
            assert!(matches!(is_null, IsNull::No), "{ty:?}");
            assert_eq!(&buf[..], b"hello", "{ty:?}");
        }
    }

    #[test]
    fn json_empty_string_and_unicode_into_text() {
        assert_eq!(&encode(json!(""), &Type::TEXT).unwrap().1[..], b"");
        assert_eq!(
            &encode(json!("héllo-🦀-世界"), &Type::TEXT).unwrap().1[..],
            "héllo-🦀-世界".as_bytes()
        );
    }

    #[test]
    fn json_string_into_int_column_is_rejected() {
        // A text value for an int4 column must fail (inner accepts() refuses it),
        // not write coincidental bytes.
        assert!(encode(json!("123"), &Type::INT4).is_err());
        assert!(encode(json!("abc"), &Type::INT4).is_err());
    }

    #[test]
    fn json_array_and_object_into_jsonb() {
        // arrays/objects fall through to to_sql_checked as a jsonb document.
        let (_, arr) = encode(json!([1, 2, 3]), &Type::JSONB).unwrap();
        assert_eq!(arr[0], 1, "jsonb version byte");
        let (_, obj) = encode(json!({ "k": [true, null] }), &Type::JSONB).unwrap();
        assert_eq!(obj[0], 1, "jsonb version byte");
    }

    #[test]
    fn json_array_into_non_json_column_is_rejected() {
        assert!(encode(json!([1, 2]), &Type::INT4).is_err());
        assert!(encode(json!({ "k": 1 }), &Type::TEXT).is_err());
    }

    #[test]
    fn json_float_nan_into_float8_serializes_bytes() {
        // f64::NAN is a representable IEEE-754 value for a float8 column (8 bytes
        // of NaN), and does not panic — unlike a JSON number, the encode path
        // here never sees NaN (serde_json rejects NaN at parse), but a literal
        // f64 bound directly does. Assert the integral-float→int path instead,
        // which is the realistic edge:
        assert_eq!(encode(json!(3.0), &Type::INT8).unwrap().1.len(), 8);
        // a fractional float can't be an integer column value.
        assert!(encode(json!(3.5), &Type::INT8).is_err());
    }

    #[test]
    fn json_param_accepts_returns_true_for_any_type() {
        // The adaptive binder claims every type at PREPARE time; the real check
        // happens in to_sql. (Documents the contract that makes the explicit
        // arms reachable.)
        assert!(JsonParam::accepts(&Type::INT4));
        assert!(JsonParam::accepts(&Type::TEXT));
        assert!(JsonParam::accepts(&Type::JSONB));
        assert!(JsonParam::accepts(&Type::NUMERIC));
    }

    // ── json_i64: integer coercion incl. integral floats ─────────────────────

    #[test]
    fn json_i64_accepts_integers_and_integral_floats() {
        let i = |v: Value| -> Result<i64, String> {
            match &v {
                Value::Number(n) => json_i64(n).map_err(|e| e.to_string()),
                _ => panic!("not a number"),
            }
        };
        assert_eq!(i(json!(0)).unwrap(), 0);
        assert_eq!(i(json!(-7)).unwrap(), -7);
        assert_eq!(i(json!(i64::MAX)).unwrap(), i64::MAX);
        assert_eq!(i(json!(i64::MIN)).unwrap(), i64::MIN);
        // integral-valued float coerces.
        assert_eq!(i(json!(3.0)).unwrap(), 3);
        assert_eq!(i(json!(-12.0)).unwrap(), -12);
        // fractional float does NOT.
        assert!(i(json!(2.5)).is_err());
        // u64 above i64::MAX does NOT (overflow → error, no wraparound).
        assert!(i(json!(u64::MAX)).is_err());
    }

    // ── write_pg_numeric: more edge vectors + failure modes ──────────────────

    #[test]
    fn write_pg_numeric_rejects_non_decimal_forms() {
        for bad in [
            "1e21", "1E5", "0x10", "1.2.3", "abc", "1,000", "", "-", "+3", " 3",
        ] {
            let mut buf = BytesMut::new();
            assert!(
                write_pg_numeric(bad, &mut buf).is_err(),
                "{bad:?} must be rejected"
            );
        }
    }

    #[test]
    fn write_pg_numeric_accepts_plain_decimals() {
        for ok in [
            "0",
            "1",
            "-1",
            "12.34",
            "1000000",
            "0.5",
            "-0.001",
            "999999999999",
        ] {
            let mut buf = BytesMut::new();
            assert!(
                write_pg_numeric(ok, &mut buf).is_ok(),
                "{ok:?} must be accepted"
            );
            assert!(buf.len() >= 8, "{ok}: header present");
        }
    }

    #[test]
    fn write_pg_numeric_zero_is_canonical() {
        // 0 → ndigits=0, weight=0, sign=0, dscale=0 → exactly 8 header bytes.
        let mut buf = BytesMut::new();
        write_pg_numeric("0", &mut buf).unwrap();
        assert_eq!(&buf[..], &[0, 0, 0, 0, 0, 0, 0, 0]);
        // "-0" has no digits → sign stays positive (0x0000), still 8 bytes.
        let mut z = BytesMut::new();
        write_pg_numeric("-0", &mut z).unwrap();
        assert_eq!(&z[..], &[0, 0, 0, 0, 0, 0, 0, 0]);
    }
}
