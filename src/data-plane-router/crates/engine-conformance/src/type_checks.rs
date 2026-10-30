//! Typed-value round trip for [`crate::run_suite`]: one column per creatable
//! normalized type is added through structured DDL, filled with one canonical
//! value, then read back through `list` and `describe`. A cell passes when the
//! value survives and the described type is the one created. Known engine gaps
//! sit in a ledger; a gap that starts passing fails too, so the ledger cannot
//! outlive the gap. The HTTP twin is scripts/verify/m249-type-round-trip.mjs.
//!
//! Caveat: it compares the pool's JSON round trip, not the stored bytes — a
//! binary value an engine keeps as its hex text reads back identically and
//! passes. A datetime read back with a non-UTC offset is reported as a FAIL
//! even when it is the same instant.

use data_plane_core::{
    DataOperationKind, EnginePool, NormalizedType, RawStatement, RequestIdentity, SchemaDdlOp,
};
use serde_json::{json, Value};

use crate::schema_checks::{apply, column, ddl_on, describe};
use crate::{num, op};

const TYPE_TABLE: &str = "conf_types";

type Check = fn(&Value) -> bool;

/// (column, created type, written value, read-back check). Bigint is probed at
/// 2^53-1 because reads past 2^53 still travel as JSON numbers.
fn cases() -> Vec<(&'static str, NormalizedType, Value, Check)> {
    use NormalizedType as T;
    vec![
        ("c_text", T::Text, json!("héllo ✓"), |v| v == "héllo ✓"),
        ("c_int", T::Integer, json!(42), |v| as_f64(v) == Some(42.0)),
        ("c_big", T::Bigint, json!("9007199254740991"), |v| {
            plain(v) == "9007199254740991"
        }),
        ("c_float", T::Float, json!(1.5), |v| as_f64(v) == Some(1.5)),
        ("c_dec", T::Decimal, json!("12.50"), |v| {
            as_f64(v) == Some(12.5)
        }),
        ("c_bool", T::Boolean, json!(true), |v| v == true || v == 1),
        ("c_date", T::Date, json!("2026-10-29"), |v| {
            plain(v).starts_with("2026-10-29")
        }),
        ("c_ts", T::Datetime, json!("2026-10-29T12:34:56Z"), |v| {
            is_utc_instant(&plain(v), "2026-10-29T12:34:56")
        }),
        ("c_json", T::Json, json!({ "k": [1, "a"] }), |v| {
            parsed_json(v) == json!({ "k": [1, "a"] })
        }),
        ("c_uuid", T::Uuid, json!(UUID), |v| {
            plain(v).to_lowercase() == UUID
        }),
        ("c_bin", T::Binary, json!("\\xdead00ff"), |v| {
            plain(v).to_lowercase() == "\\xdead00ff"
        }),
        ("c_time", T::Time, json!("12:30:00"), |v| {
            plain(v).contains("12:30:00")
        }),
    ]
}

const UUID: &str = "6f1c2d3e-4a5b-4c6d-8e7f-001122334455";

fn as_f64(v: &Value) -> Option<f64> {
    num(&json!({ "v": v }), "v")
}

fn plain(v: &Value) -> String {
    v.as_str().map_or_else(|| v.to_string(), str::to_string)
}

fn parsed_json(v: &Value) -> Value {
    v.as_str()
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_else(|| v.clone())
}

/// `text` names `want` (seconds precision, no zone) in UTC: MySQL and MSSQL
/// return `2026-10-29 12:34:56` with no zone, and the router writes UTC.
fn is_utc_instant(text: &str, want: &str) -> bool {
    let iso = text.replacen(' ', "T", 1);
    let Some(rest) = iso.strip_prefix(want) else {
        return false;
    };
    let rest = rest.trim_start_matches('.').trim_start_matches('0');
    matches!(rest, "" | "Z" | "+00:00" | "+0000" | "+00")
}

const INT_AS_BIGINT: &str = "integer is created as a 64-bit column and described as bigint";
const SQLITE_AFFINITY: &str =
    "SQLite stores it under a type affinity, so the described type is the affinity";
