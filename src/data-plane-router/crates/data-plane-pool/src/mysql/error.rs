//! Backend-error classification: map server messages to the right
//! `DataPlaneError` (client 4xx vs engine 5xx), split by query vs DDL path.

use super::*;

pub(super) fn backend<E: std::fmt::Display>(e: E) -> DataPlaneError {
    classify_mysql_error(format!("mysql backend: {e}"), false)
}

/// DDL-path variant of [`backend`]: additionally maps the "existing data is
/// incompatible with the new type" server errors raised by `MODIFY COLUMN`
/// — 1265 "Data truncated", 1366 "Incorrect <type> value", 1292 "Truncated
/// incorrect <type> value" — to a 409 Conflict. Scoped to the DDL path only
/// (additive): the query path keeps [`backend`]'s existing mapping.
pub(super) fn ddl_backend<E: std::fmt::Display>(e: E) -> DataPlaneError {
    classify_mysql_error(format!("mysql backend: {e}"), true)
}

/// Best-effort integrity-violation detection from the server message (the
/// generic helper only has the Display text): 1062 "Duplicate entry", 1452
/// foreign-key failure → a client error (409 Conflict), not an engine 5xx.
/// Truncation/cast errors (1265/1292/1366 — bad enum value, unparseable
/// date) and 1264 "Out of range" classify as Conflict on BOTH paths: on DDL
/// they mean the table's data conflicts with the requested type, on writes
/// they mean the caller's VALUE doesn't fit the column — either way the
/// caller's fault, and a 5xx would make outbox clients retry a write that
/// can never succeed.
pub(super) fn classify_mysql_error(message: String, ddl: bool) -> DataPlaneError {
    let lower = message.to_lowercase();
    if lower.contains("duplicate entry") || lower.contains("foreign key constraint fails") {
        return DataPlaneError::Conflict { message };
    }
    if lower.contains("data truncated")
        || lower.contains("truncated incorrect")
        || lower.contains("out of range value")
        || (lower.contains("incorrect") && lower.contains("value"))
    {
        return DataPlaneError::Conflict { message };
    }
    if ddl {
        // Schema-shape mistakes are deterministic client errors — a 5xx makes
        // outbox-style clients retry a request that can never succeed.
        // 1060 "Duplicate column name" / 1050 "Table … already exists" → 409;
        // 1054 "Unknown column" / 1091 "Can't DROP …; check that column/key
        // exists" / 1146 "Table … doesn't exist" → 400.
        if lower.contains("duplicate column name") || lower.contains("already exists") {
            return DataPlaneError::Conflict { message };
        }
        if lower.contains("unknown column")
            || lower.contains("check that column/key exists")
            || lower.contains("doesn't exist")
        {
            return DataPlaneError::InvalidRequest { message };
        }
    }
    DataPlaneError::Backend { message }
}
