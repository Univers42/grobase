//! Edge-case suite for `Filter::parse` + `Filter::fold` (filter.rs).
//!
//! Proves the public filter API never panics and rejects every malformed shape
//! the wire grammar forbids, while folding tautologies/contradictions exactly.
//! Tests only — no source logic is changed. Behavior is asserted against what
//! the code actually does (see filter.rs).

use data_plane_core::filter::MAX_IN_LEN;
use data_plane_core::*;
use proptest::prelude::*;
use serde_json::{json, Value};

// ── helpers ──────────────────────────────────────────────────────────────────

fn parse(v: Value) -> Result<Filter, DataPlaneError> {
    Filter::parse(&v)
}
fn ok(v: Value) -> Filter {
    parse(v).expect("expected a valid parse")
}
fn err(v: Value) {
    assert!(parse(v.clone()).is_err(), "expected parse error for {v}");
}
fn folded(v: Value) -> Folded {
    ok(v).fold()
}

// ── VALID: every comparison operator parses to the right Cmp/op ───────────────

#[test]
fn eq_operator_parses_to_cmp_eq() {
    assert!(matches!(
        ok(json!({ "a": { "$eq": 1 } })),
        Filter::Cmp { op: CmpOp::Eq, .. }
    ));
}

#[test]
fn ne_operator_parses_to_cmp_ne() {
    assert!(matches!(
        ok(json!({ "a": { "$ne": 1 } })),
        Filter::Cmp { op: CmpOp::Ne, .. }
    ));
}

#[test]
fn lt_operator_parses_to_cmp_lt() {
    assert!(matches!(
        ok(json!({ "a": { "$lt": 1 } })),
        Filter::Cmp { op: CmpOp::Lt, .. }
    ));
}

#[test]
fn lte_operator_parses_to_cmp_lte() {
    assert!(matches!(
        ok(json!({ "a": { "$lte": 1 } })),
        Filter::Cmp { op: CmpOp::Lte, .. }
    ));
}

#[test]
fn gt_operator_parses_to_cmp_gt() {
    assert!(matches!(
        ok(json!({ "a": { "$gt": 1 } })),
        Filter::Cmp { op: CmpOp::Gt, .. }
    ));
}

#[test]
fn gte_operator_parses_to_cmp_gte() {
    assert!(matches!(
        ok(json!({ "a": { "$gte": 1 } })),
        Filter::Cmp { op: CmpOp::Gte, .. }
    ));
}

#[test]
fn like_operator_is_case_sensitive() {
    assert!(matches!(
        ok(json!({ "a": { "$like": "x%" } })),
        Filter::Like { ci: false, .. }
    ));
}

#[test]
fn ilike_operator_is_case_insensitive() {
    assert!(matches!(
        ok(json!({ "a": { "$ilike": "x%" } })),
        Filter::Like { ci: true, .. }
    ));
}

#[test]
fn in_operator_parses_to_in_with_values() {
    match ok(json!({ "a": { "$in": [1, 2, 3] } })) {
        Filter::In { values, .. } => assert_eq!(values.len(), 3),
        other => panic!("expected In, got {other:?}"),
    }
}

#[test]
fn between_operator_keeps_low_and_high_in_order() {
    match ok(json!({ "a": { "$between": [5, 9] } })) {
        Filter::Between { low, high, .. } => {
            assert_eq!(low, json!(5));
            assert_eq!(high, json!(9));
        }
        other => panic!("expected Between, got {other:?}"),
    }
}

#[test]
fn null_true_is_is_null_not_negated() {
    assert!(matches!(
        ok(json!({ "a": { "$null": true } })),
        Filter::IsNull { negate: false, .. }
    ));
}

#[test]
fn null_false_is_is_not_null_negated() {
    assert!(matches!(
        ok(json!({ "a": { "$null": false } })),
        Filter::IsNull { negate: true, .. }
    ));
}

// ── VALID: scalar shorthand equality for every JSON scalar type ───────────────

