//! Security: DDL contract guards. `validate_default_expr` must reject statement
//! separators, SQL comments, and control characters (a DEFAULT clause is
//! interpolated into DDL text — it cannot bind params), while accepting
//! legitimate literals and function defaults. The `require_*` helpers must
//! reject op-shape errors (missing column / unknown PK column / empty columns)
//! so a malformed request becomes a clean 400 instead of an engine 5xx.

use data_plane_core::{
    validate_default_expr, DataPlaneError, DdlColumnDef, NormalizedType, SchemaDdlOp,
    SchemaDdlRequest,
};

// ── validate_default_expr: REJECT dangerous interpolation ───────────────────

#[test]
fn default_expr_rejects_separators_comments_and_control() {
    let dangerous = [
        "0; DROP TABLE users",
        "1; DELETE FROM accounts; --",
        "'a'; SELECT pg_sleep(10)",
        "1 -- inline comment",
        "1--",
        "'x' /* block */",
        "/* leading */ 0",
        "a\nb",      // newline control
        "a\rb",      // carriage return
        "a\tb",      // tab control char
        "a\0b",      // null byte
        "1\x07bell", // bell control char
        "';--",
        "now();DROP",
        "0;;",
    ];
    for expr in dangerous {
        let err = validate_default_expr(expr).unwrap_err();
        assert!(
            matches!(err, DataPlaneError::InvalidRequest { .. }),
            "default {expr:?} must be rejected as InvalidRequest, got {err:?}"
        );
    }
}

#[test]
fn default_expr_accepts_legitimate_literals_and_functions() {
    // These are real, safe DDL defaults — the guard must NOT over-reject them.
    let safe = [
        "0",
        "1",
        "-1",
        "3.14",
        "'pending'",
        "'paid'",
        "''",
        "true",
        "false",
        "NULL",
        "now()",
        "CURRENT_TIMESTAMP",
        "gen_random_uuid()",
        "uuid_generate_v4()",
        "current_date",
        "'{}'",
        "'[]'",
        "0.0",
        "'2020-01-01'",
    ];
    for expr in safe {
        assert!(
            validate_default_expr(expr).is_ok(),
            "legitimate default {expr:?} must be accepted"
        );
    }
}

#[test]
fn default_expr_rejects_each_forbidden_token_in_isolation() {
    // Pin the exact forbidden set: ';', '--', '/*', and any control char.
    assert!(validate_default_expr("a;b").is_err(), "semicolon");
    assert!(validate_default_expr("a--b").is_err(), "double dash");
    assert!(validate_default_expr("a/*b").is_err(), "block comment open");
    for code in 0u32..0x20 {
        let c = char::from_u32(code).unwrap();
        let expr = format!("a{c}b");
        assert!(
            validate_default_expr(&expr).is_err(),
            "control char U+{code:04X} must be rejected"
        );
    }
    // A bare '-' (single dash, e.g. a negative literal) is NOT forbidden.
    assert!(
        validate_default_expr("-5").is_ok(),
        "single dash is allowed"
    );
    // A bare '/' (not '/*') is NOT forbidden.
    assert!(
        validate_default_expr("1/2").is_ok(),
        "lone slash is allowed"
    );
}

// ── require_* op-shape validation: malformed requests → clean 400 ───────────

fn col(name: &str) -> DdlColumnDef {
    DdlColumnDef {
        name: name.into(),
        normalized_type: NormalizedType::Integer,
        nullable: false,
        default: None,
        enum_values: None,
    }
}

fn req(op: SchemaDdlOp) -> SchemaDdlRequest {
    SchemaDdlRequest {
        op,
        table: "t".into(),
        column: None,
        column_name: None,
        columns: None,
        primary_key: None,
    }
}

#[test]
fn add_column_requires_a_column_def() {
    let err = req(SchemaDdlOp::AddColumn).require_column().unwrap_err();
    assert!(matches!(err, DataPlaneError::InvalidRequest { .. }));
    let mut r = req(SchemaDdlOp::AddColumn);
    r.column = Some(col("status"));
    assert!(r.require_column().is_ok());
}

#[test]
fn drop_column_requires_a_non_empty_name() {
    for name in [None, Some(""), Some("   "), Some("\t")] {
        let mut r = req(SchemaDdlOp::DropColumn);
        r.column_name = name.map(str::to_string);
        assert!(
            r.require_column_name().is_err(),
            "drop_column with name {name:?} must be rejected"
        );
    }
    let mut r = req(SchemaDdlOp::DropColumn);
    r.column_name = Some("status".into());
    assert_eq!(r.require_column_name().unwrap(), "status");
}

#[test]
fn create_table_requires_non_empty_columns_and_pk() {
    // No columns → reject.
    let mut r = req(SchemaDdlOp::CreateTable);
    assert!(r.require_create_spec().is_err(), "no columns");
    r.columns = Some(vec![]);
    assert!(r.require_create_spec().is_err(), "empty columns");
    // Columns but no PK → reject.
    r.columns = Some(vec![col("id"), col("title")]);
    assert!(r.require_create_spec().is_err(), "no primary_key");
    r.primary_key = Some(vec![]);
    assert!(r.require_create_spec().is_err(), "empty primary_key");
}

#[test]
fn create_table_rejects_pk_referencing_unknown_column() {
    let mut r = req(SchemaDdlOp::CreateTable);
    r.columns = Some(vec![col("id"), col("title")]);
    // A PK column that isn't declared (and isn't owner_id) → reject (catches typos).
    for bad_pk in ["nope", "ID", "id ", "title;", "'; DROP"] {
        r.primary_key = Some(vec![bad_pk.into()]);
        let err = r.require_create_spec().unwrap_err();
        assert!(
            matches!(err, DataPlaneError::InvalidRequest { .. }),
            "PK {bad_pk:?} not in columns must be rejected"
        );
    }
    // A declared column is a valid PK.
    r.primary_key = Some(vec!["id".into()]);
    assert!(r.require_create_spec().is_ok());
    // owner_id is always a legal PK (engines auto-append it).
    r.primary_key = Some(vec!["owner_id".into()]);
    assert!(r.require_create_spec().is_ok());
    // Composite PK where every column is declared.
    r.primary_key = Some(vec!["id".into(), "title".into(), "owner_id".into()]);
    assert!(r.require_create_spec().is_ok());
}

#[test]
fn op_as_str_is_the_stable_wire_name() {
    assert_eq!(SchemaDdlOp::AddColumn.as_str(), "add_column");
    assert_eq!(SchemaDdlOp::DropColumn.as_str(), "drop_column");
    assert_eq!(SchemaDdlOp::AlterColumnType.as_str(), "alter_column_type");
    assert_eq!(SchemaDdlOp::CreateTable.as_str(), "create_table");
    assert_eq!(SchemaDdlOp::DropTable.as_str(), "drop_table");
}

#[test]
fn ddl_request_serde_round_trip_preserves_op_shape() {
    // A malicious-looking default inside a column survives the wire round-trip
    // as DATA (it is the validate_default_expr guard, not serde, that rejects it).
    let wire = serde_json::json!({
        "op": "add_column",
        "table": "orders",
        "column": {
            "name": "status",
            "normalized_type": "enum",
            "nullable": false,
            "default": "'pending'",
            "enum_values": ["pending", "paid"]
        },
        "column_name": null,
        "columns": null,
        "primary_key": null
    });
    let parsed: SchemaDdlRequest = serde_json::from_value(wire.clone()).unwrap();
    assert_eq!(parsed.op, SchemaDdlOp::AddColumn);
    assert_eq!(serde_json::to_value(&parsed).unwrap(), wire);
}
