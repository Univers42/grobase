/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   cell.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/29 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Postgres → JSON decoding for one cell of a raw (`execute_raw`) read.
//!
//! CRUD reads come back as `to_jsonb(t)`, but a raw statement's columns
//! arrive in the binary protocol with their own types. Decoding them as
//! `serde_json::Value` only accepts json/jsonb, and the old
//! `unwrap_or(Value::Null)` turned every other column into a silent null.
//! `JsonCell` decodes by type and renders values the way `to_jsonb` does,
//! so a raw read and a CRUD read of the same row agree. A type without a
//! decoder is an error that names the remedy, never a null.

use chrono::{DateTime, NaiveDate, NaiveDateTime, Utc};
use serde_json::Value;
use std::error::Error;
use std::fmt::Write as _;
use tokio_postgres::types::{FromSql, Kind, Type};

type DecodeError = Box<dyn Error + Sync + Send>;

/// One decoded cell. Accepts every type so the row read never fails on
/// type-checking; unsupported types fail in `from_sql` with a clear message.
pub(super) struct JsonCell(pub(super) Value);

impl<'a> FromSql<'a> for JsonCell {
    fn from_sql(ty: &Type, raw: &'a [u8]) -> Result<Self, DecodeError> {
        decode(ty, raw).map(JsonCell)
    }

    fn from_sql_null(_: &Type) -> Result<Self, DecodeError> {
        Ok(JsonCell(Value::Null))
    }

    fn accepts(_: &Type) -> bool {
        true
    }
}

fn decode(ty: &Type, raw: &[u8]) -> Result<Value, DecodeError> {
    // An enum's binary form is its label.
    if let Kind::Enum(_) = ty.kind() {
        return text(raw);
    }
    Ok(match *ty {
        Type::BOOL => Value::Bool(bool::from_sql(ty, raw)?),
        Type::INT2 => i16::from_sql(ty, raw)?.into(),
        Type::INT4 => i32::from_sql(ty, raw)?.into(),
        Type::INT8 => i64::from_sql(ty, raw)?.into(),
        Type::OID => u32::from_sql(ty, raw)?.into(),
        Type::FLOAT4 => float(f64::from(f32::from_sql(ty, raw)?)),
        Type::FLOAT8 => float(f64::from_sql(ty, raw)?),
        Type::NUMERIC => {
            let digits = numeric_text(raw)?;
            serde_json::from_str(&digits).unwrap_or(Value::String(digits))
        }
        Type::TEXT | Type::VARCHAR | Type::BPCHAR | Type::NAME | Type::UNKNOWN => text(raw)?,
        Type::UUID => Value::String(uuid::Uuid::from_sql(ty, raw)?.to_string()),
        Type::JSON | Type::JSONB => Value::from_sql(ty, raw)?,
        Type::DATE => Value::String(NaiveDate::from_sql(ty, raw)?.to_string()),
        Type::TIMESTAMP => Value::String(iso(NaiveDateTime::from_sql(ty, raw)?)),
        Type::TIMESTAMPTZ => {
            Value::String(iso(DateTime::<Utc>::from_sql(ty, raw)?.naive_utc()) + "+00:00")
        }
        Type::BYTEA => Value::String(raw.iter().fold(String::from("\\x"), |mut hex, byte| {
            let _ = write!(hex, "{byte:02x}");
            hex
        })),
        _ => return Err(no_decoder(ty)),
    })
}

fn no_decoder(ty: &Type) -> DecodeError {
    let name = ty.name();
    format!("type `{name}` has no raw-read decoder; cast it with `::text` or `to_jsonb(...)`")
        .into()
}

fn text(raw: &[u8]) -> Result<Value, DecodeError> {
    Ok(Value::String(std::str::from_utf8(raw)?.to_owned()))
}

/// `to_jsonb` renders non-finite floats as the strings `NaN`/`Infinity`.
fn float(value: f64) -> Value {
    serde_json::Number::from_f64(value).map_or_else(
        || {
            Value::String(
                match value {
                    v if v.is_nan() => "NaN",
                    v if v > 0.0 => "Infinity",
                    _ => "-Infinity",
                }
                .into(),
            )
        },
        Value::Number,
    )
}

/// ISO 8601 with Postgres's fraction: microseconds, trailing zeros dropped.
/// A timestamptz is rendered in UTC; `to_jsonb` uses the session TimeZone,
/// so the offset can differ while the instant is the same.
fn iso(at: NaiveDateTime) -> String {
    let full = at.format("%Y-%m-%dT%H:%M:%S%.6f").to_string();
    full.trim_end_matches('0').trim_end_matches('.').to_owned()
}