const MARIADB_TS: &str =
    "the datetime bind is type-blind: an RFC 3339 string is refused (ERROR 1292)";

/// engine (or server flavour) → column → reason. Each entry is an open item
/// in wiki/architecture/multidb-holistic.md (G7).
fn gaps(flavour: &str) -> &'static [(&'static str, &'static str)] {
    match flavour {
        "postgresql" | "cockroachdb" => &[("c_int", INT_AS_BIGINT)],
        "mariadb" => &[
            ("c_int", INT_AS_BIGINT),
            ("c_ts", MARIADB_TS),
            (
                "c_json",
                "MariaDB JSON is an alias of LONGTEXT, described as text",
            ),
            ("c_uuid", "created as CHAR(36), described as text"),
        ],
        "mongodb" => &[
            ("c_int", INT_AS_BIGINT),
            (
                "c_date",
                "BSON has no date-only type, stored as a midnight-UTC Date",
            ),
            ("c_uuid", "stored as a string field, described as text"),
            (
                "c_time",
                "BSON has no time type, stored and described as text",
            ),
        ],
        "sqlite" => &[
            ("c_big", SQLITE_AFFINITY),
            ("c_bool", SQLITE_AFFINITY),
            ("c_date", SQLITE_AFFINITY),
            ("c_ts", SQLITE_AFFINITY),
            ("c_json", SQLITE_AFFINITY),
            ("c_uuid", SQLITE_AFFINITY),
            ("c_time", SQLITE_AFFINITY),
        ],
        _ => &[],
    }
}