#[test]
fn scalar_integer_is_equality() {
    assert_eq!(
        ok(json!({ "a": 7 })),
        Filter::Cmp {
            field: "a".into(),
            op: CmpOp::Eq,
            value: json!(7)
        }
    );
}

#[test]
fn scalar_string_is_equality() {
    assert_eq!(
        ok(json!({ "a": "hi" })),
        Filter::Cmp {
            field: "a".into(),
            op: CmpOp::Eq,
            value: json!("hi")
        }
    );
}

#[test]
fn scalar_bool_is_equality() {
    assert_eq!(
        ok(json!({ "a": true })),
        Filter::Cmp {
            field: "a".into(),
            op: CmpOp::Eq,
            value: json!(true)
        }
    );
}

#[test]
fn scalar_float_is_equality() {
    assert!(matches!(
        ok(json!({ "a": 1.5 })),
        Filter::Cmp { op: CmpOp::Eq, .. }
    ));
}

#[test]
fn scalar_null_value_is_equality_not_is_null() {
    // A bare JSON null is value-equality, NOT the $null operator.
    assert_eq!(
        ok(json!({ "a": Value::Null })),
        Filter::Cmp {
            field: "a".into(),
            op: CmpOp::Eq,
            value: Value::Null
        }
    );
}

#[test]
fn array_value_without_operator_is_equality() {
    // An array value with no `$` keys lowers to jsonb-literal equality.
    assert!(matches!(
        ok(json!({ "tags": [1, 2, 3] })),
        Filter::Cmp { op: CmpOp::Eq, .. }
    ));
}

#[test]
fn object_value_without_dollar_keys_is_equality() {
    // An object whose keys do NOT start with `$` is a jsonb-literal equality,
    // not an operator map.
    assert!(matches!(
        ok(json!({ "meta": { "k": "v" } })),
        Filter::Cmp { op: CmpOp::Eq, .. }
    ));
}

// ── VALID: boolean composition ────────────────────────────────────────────────

#[test]
fn and_with_two_children_parses() {
    assert!(matches!(
        ok(json!({ "$and": [{ "a": 1 }, { "b": 2 }] })),
        Filter::And(v) if v.len() == 2
    ));
}

#[test]
fn or_with_two_children_parses() {
    assert!(matches!(
        ok(json!({ "$or": [{ "a": 1 }, { "b": 2 }] })),
        Filter::Or(v) if v.len() == 2
    ));
}

#[test]
fn not_wraps_inner_filter() {
    assert!(matches!(ok(json!({ "$not": { "a": 1 } })), Filter::Not(_)));
}

#[test]
fn empty_object_is_empty_and() {
    assert_eq!(ok(json!({})), Filter::And(vec![]));
}

#[test]
fn empty_and_array_is_empty_and() {
    assert_eq!(ok(json!({ "$and": [] })), Filter::And(vec![]));
}

#[test]
fn empty_or_array_is_empty_or() {
    assert_eq!(ok(json!({ "$or": [] })), Filter::Or(vec![]));
}

#[test]
fn single_column_does_not_wrap_in_and() {
    // One top-level entry is itself, not And([self]).
    assert!(matches!(ok(json!({ "a": 1 })), Filter::Cmp { .. }));
}

#[test]
fn multiple_columns_wrap_in_and_sorted() {
    // Keys are processed in sorted order, so b/a → And[a, b].
    assert_eq!(
        ok(json!({ "b": 2, "a": 1 })),
        Filter::And(vec![
            Filter::Cmp {
                field: "a".into(),
                op: CmpOp::Eq,
                value: json!(1)
            },
            Filter::Cmp {
                field: "b".into(),
                op: CmpOp::Eq,
                value: json!(2)
            },
        ])
    );
}

#[test]
fn multiple_ops_on_one_column_are_anded_sorted() {
    // {a: {$gte, $lte}} → And[Cmp Gte, Cmp Lte] (op keys sorted: $gte < $lte).
    match ok(json!({ "a": { "$lte": 9, "$gte": 1 } })) {
        Filter::And(parts) => {
            assert_eq!(parts.len(), 2);
            assert!(matches!(parts[0], Filter::Cmp { op: CmpOp::Gte, .. }));
            assert!(matches!(parts[1], Filter::Cmp { op: CmpOp::Lte, .. }));
        }
        other => panic!("expected And, got {other:?}"),
    }
}

