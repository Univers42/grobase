//! Security: the engine-neutral filter parser must reject malformed / unknown
//! grammar and must treat SQL-looking strings as DATA (never operators). Values
//! that look like injection ("1 OR 1=1", "'; DROP TABLE--", "$ne", "../../etc")
//! are accepted as scalar VALUES and remain inside the `Filter` tree as
//! `serde_json::Value` (parameterized downstream), never promoted to operators
//! or field names.

use data_plane_core::{CmpOp, Filter, Folded};
use serde_json::{json, Value};

// ── (a) malicious/weird input is REJECTED at the grammar layer ──────────────

#[test]
fn unknown_operators_are_rejected() {
    // Anything starting with `$` that is not in the allowlist is a 400.
    let bad_ops = [
        "$where",
        "$expr",
        "$regex",
        "$jsonSchema",
        "$function",
        "$accumulator",
        "$drop",
        "$exec",
        "$elemMatch",
        "$text",
        "$comment",
        "$EQ",
        "$Eq",
        "$ eq",
        "$in ",
        "$lte;",
        "$$",
        "$",
        "$1",
        "$nin",
        "$mod",
        "$type",
    ];
    for op in bad_ops {
        let v = json!({ "col": { op: 1 } });
        assert!(
            Filter::parse(&v).is_err(),
            "operator {op:?} must be rejected as unknown"
        );
    }
}

#[test]
fn dollar_prefixed_field_names_are_rejected() {
    // A top-level `$`-key that is not a known boolean combinator is rejected:
    // it can be neither a field (fields may not start with `$`) nor an operator.
    for key in ["$where", "$comment", "$func", "$evil", "$", "$1", "$_"] {
        let v = json!({ key: "x" });
        assert!(
            Filter::parse(&v).is_err(),
            "top-level field {key:?} starting with '$' must be rejected"
        );
    }
}

#[test]
fn non_object_filters_are_rejected() {
    for v in [
        json!("a string"),
        json!(42),
        json!(true),
        json!(null),
        json!([1, 2, 3]),
        json!(2.5),
        json!("'; DROP TABLE users; --"),
    ] {
        assert!(
            Filter::parse(&v).is_err(),
            "non-object {v:?} must be rejected"
        );
    }
}

#[test]
fn malformed_operator_payloads_are_rejected() {
    let cases = [
        json!({ "a": { "$in": 5 } }), // $in needs an array
        json!({ "a": { "$in": "x" } }),
        json!({ "a": { "$in": {} } }),
        json!({ "a": { "$between": [1] } }), // between needs exactly 2
        json!({ "a": { "$between": [1, 2, 3] } }),
        json!({ "a": { "$between": 5 } }),
        json!({ "a": { "$between": [] } }),
        json!({ "a": { "$null": 1 } }), // $null needs a bool
        json!({ "a": { "$null": "true" } }),
        json!({ "a": { "$null": [] } }),
        json!({ "$and": "not an array" }), // $and needs an array
        json!({ "$or": 5 }),
        json!({ "$and": [ "not a filter" ] }), // array of non-filters
        json!({ "$or": [ 42 ] }),
    ];
    for v in cases {
        assert!(
            Filter::parse(&v).is_err(),
            "malformed payload {v:?} must be rejected"
        );
    }
}

#[test]
fn in_list_over_the_cap_is_rejected() {
    // MAX_IN_LEN defense-in-depth cap (1000): 1001 elements must be refused.
    let big: Vec<i64> = (0..=1000).collect();
    assert!(
        Filter::parse(&json!({ "a": { "$in": big } })).is_err(),
        "$in list over the 1000-element cap must be rejected"
    );
    // Exactly at the cap is fine.
    let at_cap: Vec<i64> = (0..1000).collect();
    assert!(
        Filter::parse(&json!({ "a": { "$in": at_cap } })).is_ok(),
        "$in list exactly at the cap is accepted"
    );
}