/// Outcome of the round trip: hard failures, and ledger gaps still open.
#[derive(Debug, Default)]
pub(crate) struct TypeReport {
    pub(crate) failures: Vec<String>,
    pub(crate) gaps: Vec<(String, &'static str)>,
}

impl TypeReport {
    /// Files one cell against the ledger: a listed gap that fails is a gap, a
    /// listed gap that passes is a failure (remove the entry).
    fn judge(&mut self, flavour: &str, name: &str, outcome: Result<(), String>) {
        let gap = gaps(flavour).iter().find(|(c, _)| *c == name).map(|g| g.1);
        match (gap, outcome) {
            (Some(reason), Err(_)) => self.gaps.push((name.to_string(), reason)),
            (Some(reason), Ok(())) => self.failures.push(format!(
                "{name}: now passes — remove the {flavour} gap ({reason})"
            )),
            (None, Err(e)) => self.failures.push(format!("{name}: {e}")),
            (None, Ok(())) => {}
        }
    }
}

/// The engine id, except `mysql`, which names the server it actually runs:
/// the `mysql` service is MariaDB, and Oracle MySQL 8 has its own gaps.
async fn flavour(pool: &dyn EnginePool, id: &RequestIdentity, engine: &str) -> String {
    if engine != "mysql" {
        return engine.to_string();
    }
    let probe = RawStatement {
        statement: "SELECT VERSION() AS v".to_string(),
        params: vec![],
        expect_rows: true,
    };
    match pool.execute_raw(probe, id.clone()).await {
        Ok(r) if format!("{:?}", r.rows).contains("MariaDB") => "mariadb".into(),
        _ => "mysql".into(),
    }
}

pub(crate) async fn check_type_round_trip(
    pool: &dyn EnginePool,
    id: &RequestIdentity,
    engine: &str,
) -> TypeReport {
    let flavour = flavour(pool, id, engine).await;
    let mut report = TypeReport::default();
    let _ = apply(pool, id, ddl_on(TYPE_TABLE, SchemaDdlOp::DropTable)).await;
    let mut create = ddl_on(TYPE_TABLE, SchemaDdlOp::CreateTable);
    let mut id_column = column("id", NormalizedType::Integer);
    id_column.nullable = false;
    create.columns = Some(vec![id_column]);
    create.primary_key = Some(vec!["id".to_string()]);
    if let Err(e) = apply(pool, id, create).await {
        report.failures.push(format!("create {TYPE_TABLE}: {e}"));
        return report;
    }
    for (row, (name, kind, value, check)) in cases().into_iter().enumerate() {
        let outcome = probe_cell(pool, id, row + 1, (name, kind, value, check)).await;
        report.judge(&flavour, name, outcome);
    }
    let _ = apply(pool, id, ddl_on(TYPE_TABLE, SchemaDdlOp::DropTable)).await;
    report
}

/// One column added and filled alone, so one refused type cannot hide the
/// others. Each row carries its own id: SQL engines would generate it, but a
/// Mongo validator only requires it.
async fn probe_cell(
    pool: &dyn EnginePool,
    id: &RequestIdentity,
    row: usize,
    (name, kind, value, check): (&str, NormalizedType, Value, Check),
) -> Result<(), String> {
    let mut add = ddl_on(TYPE_TABLE, SchemaDdlOp::AddColumn);
    add.column = Some(column(name, kind));
    apply(pool, id, add).await?;
    let mut insert = op(DataOperationKind::Insert, Value::Null);
    insert.resource = TYPE_TABLE.to_string();
    insert.filter = None;
    insert.data = Some(json!({ "id": row, name: value }));
    pool.execute(insert, id.clone())
        .await
        .map_err(|e| format!("insert: {e}"))?;
    let got = read_back(pool, id, name).await?;
    let described = described_type(pool, id, name).await?;
    if described == Some(kind) && got.as_ref().is_some_and(check) {
        return Ok(());
    }
    Err(format!("described {described:?}, read {got:?}"))
}

async fn read_back(
    pool: &dyn EnginePool,
    id: &RequestIdentity,
    name: &str,
) -> Result<Option<Value>, String> {
    let mut list = op(DataOperationKind::List, Value::Null);
    list.resource = TYPE_TABLE.to_string();
    list.filter = None;
    list.limit = Some(50);
    let rows = pool
        .execute(list, id.clone())
        .await
        .map_err(|e| format!("list: {e}"))?
        .rows;
    Ok(rows
        .into_iter()
        .filter_map(|r| r.get(name).cloned())
        .find(|v| !v.is_null()))
}

async fn described_type(
    pool: &dyn EnginePool,
    id: &RequestIdentity,
    name: &str,
) -> Result<Option<NormalizedType>, String> {
    Ok(describe(pool, id)
        .await?
        .tables
        .into_iter()
        .find(|t| t.name == TYPE_TABLE)
        .and_then(|t| t.columns.into_iter().find(|c| c.name == name))
        .map(|c| c.normalized_type))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_gap_that_passes_fails_and_a_failing_gap_is_listed() {
        let mut r = TypeReport::default();
        r.judge("postgresql", "c_int", Ok(()));
        r.judge("postgresql", "c_int", Err("described Some(Bigint)".into()));
        r.judge("postgresql", "c_text", Err("read None".into()));
        r.judge("postgresql", "c_float", Ok(()));
        assert_eq!(r.gaps.len(), 1);
        assert_eq!(r.failures.len(), 2);
        assert!(r.failures[0].contains("now passes"));
    }

    #[test]
    fn every_case_accepts_its_own_written_value() {
        for (name, _, value, check) in cases() {
            assert!(check(&value), "{name} rejects {value}");
        }
    }

    #[test]
    fn utc_instant_accepts_zone_spellings_and_rejects_offsets() {
        let want = "2026-10-29T12:34:56";
        for ok in [
            "2026-10-29 12:34:56",
            "2026-10-29T12:34:56Z",
            "2026-10-29T12:34:56.000+00:00",
        ] {
            assert!(is_utc_instant(ok, want), "{ok}");
        }
        for bad in ["2026-10-29T12:34:56+02:00", "2026-10-29T12:34:57Z"] {
            assert!(!is_utc_instant(bad, want), "{bad}");
        }
    }

    #[test]
    fn every_gap_names_a_real_case() {
        let names: Vec<_> = cases().into_iter().map(|c| c.0).collect();
        for flavour in ["postgresql", "cockroachdb", "mariadb", "mongodb", "sqlite"] {
            for (column, _) in gaps(flavour) {
                assert!(names.contains(column), "{flavour}: {column}");
            }
        }
    }
}