#[test]
fn single_op_on_column_does_not_wrap_in_and() {
    assert!(matches!(
        ok(json!({ "a": { "$gt": 1 } })),
        Filter::Cmp { op: CmpOp::Gt, .. }
    ));
}

// ── VALID: nesting depth ──────────────────────────────────────────────────────

#[test]
fn deeply_nested_not_or_and_parses_without_panic() {
    let f = json!({
        "$and": [
            { "$or": [{ "a": 1 }, { "$not": { "b": { "$in": [1, 2] } } }] },
            { "$not": { "$and": [{ "c": { "$gte": 0 } }, { "d": { "$like": "x%" } }] } }
        ]
    });
    assert!(matches!(ok(f), Filter::And(v) if v.len() == 2));
}

#[test]
fn ten_levels_of_not_nesting_parses() {
    // Build $not nested 10 deep around a leaf; must parse, never panic.
    let mut v = json!({ "a": 1 });
    for _ in 0..10 {
        v = json!({ "$not": v });
    }
    assert!(matches!(ok(v), Filter::Not(_)));
}

#[test]
fn nested_and_or_inside_not_inside_or_parses() {
    let f = json!({ "$or": [{ "$not": { "$and": [{ "x": 1 }] } }, { "y": 2 }] });
    assert!(matches!(ok(f), Filter::Or(v) if v.len() == 2));
}

// ── VALID: $in boundary at MAX_IN_LEN ─────────────────────────────────────────

#[test]
fn in_list_exactly_at_cap_is_accepted() {
    let items: Vec<i64> = (0..MAX_IN_LEN as i64).collect();
    match ok(json!({ "a": { "$in": items } })) {
        Filter::In { values, .. } => assert_eq!(values.len(), MAX_IN_LEN),
        other => panic!("expected In at cap, got {other:?}"),
    }
}

#[test]
fn in_list_one_under_cap_is_accepted() {
    let items: Vec<i64> = (0..(MAX_IN_LEN as i64 - 1)).collect();
    assert!(matches!(
        ok(json!({ "a": { "$in": items } })),
        Filter::In { .. }
    ));
}

#[test]
fn in_list_one_over_cap_is_rejected() {
    let items: Vec<i64> = (0..(MAX_IN_LEN as i64 + 1)).collect();
    err(json!({ "a": { "$in": items } }));
}

#[test]
fn in_empty_list_is_accepted_but_matches_nothing() {
    let f = ok(json!({ "a": { "$in": [] } }));
    assert!(matches!(f, Filter::In { .. }));
    assert_eq!(f.fold(), Folded::AlwaysFalse);
}

#[test]
fn in_with_mixed_scalar_types_is_accepted() {
    assert!(matches!(
        ok(json!({ "a": { "$in": [1, "two", true, Value::Null] } })),
        Filter::In { .. }
    ));
}

// ── INVALID: top-level shape ──────────────────────────────────────────────────

#[test]
fn top_level_string_is_rejected() {
    err(json!("hello"));
}

#[test]
fn top_level_number_is_rejected() {
    err(json!(42));
}

#[test]
fn top_level_bool_is_rejected() {
    err(json!(true));
}

#[test]
fn top_level_null_is_rejected() {
    err(Value::Null);
}

#[test]
fn top_level_array_is_rejected() {
    err(json!([{ "a": 1 }]));
}

// ── INVALID: unknown operators ────────────────────────────────────────────────

#[test]
fn unknown_dollar_operator_is_rejected() {
    err(json!({ "a": { "$drop": 1 } }));
}

#[test]
fn dollar_where_operator_is_rejected_as_field() {
    // `$where` at the column position is a `$`-prefixed FIELD → rejected.
    err(json!({ "$where": "1==1" }));
}