// ── (b) SQL-looking strings are accepted as DATA, never operators ───────────

/// A value that looks like SQL injection must parse into a plain equality whose
/// `value` is the verbatim string — it never becomes an operator or a field.
#[test]
fn sql_looking_values_stay_data_in_equality() {
    let payloads = [
        "1 OR 1=1",
        "'; DROP TABLE users; --",
        "1; DELETE FROM accounts",
        "admin'--",
        "\" OR \"\"=\"",
        "1) OR (1=1",
        "$ne", // looks like an operator but is a plain string VALUE
        "$where",
        "../../etc/passwd",
        "..\\..\\windows\\system32",
        "%27%20OR%201=1",
        "0x44524f50",
        "/*! UNION */",
        "\u{0000}null-byte",
        "\u{202e}rtl-override", // unicode trick
        "ＤＲＯＰ",             // fullwidth unicode "DROP"
        "${jndi:ldap://evil}",
        "{{7*7}}",
    ];
    for p in payloads {
        let f = Filter::parse(&json!({ "name": p })).expect("string value parses as equality");
        match f {
            Filter::Cmp {
                ref field,
                op,
                ref value,
            } => {
                assert_eq!(field, "name", "field is the column, not the payload");
                assert_eq!(op, CmpOp::Eq);
                assert_eq!(
                    value,
                    &json!(p),
                    "the SQL-looking string survives verbatim as data: {p:?}"
                );
            }
            other => panic!("expected Cmp equality for {p:?}, got {other:?}"),
        }
    }
}

/// Same payloads carried through every comparison operator stay as the bound
/// `value` — the operator is the JSON key, never derived from the data.
#[test]
fn sql_looking_values_stay_data_under_every_operator() {
    let payload = "'; DROP TABLE x; --";
    let ops: [(&str, CmpOp); 6] = [
        ("$eq", CmpOp::Eq),
        ("$ne", CmpOp::Ne),
        ("$lt", CmpOp::Lt),
        ("$lte", CmpOp::Lte),
        ("$gt", CmpOp::Gt),
        ("$gte", CmpOp::Gte),
    ];
    for (op, expect) in ops {
        let f = Filter::parse(&json!({ "c": { op: payload } })).unwrap();
        match f {
            Filter::Cmp { op: got, value, .. } => {
                assert_eq!(got, expect, "{op} maps to {expect:?}");
                assert_eq!(
                    value,
                    json!(payload),
                    "injection string is bound as data under {op}"
                );
            }
            other => panic!("expected Cmp for {op}, got {other:?}"),
        }
    }
}

#[test]
fn sql_looking_values_stay_data_in_like_in_between() {
    // $like / $ilike — pattern is a value, not interpolated SQL.
    let f = Filter::parse(&json!({ "c": { "$like": "%'; DROP--%" } })).unwrap();
    assert!(
        matches!(f, Filter::Like { ref pattern, ci: false, .. } if pattern == &json!("%'; DROP--%"))
    );
    let f = Filter::parse(&json!({ "c": { "$ilike": "%OR 1=1%" } })).unwrap();
    assert!(matches!(f, Filter::Like { ci: true, .. }));

    // $in — every element is a bound value (here, all injection strings).
    let f = Filter::parse(&json!({ "c": { "$in": ["1 OR 1=1", "'; DROP", "$ne"] } })).unwrap();
    match f {
        Filter::In { values, .. } => {
            assert_eq!(
                values,
                vec![json!("1 OR 1=1"), json!("'; DROP"), json!("$ne")]
            );
        }
        other => panic!("expected In, got {other:?}"),
    }

    // $between low/high carry the verbatim strings.
    let f = Filter::parse(&json!({ "c": { "$between": ["a'--", "z;--"] } })).unwrap();
    match f {
        Filter::Between { low, high, .. } => {
            assert_eq!(low, json!("a'--"));
            assert_eq!(high, json!("z;--"));
        }
        other => panic!("expected Between, got {other:?}"),
    }
}