/// Binary `numeric` → plain decimal text (`[-]int[.frac]`, `dscale` fraction
/// digits), or `NaN`/`Infinity`/`-Infinity`. Layout mirrors
/// `convert::write_pg_numeric`: ndigits, weight, sign, dscale, then base-10000
/// groups where group `i` carries the exponent `weight - i`.
fn numeric_text(raw: &[u8]) -> Result<String, DecodeError> {
    let word = |index: usize| -> Result<u16, DecodeError> {
        raw.get(2 * index..2 * index + 2)
            .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
            .ok_or_else(|| "truncated numeric".into())
    };
    let ndigits = usize::from(word(0)?);
    let weight = i32::from(word(1)? as i16);
    let sign = match word(2)? {
        0x0000 => "",
        0x4000 => "-",
        0xC000 => return Ok("NaN".into()),
        0xD000 => return Ok("Infinity".into()),
        0xF000 => return Ok("-Infinity".into()),
        other => return Err(format!("unknown numeric sign {other:#06x}").into()),
    };
    let dscale = usize::from(word(3)?);
    let groups = (0..ndigits)
        .map(|index| word(4 + index))
        .collect::<Result<Vec<u16>, _>>()?;
    let group = |index: i32| {
        usize::try_from(index)
            .ok()
            .and_then(|i| groups.get(i))
            .copied()
            .unwrap_or(0)
    };
    let mut out = String::from(sign);
    if weight < 0 {
        out.push('0');
    }
    for index in 0..=weight {
        if index == 0 {
            let _ = write!(out, "{}", group(index));
        } else {
            let _ = write!(out, "{:04}", group(index));
        }
    }
    if dscale > 0 {
        let mut fraction = String::with_capacity(dscale + 4);
        let mut index = weight + 1;
        while fraction.len() < dscale {
            let _ = write!(fraction, "{:04}", group(index));
            index += 1;
        }
        fraction.truncate(dscale);
        out.push('.');
        out.push_str(&fraction);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::BytesMut;
    use serde_json::json;

    fn cell(ty: &Type, raw: &[u8]) -> Result<Value, DecodeError> {
        JsonCell::from_sql(ty, raw).map(|cell| cell.0)
    }

    #[test]
    fn accepts_every_type_and_null_is_null() {
        assert!(JsonCell::accepts(&Type::INTERVAL));
        assert_eq!(JsonCell::from_sql_null(&Type::INT4).unwrap().0, Value::Null);
    }

    #[test]
    fn scalars_decode_to_their_json_value() {
        assert_eq!(cell(&Type::BOOL, &[1]).unwrap(), json!(true));
        assert_eq!(cell(&Type::INT2, &7i16.to_be_bytes()).unwrap(), json!(7));
        assert_eq!(
            cell(&Type::INT4, &(-5i32).to_be_bytes()).unwrap(),
            json!(-5)
        );
        assert_eq!(
            cell(&Type::INT8, &i64::MAX.to_be_bytes()).unwrap(),
            json!(i64::MAX)
        );
        assert_eq!(
            cell(&Type::FLOAT8, &1.5f64.to_be_bytes()).unwrap(),
            json!(1.5)
        );
        assert_eq!(
            cell(&Type::FLOAT8, &f64::NAN.to_be_bytes()).unwrap(),
            json!("NaN")
        );
        assert_eq!(
            cell(&Type::FLOAT4, &f32::NEG_INFINITY.to_be_bytes()).unwrap(),
            json!("-Infinity")
        );
        assert_eq!(cell(&Type::TEXT, "hé".as_bytes()).unwrap(), json!("hé"));
        assert_eq!(
            cell(&Type::BYTEA, &[0xde, 0xad, 0x00]).unwrap(),
            json!("\\xdead00")
        );
        assert_eq!(
            cell(&Type::JSONB, b"\x01{\"a\":1}").unwrap(),
            json!({"a": 1})
        );
        let id = uuid::Uuid::from_u128(0x0123_4567_89ab_cdef_0123_4567_89ab_cdef);
        assert_eq!(
            cell(&Type::UUID, id.as_bytes()).unwrap(),
            json!(id.to_string())
        );
    }

    #[test]
    fn dates_and_timestamps_render_like_to_jsonb() {
        // Postgres epochs are 2000-01-01: days for date, microseconds for timestamps.
        assert_eq!(
            cell(&Type::DATE, &1i32.to_be_bytes()).unwrap(),
            json!("2000-01-02")
        );
        let micros = 90_061_500_000i64; // 1 day 01:01:01.5
        assert_eq!(
            cell(&Type::TIMESTAMP, &micros.to_be_bytes()).unwrap(),
            json!("2000-01-02T01:01:01.5")
        );
        assert_eq!(
            cell(&Type::TIMESTAMPTZ, &0i64.to_be_bytes()).unwrap(),
            json!("2000-01-01T00:00:00+00:00")
        );
    }

    #[test]
    fn enum_labels_decode_as_text() {
        let mood = Type::new(
            "mood".into(),
            90_001,
            Kind::Enum(vec!["ok".into()]),
            "public".into(),
        );
        assert_eq!(cell(&mood, b"ok").unwrap(), json!("ok"));
    }

    #[test]
    fn undecodable_type_is_an_error_naming_the_cast() {
        let err = cell(&Type::INTERVAL, &[0; 16]).unwrap_err().to_string();
        assert!(err.contains("interval") && err.contains("::text"), "{err}");
    }

    #[test]
    fn numeric_round_trips_through_the_encoder() {
        for literal in [
            "0",
            "1.50",
            "-12345.6789",
            "0.00001",
            "10000",
            "123456789012",
            "-0.5",
        ] {
            let mut wire = BytesMut::new();
            super::super::convert::write_pg_numeric(literal, &mut wire).unwrap();
            assert_eq!(numeric_text(&wire).unwrap(), literal, "{literal}");
        }
        assert_eq!(
            cell(&Type::NUMERIC, &[0, 0, 0, 0, 0xC0, 0, 0, 0]).unwrap(),
            json!("NaN")
        );
        assert!(numeric_text(&[0, 1]).is_err(), "truncated header");
    }
}