#[test]
fn unknown_top_level_dollar_key_is_rejected_as_field() {
    err(json!({ "$expr": { "a": 1 } }));
}

#[test]
fn regex_operator_is_not_supported() {
    err(json!({ "a": { "$regex": ".*" } }));
}

#[test]
fn nin_operator_is_not_supported() {
    err(json!({ "a": { "$nin": [1, 2] } }));
}

#[test]
fn exists_operator_is_not_supported() {
    err(json!({ "a": { "$exists": true } }));
}

#[test]
fn mixed_known_and_unknown_op_on_column_is_rejected() {
    // One bad op poisons the whole column predicate.
    err(json!({ "a": { "$gte": 1, "$bogus": 2 } }));
}

// ── INVALID: malformed operator value shapes ──────────────────────────────────

#[test]
fn in_with_non_array_value_is_rejected() {
    err(json!({ "a": { "$in": 5 } }));
}

#[test]
fn in_with_object_value_is_rejected() {
    err(json!({ "a": { "$in": { "k": "v" } } }));
}

#[test]
fn in_with_string_value_is_rejected() {
    err(json!({ "a": { "$in": "abc" } }));
}

#[test]
fn between_with_one_element_is_rejected() {
    err(json!({ "a": { "$between": [1] } }));
}

#[test]
fn between_with_three_elements_is_rejected() {
    err(json!({ "a": { "$between": [1, 2, 3] } }));
}

#[test]
fn between_with_empty_array_is_rejected() {
    err(json!({ "a": { "$between": [] } }));
}

#[test]
fn between_with_non_array_value_is_rejected() {
    err(json!({ "a": { "$between": 5 } }));
}

#[test]
fn between_with_object_value_is_rejected() {
    err(json!({ "a": { "$between": { "low": 1, "high": 2 } } }));
}

#[test]
fn null_with_integer_value_is_rejected() {
    err(json!({ "a": { "$null": 1 } }));
}

#[test]
fn null_with_string_value_is_rejected() {
    err(json!({ "a": { "$null": "true" } }));
}

#[test]
fn null_with_array_value_is_rejected() {
    err(json!({ "a": { "$null": [true] } }));
}

#[test]
fn null_with_null_value_is_rejected() {
    err(json!({ "a": { "$null": Value::Null } }));
}

#[test]
fn and_with_non_array_value_is_rejected() {
    err(json!({ "$and": { "a": 1 } }));
}

#[test]
fn or_with_non_array_value_is_rejected() {
    err(json!({ "$or": "nope" }));
}

#[test]
fn and_with_scalar_item_is_rejected() {
    // Array items of $and must themselves be filter objects.
    err(json!({ "$and": [1, 2] }));
}

#[test]
fn or_with_array_item_is_rejected() {
    err(json!({ "$or": [[{ "a": 1 }]] }));
}

#[test]
fn not_with_scalar_inner_is_rejected() {
    err(json!({ "$not": 5 }));
}

#[test]
fn not_with_array_inner_is_rejected() {
    err(json!({ "$not": [{ "a": 1 }] }));
}

#[test]
fn nested_invalid_operator_inside_and_propagates_error() {
    err(json!({ "$and": [{ "a": 1 }, { "b": { "$bad": 2 } }] }));
}

#[test]
fn nested_invalid_in_inside_not_propagates_error() {
    err(json!({ "$not": { "a": { "$in": 99 } } }));
}

// ── INVALID: field-name validation ────────────────────────────────────────────

#[test]
fn empty_field_name_is_rejected() {
    err(json!({ "": 1 }));
}

#[test]
fn empty_field_name_with_operator_is_rejected() {
    err(json!({ "": { "$gt": 1 } }));
}

#[test]
fn dollar_prefixed_arbitrary_field_is_rejected() {
    err(json!({ "$custom": 1 }));
}

#[test]
fn field_starting_with_dollar_even_with_more_chars_is_rejected() {
    err(json!({ "$foo_bar": "x" }));
}