#[test]
fn weird_field_names_that_are_not_dollar_prefixed_are_accepted_as_columns() {
    // The grammar only forbids `$`-prefixed and empty fields; other oddities are
    // accepted as column names here and re-validated by the adapter's quoting.
    // The point: they never become operators.
    for col in [
        "a-b",
        "a.b",
        "a b",
        "weird;col",
        "col--",
        "UPPER",
        "数字",
        "a\tb",
    ] {
        let f = Filter::parse(&json!({ col: 1 })).expect("non-$ column accepted");
        match f {
            Filter::Cmp {
                field,
                op: CmpOp::Eq,
                value,
            } => {
                assert_eq!(
                    field, col,
                    "the odd string is the field name, taken verbatim"
                );
                assert_eq!(value, json!(1));
            }
            other => panic!("expected Cmp for column {col:?}, got {other:?}"),
        }
    }
}

// ── (b) fold(): tautology / contradiction detection (full-table guard) ──────

#[test]
fn fold_classifies_tautologies_contradictions_and_real_predicates() {
    let f = |v: Value| Filter::parse(&v).unwrap().fold();
    // AlwaysTrue (full-table — must be refused by mutation guards)
    let always_true = [
        json!({}),
        json!({ "$and": [] }),
        json!({ "$not": { "$or": [] } }),
        json!({ "$or": [{ "a": 1 }, { "$not": { "$or": [] } }] }),
        json!({ "$and": [{}, {}] }),
    ];
    for v in always_true {
        assert_eq!(f(v.clone()), Folded::AlwaysTrue, "{v:?}");
    }
    // AlwaysFalse (matches nothing)
    let always_false = [
        json!({ "$or": [] }),
        json!({ "a": { "$in": [] } }),
        json!({ "$not": {} }),
        json!({ "$and": [{ "a": 1 }, { "b": { "$in": [] } }] }),
    ];
    for v in always_false {
        assert_eq!(f(v.clone()), Folded::AlwaysFalse, "{v:?}");
    }
    // Constrained (genuine predicates — including SQL-looking data values)
    let constrained = [
        json!({ "a": 1 }),
        json!({ "a": { "$gte": 1 } }),
        json!({ "name": "'; DROP TABLE--" }),
        json!({ "$or": [{ "a": 1 }, { "b": 2 }] }),
        json!({ "a": { "$in": ["1 OR 1=1"] } }),
    ];
    for v in constrained {
        assert_eq!(f(v.clone()), Folded::Constrained, "{v:?}");
    }
}

#[test]
fn empty_and_nested_objects_constrain_nothing_or_everything_deterministically() {
    // Deeply nested NOT chains fold to a stable boolean (no panic, no nondeterminism).
    assert_eq!(
        Filter::parse(&json!({ "$not": { "$not": { "$or": [] } } }))
            .unwrap()
            .fold(),
        Folded::AlwaysFalse
    );
    assert_eq!(
        Filter::parse(&json!({ "$not": { "$not": {} } }))
            .unwrap()
            .fold(),
        Folded::AlwaysTrue
    );
}

// ── determinism: multi-key objects sort into a stable AND ───────────────────

#[test]
fn multi_key_objects_are_anded_in_sorted_order() {
    let f = Filter::parse(&json!({ "c": 3, "a": 1, "b": 2 })).unwrap();
    match f {
        Filter::And(parts) => {
            let fields: Vec<&str> = parts
                .iter()
                .map(|p| match p {
                    Filter::Cmp { field, .. } => field.as_str(),
                    _ => "?",
                })
                .collect();
            assert_eq!(
                fields,
                ["a", "b", "c"],
                "keys sorted for deterministic lowering"
            );
        }
        other => panic!("expected And, got {other:?}"),
    }
}
