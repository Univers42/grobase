//! rusqlite error → client/server bucket classification (pure, message-based).

use data_plane_core::DataPlaneError;

/// DDL-shaped mistakes ("already exists", "no such table/column", "duplicate
/// column") are the CALLER's error (400), not a backend fault — mirrors the
/// MySQL adapter's `ddl_backend` classification.
pub(super) fn classify_sqlite_ddl_error(e: &rusqlite::Error) -> DataPlaneError {
    let msg = e.to_string();
    let lower = msg.to_ascii_lowercase();
    if lower.contains("already exists")
        || lower.contains("no such table")
        || lower.contains("no such column")
        || lower.contains("duplicate column")
    {
        DataPlaneError::InvalidRequest {
            message: format!("sqlite ddl: {msg}"),
        }
    } else {
        DataPlaneError::Backend {
            message: format!("sqlite ddl: {msg}"),
        }
    }
}

/// Classify a rusqlite error into the right client/server bucket: a constraint
/// violation (UNIQUE/PK/FK/NOT NULL/CHECK) is a 409 Conflict; everything else a
/// 502 Backend.
pub(super) fn backend(e: rusqlite::Error) -> DataPlaneError {
    let msg = e.to_string();
    let lower = msg.to_ascii_lowercase();
    if lower.contains("unique constraint")
        || lower.contains("constraint failed")
        || lower.contains("not null")
        || lower.contains("foreign key")
    {
        DataPlaneError::Conflict {
            message: format!("sqlite constraint: {msg}"),
        }
    } else {
        DataPlaneError::Backend {
            message: format!("sqlite backend: {msg}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── conflict classification: backend / ddl ───────────────────────────────

    #[test]
    fn backend_classifies_constraint_violations_as_conflict() {
        for msg in [
            "UNIQUE constraint failed: t.email",
            "CHECK constraint failed: t",
            "NOT NULL constraint failed: t.name",
            "FOREIGN KEY constraint failed",
        ] {
            let e = backend(rusqlite::Error::ToSqlConversionFailure(msg.into()));
            assert!(
                matches!(e, DataPlaneError::Conflict { .. }),
                "{msg:?} → {e:?}"
            );
        }
    }

    #[test]
    fn backend_classifies_generic_errors_as_backend() {
        for msg in [
            "database is locked",
            "disk I/O error",
            "no such function: foo",
        ] {
            let e = backend(rusqlite::Error::ToSqlConversionFailure(msg.into()));
            assert!(
                matches!(e, DataPlaneError::Backend { .. }),
                "{msg:?} → {e:?}"
            );
        }
    }

    #[test]
    fn backend_classification_is_case_insensitive() {
        let e = backend(rusqlite::Error::ToSqlConversionFailure(
            "UNIQUE CONSTRAINT FAILED".into(),
        ));
        assert!(matches!(e, DataPlaneError::Conflict { .. }), "{e:?}");
    }

    #[test]
    fn ddl_error_classifies_schema_shape_mistakes_as_invalid_request() {
        for msg in [
            "table \"posts\" already exists",
            "no such table: ghost",
            "no such column: missing",
            "duplicate column name: dup",
        ] {
            let e = classify_sqlite_ddl_error(&rusqlite::Error::ToSqlConversionFailure(msg.into()));
            assert!(
                matches!(e, DataPlaneError::InvalidRequest { .. }),
                "{msg:?} → {e:?}"
            );
        }
    }

    #[test]
    fn ddl_error_classifies_other_failures_as_backend() {
        let e = classify_sqlite_ddl_error(&rusqlite::Error::ToSqlConversionFailure(
            "database disk image is malformed".into(),
        ));
        assert!(matches!(e, DataPlaneError::Backend { .. }), "{e:?}");
    }
}