// ── VALID: unusual-but-legal field names (only empty / $-prefix are barred) ───

#[test]
fn field_with_dot_is_accepted() {
    assert!(matches!(ok(json!({ "a.b.c": 1 })), Filter::Cmp { .. }));
}

#[test]
fn field_with_spaces_is_accepted() {
    assert!(matches!(ok(json!({ "a b c": 1 })), Filter::Cmp { .. }));
}

#[test]
fn field_with_unicode_is_accepted() {
    assert!(matches!(
        ok(json!({ "naïve_café_名前": 1 })),
        Filter::Cmp { .. }
    ));
}

#[test]
fn field_with_dollar_not_at_start_is_accepted() {
    // The rule is *starts_with* `$`; an interior `$` is fine.
    assert!(matches!(ok(json!({ "a$b": 1 })), Filter::Cmp { .. }));
}

#[test]
fn field_containing_sql_injection_text_stays_a_field_name() {
    // The field name is preserved verbatim as data (quoting happens in adapters).
    match ok(json!({ "id; DROP TABLE users; --": 1 })) {
        Filter::Cmp { field, .. } => assert_eq!(field, "id; DROP TABLE users; --"),
        other => panic!("expected Cmp, got {other:?}"),
    }
}

#[test]
fn field_that_is_just_numbers_is_accepted() {
    assert!(matches!(ok(json!({ "12345": 1 })), Filter::Cmp { .. }));
}

// ── VALUE PRESERVATION: SQL-looking strings stay data ─────────────────────────

#[test]
fn sql_injection_string_in_equality_is_preserved_verbatim() {
    let payload = "'; DROP TABLE x; --";
    match ok(json!({ "a": payload })) {
        Filter::Cmp { value, .. } => assert_eq!(value, json!(payload)),
        other => panic!("expected Cmp, got {other:?}"),
    }
}

#[test]
fn sql_injection_string_in_like_pattern_is_preserved() {
    let payload = "%' OR '1'='1";
    match ok(json!({ "a": { "$like": payload } })) {
        Filter::Like { pattern, .. } => assert_eq!(pattern, json!(payload)),
        other => panic!("expected Like, got {other:?}"),
    }
}

#[test]
fn sql_injection_strings_in_in_list_are_preserved() {
    let p1 = "1); DELETE FROM t; --";
    match ok(json!({ "a": { "$in": [p1, "ok"] } })) {
        Filter::In { values, .. } => assert_eq!(values[0], json!(p1)),
        other => panic!("expected In, got {other:?}"),
    }
}

#[test]
fn between_bounds_preserve_injection_strings() {
    match ok(json!({ "a": { "$between": ["x' OR 1=1", "y; --"] } })) {
        Filter::Between { low, high, .. } => {
            assert_eq!(low, json!("x' OR 1=1"));
            assert_eq!(high, json!("y; --"));
        }
        other => panic!("expected Between, got {other:?}"),
    }
}

// ── FOLD: tautologies (AlwaysTrue) ────────────────────────────────────────────

#[test]
fn fold_empty_object_is_always_true() {
    assert_eq!(folded(json!({})), Folded::AlwaysTrue);
}

#[test]
fn fold_empty_and_is_always_true() {
    assert_eq!(folded(json!({ "$and": [] })), Folded::AlwaysTrue);
}

#[test]
fn fold_not_empty_or_is_always_true() {
    // NOT(FALSE) = TRUE; empty $or is FALSE.
    assert_eq!(folded(json!({ "$not": { "$or": [] } })), Folded::AlwaysTrue);
}

#[test]
fn fold_not_empty_in_is_always_true() {
    // NOT(empty $in) = NOT(FALSE) = TRUE.
    assert_eq!(
        folded(json!({ "$not": { "a": { "$in": [] } } })),
        Folded::AlwaysTrue
    );
}

#[test]
fn fold_or_with_a_tautology_branch_is_always_true() {
    assert_eq!(
        folded(json!({ "$or": [{ "a": 1 }, { "$not": { "$or": [] } }] })),
        Folded::AlwaysTrue
    );
}

#[test]
fn fold_and_of_all_true_children_is_always_true() {
    assert_eq!(
        folded(json!({ "$and": [{}, { "$and": [] }] })),
        Folded::AlwaysTrue
    );
}

#[test]
fn fold_double_negation_of_constrained_stays_constrained() {
    assert_eq!(
        folded(json!({ "$not": { "$not": { "a": 1 } } })),
        Folded::Constrained
    );
}

// ── FOLD: contradictions (AlwaysFalse) ────────────────────────────────────────

#[test]
fn fold_empty_or_is_always_false() {
    assert_eq!(folded(json!({ "$or": [] })), Folded::AlwaysFalse);
}

#[test]
fn fold_empty_in_is_always_false() {
    assert_eq!(folded(json!({ "a": { "$in": [] } })), Folded::AlwaysFalse);
}

#[test]
fn fold_not_empty_object_is_always_false() {
    // NOT(empty {} = TRUE) = FALSE.
    assert_eq!(folded(json!({ "$not": {} })), Folded::AlwaysFalse);
}

#[test]
fn fold_not_empty_and_is_always_false() {
    assert_eq!(
        folded(json!({ "$not": { "$and": [] } })),
        Folded::AlwaysFalse
    );
}

#[test]
fn fold_and_with_a_false_branch_is_always_false() {
    // AND with FALSE = FALSE, regardless of the other branch.
    assert_eq!(
        folded(json!({ "$and": [{ "a": 1 }, { "b": { "$in": [] } }] })),
        Folded::AlwaysFalse
    );
}

#[test]
fn fold_or_of_all_false_children_is_always_false() {
    assert_eq!(
        folded(json!({ "$or": [{ "a": { "$in": [] } }, { "$or": [] }] })),
        Folded::AlwaysFalse
    );
}

#[test]
fn fold_not_of_tautology_or_branch_is_always_false() {
    // NOT( OR[constrained, TRUE] = TRUE ) = FALSE.
    assert_eq!(
        folded(json!({ "$not": { "$or": [{ "a": 1 }, { "$not": { "$or": [] } }] } })),
        Folded::AlwaysFalse
    );
}

// ── FOLD: genuine predicates (Constrained) ────────────────────────────────────

#[test]
fn fold_scalar_equality_is_constrained() {
    assert_eq!(folded(json!({ "a": 1 })), Folded::Constrained);
}

#[test]
fn fold_comparison_is_constrained() {
    assert_eq!(folded(json!({ "a": { "$gte": 1 } })), Folded::Constrained);
}

#[test]
fn fold_non_empty_in_is_constrained() {
    assert_eq!(
        folded(json!({ "a": { "$in": [1, 2] } })),
        Folded::Constrained
    );
}

#[test]
fn fold_like_is_constrained() {
    assert_eq!(
        folded(json!({ "a": { "$like": "x%" } })),
        Folded::Constrained
    );
}

#[test]
fn fold_between_is_constrained() {
    assert_eq!(
        folded(json!({ "a": { "$between": [1, 9] } })),
        Folded::Constrained
    );
}

#[test]
fn fold_is_null_is_constrained() {
    assert_eq!(
        folded(json!({ "a": { "$null": true } })),
        Folded::Constrained
    );
}

#[test]
fn fold_or_with_one_constrained_and_one_false_is_constrained() {
    // OR[constrained, FALSE] keeps the constrained branch.
    assert_eq!(
        folded(json!({ "$or": [{ "a": 1 }, { "b": { "$in": [] } }] })),
        Folded::Constrained
    );
}

#[test]
fn fold_and_with_one_constrained_and_one_true_is_constrained() {
    assert_eq!(
        folded(json!({ "$and": [{ "a": 1 }, {}] })),
        Folded::Constrained
    );
}

#[test]
fn fold_not_of_constrained_is_constrained() {
    assert_eq!(
        folded(json!({ "$not": { "a": { "$gt": 5 } } })),
        Folded::Constrained
    );
}

// ── PROPERTY-BASED ────────────────────────────────────────────────────────────

proptest! {
    /// Equality shorthand on any non-`$` field with any JSON scalar value never
    /// panics and always yields a Cmp Eq whose value is preserved byte-for-byte.
    #[test]
    fn prop_scalar_equality_preserves_value(field in "[a-z][a-z0-9_]{0,12}", n in any::<i64>()) {
        let f = Filter::parse(&json!({ field.clone(): n })).unwrap();
        prop_assert_eq!(
            f,
            Filter::Cmp { field, op: CmpOp::Eq, value: json!(n) }
        );
    }

    /// Any `$`-prefixed field name (that isn't a known boolean op) is rejected,
    /// never panics.
    #[test]
    fn prop_dollar_field_always_rejected(suffix in "[a-zA-Z0-9_]{0,16}") {
        let field = format!("${suffix}");
        // Skip the three reserved boolean composition keys, which are valid.
        prop_assume!(!["$and", "$or", "$not"].contains(&field.as_str()));
        let is_err = Filter::parse(&json!({ field: 1 })).is_err();
        prop_assert!(is_err);
    }

    /// An `$in` list of length n is accepted iff n <= MAX_IN_LEN, and the fold
    /// is AlwaysFalse exactly when the list is empty.
    #[test]
    fn prop_in_cap_boundary_and_fold(n in 0usize..(MAX_IN_LEN + 5)) {
        let items: Vec<i64> = (0..n as i64).collect();
        let res = Filter::parse(&json!({ "a": { "$in": items } }));
        if n <= MAX_IN_LEN {
            let f = res.unwrap();
            let expected = if n == 0 { Folded::AlwaysFalse } else { Folded::Constrained };
            prop_assert_eq!(f.fold(), expected);
        } else {
            prop_assert!(res.is_err());
        }
    }

    /// `$between` is accepted iff the array has exactly two elements.
    #[test]
    fn prop_between_requires_exactly_two(n in 0usize..6) {
        let items: Vec<i64> = (0..n as i64).collect();
        let res = Filter::parse(&json!({ "a": { "$between": items } }));
        prop_assert_eq!(res.is_ok(), n == 2);
    }

    /// `$null` is accepted iff its value is a JSON boolean; the negate flag is
    /// the logical inverse of the boolean.
    #[test]
    fn prop_null_accepts_only_bool(b in any::<bool>()) {
        match Filter::parse(&json!({ "a": { "$null": b } })).unwrap() {
            Filter::IsNull { negate, .. } => prop_assert_eq!(negate, !b),
            other => prop_assert!(false, "expected IsNull, got {:?}", other),
        }
        // A non-bool $null value is always rejected.
        let int_rejected = Filter::parse(&json!({ "a": { "$null": b as i64 } })).is_err();
        prop_assert!(int_rejected);
    }

    /// Folding is total: any parseable filter folds to exactly one of the three
    /// variants and never panics. (Generated from a small recursive shape.)
    #[test]
    fn prop_fold_is_total(depth in 0u32..5, leaf in any::<i64>()) {
        let mut v = json!({ "a": leaf });
        for i in 0..depth {
            v = if i % 2 == 0 { json!({ "$not": v }) } else { json!({ "$and": [v] }) };
        }
        let f = Filter::parse(&v).unwrap();
        let fold = f.fold();
        prop_assert!(matches!(
            fold,
            Folded::AlwaysTrue | Folded::AlwaysFalse | Folded::Constrained
        ));
    }

    /// Wrapping any constrained leaf in N levels of `$or: [ _ ]` keeps it
    /// Constrained (a single-child OR neither short-circuits true nor false).
    #[test]
    fn prop_single_child_or_preserves_constrained(depth in 1u32..6) {
        let mut v = json!({ "a": 1 });
        for _ in 0..depth {
            v = json!({ "$or": [v] });
        }
        prop_assert_eq!(Filter::parse(&v).unwrap().fold(), Folded::Constrained);
    }
}
