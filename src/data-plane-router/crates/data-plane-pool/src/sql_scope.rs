//! Shared SQL filter-lowering for the relational adapters (sqlite, mysql, mssql).
//!
//! The three engines lowered a validated [`Filter`] to a `WHERE` fragment with
//! byte-identical logic, differing only in (a) how a bound parameter is recorded
//! and rendered as a placeholder and (b) identifier quoting. Both are captured by
//! [`SqlParamSink`]; the recursive descent, reserved-column stripping, and the
//! no-full-table-mutation guard live here once.
//!
//! Postgres is deliberately NOT a client: it scopes via RLS GUCs and its own
//! constant-folding compiler (`lower_pg`), not an appended `owner_id` predicate.
//! Owner stamping also stays per-engine (the engines gate it differently); this
//! module is only the engine-neutral filter machinery.

use data_plane_core::{CmpOp, DataPlaneError, DataPlaneResult, Filter, Folded};
use serde_json::Value;
use std::borrow::Cow;

/// A per-request parameter accumulator + dialect for one relational engine.
///
/// `bind` is the ONLY way to add a parameter, so the number of placeholders in a
/// generated fragment always equals the number of bound parameters — an engine
/// cannot bind a value to the wrong column by miscounting positions.
pub(crate) trait SqlParamSink {
    /// Record `value` as a bound parameter and return its placeholder text
    /// (`?` for positional engines, `@P{n}` for SQL Server).
    fn bind(&mut self, value: &Value) -> String;
    /// Quote an identifier for this dialect (rejects an invalid identifier).
    fn quote_ident(&self, name: &str) -> DataPlaneResult<String>;
}

/// The comparison operator → SQL token map (identical across the relational
/// engines).
pub(crate) fn cmp_op_sql(op: CmpOp) -> &'static str {
    match op {
        CmpOp::Eq => "=",
        CmpOp::Ne => "<>",
        CmpOp::Lt => "<",
        CmpOp::Lte => "<=",
        CmpOp::Gt => ">",
        CmpOp::Gte => ">=",
    }
}

/// Drop top-level reserved keys from a filter object so a client cannot set a
/// trusted column. Borrows unchanged in the common case (no reserved key
/// present), only cloning when one must actually be stripped.
pub(crate) fn strip_reserved_top_level<'a>(filter: &'a Value, reserved: &[&str]) -> Cow<'a, Value> {
    if let Value::Object(map) = filter {
        if map.keys().any(|k| reserved.contains(&k.as_str())) {
            let cleaned = map
                .iter()
                .filter(|(k, _)| !reserved.contains(&k.as_str()))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect();
            return Cow::Owned(Value::Object(cleaned));
        }
    }
    Cow::Borrowed(filter)
}

/// Refuse an UPDATE/DELETE whose filter constrains nothing (full-table mutation).
pub(crate) fn guard_constraining_filter(
    filter: Option<&Value>,
    reserved: &[&str],
) -> DataPlaneResult<()> {
    let folded = match filter {
        Some(v) => Filter::parse(&strip_reserved_top_level(v, reserved))?.fold(),
        None => Folded::AlwaysTrue,
    };
    if folded == Folded::AlwaysTrue {
        return Err(DataPlaneError::InvalidRequest {
            message: "update/delete requires a constraining filter (refusing full-table mutation)"
                .to_string(),
        });
    }
    Ok(())
}

/// Lower a validated [`Filter`] to a `WHERE` fragment (without the `WHERE`
/// keyword), recording every value through `sink`. Returns `None` when the
/// filter constrains nothing (`And([])`).
pub(crate) fn lower_filter<S: SqlParamSink>(
    filter: &Filter,
    sink: &mut S,
) -> DataPlaneResult<Option<String>> {
    Ok(match filter {
        Filter::And(parts) => {
            let mut sqls = Vec::with_capacity(parts.len());
            for p in parts {
                if let Some(s) = lower_filter(p, sink)? {
                    sqls.push(s);
                }
            }
            if sqls.is_empty() {
                None
            } else {
                Some(sqls.join(" AND "))
            }
        }
        Filter::Or(parts) => {
            let mut sqls = Vec::with_capacity(parts.len());
            for p in parts {
                if let Some(s) = lower_filter(p, sink)? {
                    sqls.push(format!("({s})"));
                }
            }
            Some(if sqls.is_empty() {
                "0 = 1".to_string()
            } else {
                sqls.join(" OR ")
            })
        }
        Filter::Not(inner) => lower_filter(inner, sink)?.map(|s| format!("NOT ({s})")),
        Filter::Cmp { field, op, value } => {
            let q = sink.quote_ident(field)?;
            let ph = sink.bind(value);
            Some(format!("{q} {} {ph}", cmp_op_sql(*op)))
        }
        Filter::In { field, values } => {
            let q = sink.quote_ident(field)?;
            if values.is_empty() {
                Some("0 = 1".to_string())
            } else {
                let ph: Vec<String> = values.iter().map(|v| sink.bind(v)).collect();
                Some(format!("{q} IN ({})", ph.join(", ")))
            }
        }
        Filter::Like { field, pattern, ci } => {
            let q = sink.quote_ident(field)?;
            let ph = sink.bind(pattern);
            Some(if *ci {
                format!("LOWER({q}) LIKE LOWER({ph})")
            } else {
                format!("{q} LIKE {ph}")
            })
        }
        Filter::Between { field, low, high } => {
            let q = sink.quote_ident(field)?;
            let lo = sink.bind(low);
            let hi = sink.bind(high);
            Some(format!("{q} BETWEEN {lo} AND {hi}"))
        }
        Filter::IsNull { field, negate } => {
            let q = sink.quote_ident(field)?;
            Some(format!("{q} IS {}NULL", if *negate { "NOT " } else { "" }))
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use serde_json::json;

    /// A positional-`?` sink that records bound values — mirrors the
    /// sqlite/mysql binding. The placeholder/param invariant holds identically
    /// for the `@Pn` dialect: `bind` is the only parameter source either way.
    #[derive(Default)]
    struct TestSink {
        params: Vec<Value>,
    }
    impl SqlParamSink for TestSink {
        fn bind(&mut self, value: &Value) -> String {
            self.params.push(value.clone());
            "?".to_string()
        }
        fn quote_ident(&self, name: &str) -> DataPlaneResult<String> {
            Ok(format!("\"{name}\""))
        }
    }

    fn cmp(field: &str, op: CmpOp, value: Value) -> Filter {
        Filter::Cmp {
            field: field.into(),
            op,
            value,
        }
    }

    fn lowered(f: &Filter) -> (String, usize) {
        let mut sink = TestSink::default();
        let sql = lower_filter(f, &mut sink).unwrap().unwrap_or_default();
        (sql, sink.params.len())
    }

    #[test]
    fn each_arm_lowers_to_expected_sql_with_balanced_placeholders() {
        let cases: Vec<(Filter, &str)> = vec![
            (cmp("a", CmpOp::Eq, json!(1)), "\"a\" = ?"),
            (cmp("a", CmpOp::Ne, json!(1)), "\"a\" <> ?"),
            (cmp("a", CmpOp::Gte, json!(1)), "\"a\" >= ?"),
            (
                Filter::In {
                    field: "a".into(),
                    values: vec![json!(1), json!(2)],
                },
                "\"a\" IN (?, ?)",
            ),
            (
                Filter::In {
                    field: "a".into(),
                    values: vec![],
                },
                "0 = 1",
            ),
            (
                Filter::Like {
                    field: "a".into(),
                    pattern: json!("x%"),
                    ci: false,
                },
                "\"a\" LIKE ?",
            ),
            (
                Filter::Like {
                    field: "a".into(),
                    pattern: json!("x%"),
                    ci: true,
                },
                "LOWER(\"a\") LIKE LOWER(?)",
            ),
            (
                Filter::Between {
                    field: "a".into(),
                    low: json!(1),
                    high: json!(9),
                },
                "\"a\" BETWEEN ? AND ?",
            ),
            (
                Filter::IsNull {
                    field: "a".into(),
                    negate: false,
                },
                "\"a\" IS NULL",
            ),
            (
                Filter::IsNull {
                    field: "a".into(),
                    negate: true,
                },
                "\"a\" IS NOT NULL",
            ),
            (
                Filter::Not(Box::new(cmp("a", CmpOp::Eq, json!(1)))),
                "NOT (\"a\" = ?)",
            ),
            (Filter::And(vec![]), ""),
            (Filter::Or(vec![]), "0 = 1"),
            (
                Filter::Or(vec![
                    cmp("a", CmpOp::Eq, json!(1)),
                    cmp("b", CmpOp::Eq, json!(2)),
                ]),
                "(\"a\" = ?) OR (\"b\" = ?)",
            ),
            (
                Filter::And(vec![
                    cmp("a", CmpOp::Eq, json!(1)),
                    cmp("b", CmpOp::Eq, json!(2)),
                ]),
                "\"a\" = ? AND \"b\" = ?",
            ),
        ];
        for (f, expect) in cases {
            let (sql, params) = lowered(&f);
            assert_eq!(sql, expect, "filter {f:?}");
            assert_eq!(
                sql.matches('?').count(),
                params,
                "balanced placeholders for {f:?}"
            );
        }
    }

    fn arb_filter() -> impl Strategy<Value = Filter> {
        let leaf = prop_oneof![
            ("[a-z]{1,4}", any::<i64>())
                .prop_map(|(f, v)| Filter::Cmp { field: f, op: CmpOp::Eq, value: json!(v) }),
            ("[a-z]{1,4}", prop::collection::vec(any::<i64>(), 0..4)).prop_map(|(f, vs)| {
                Filter::In { field: f, values: vs.into_iter().map(|v| json!(v)).collect() }
            }),
            ("[a-z]{1,4}", any::<bool>())
                .prop_map(|(f, ci)| Filter::Like { field: f, pattern: json!("x%"), ci }),
            ("[a-z]{1,4}", any::<i64>(), any::<i64>())
                .prop_map(|(f, lo, hi)| Filter::Between { field: f, low: json!(lo), high: json!(hi) }),
            ("[a-z]{1,4}", any::<bool>())
                .prop_map(|(f, negate)| Filter::IsNull { field: f, negate }),
        ];
        leaf.prop_recursive(4, 48, 4, |inner| {
            prop_oneof![
                prop::collection::vec(inner.clone(), 0..4).prop_map(Filter::And),
                prop::collection::vec(inner.clone(), 0..4).prop_map(Filter::Or),
                inner.prop_map(|f| Filter::Not(Box::new(f))),
            ]
        })
    }

    proptest! {
        /// The devil's #3 guard, fuzzed: for ANY filter tree, the number of `?`
        /// placeholders in the emitted SQL equals the number of bound parameters
        /// — so a value can never bind to the wrong column by miscounting.
        #[test]
        fn placeholder_count_always_equals_bound_param_count(f in arb_filter()) {
            let (sql, params) = lowered(&f);
            prop_assert_eq!(sql.matches('?').count(), params);
        }
    }

    // ── extended edge-case coverage ─────────────────────────────────────────
    //
    // A SECOND sink that emits numbered `@P{n}` placeholders, mirroring the
    // SQL-Server `Binder`. The placeholder/param invariant must hold here too:
    // `bind` is the only parameter source either way, so the count of distinct
    // emitted placeholders equals the number of recorded params.
    #[derive(Default)]
    struct NumberedSink {
        params: Vec<Value>,
    }
    impl SqlParamSink for NumberedSink {
        fn bind(&mut self, value: &Value) -> String {
            self.params.push(value.clone());
            format!("@P{}", self.params.len())
        }
        fn quote_ident(&self, name: &str) -> DataPlaneResult<String> {
            Ok(format!("[{}]", name.replace(']', "]]")))
        }
    }

    fn lowered_numbered(f: &Filter) -> (String, usize) {
        let mut sink = NumberedSink::default();
        let sql = lower_filter(f, &mut sink).unwrap().unwrap_or_default();
        (sql, sink.params.len())
    }

    /// Count distinct `@P{n}` tokens in a numbered-sink fragment.
    fn count_at_p(sql: &str) -> usize {
        let mut seen = std::collections::HashSet::new();
        let bytes = sql.as_bytes();
        let mut i = 0;
        while i + 1 < bytes.len() {
            if bytes[i] == b'@' && bytes[i + 1] == b'P' {
                let mut j = i + 2;
                while j < bytes.len() && bytes[j].is_ascii_digit() {
                    j += 1;
                }
                if j > i + 2 {
                    seen.insert(sql[i..j].to_string());
                }
                i = j;
            } else {
                i += 1;
            }
        }
        seen.len()
    }

    const ALL_OPS: [CmpOp; 6] = [
        CmpOp::Eq,
        CmpOp::Ne,
        CmpOp::Lt,
        CmpOp::Lte,
        CmpOp::Gt,
        CmpOp::Gte,
    ];

    // A diverse value menu reused across the value-type matrices.
    fn value_menu() -> Vec<Value> {
        vec![
            Value::Null,
            json!(true),
            json!(false),
            json!(0),
            json!(-1),
            json!(i64::MAX),
            json!(i64::MIN),
            json!(u64::MAX),
            json!(3.14),
            json!(-2.5e10),
            json!(0.0),
            json!(""),
            json!("plain"),
            json!("emoji-🦀-中"),
            json!("has \" quote"),
            json!("has ' apostrophe"),
            json!([1, 2, 3]),
            json!([]),
            json!({ "nested": { "deep": [true, null] } }),
            json!({}),
        ]
    }

    // ---- strip_reserved_top_level: borrow vs. clone, nesting ----------------

    #[test]
    fn strip_reserved_borrows_when_no_reserved_key_present() {
        let v = json!({ "name": "a", "age": 1 });
        let out = strip_reserved_top_level(&v, &["owner_id", "tenant_id"]);
        assert!(matches!(out, Cow::Borrowed(_)), "no reserved key → borrow");
        assert_eq!(&*out, &v);
    }

    #[test]
    fn strip_reserved_removes_only_top_level_reserved_keys() {
        let v = json!({ "owner_id": "x", "tenant_id": "y", "name": "keep" });
        let out = strip_reserved_top_level(&v, &["owner_id", "tenant_id"]);
        assert!(matches!(out, Cow::Owned(_)), "a reserved key → clone");
        assert_eq!(&*out, &json!({ "name": "keep" }));
    }

    #[test]
    fn strip_reserved_leaves_nested_reserved_keys_untouched() {
        // Only TOP-level keys are stripped; a nested owner_id stays.
        let v = json!({ "owner_id": "x", "meta": { "owner_id": "nested" } });
        let out = strip_reserved_top_level(&v, &["owner_id"]);
        assert_eq!(&*out, &json!({ "meta": { "owner_id": "nested" } }));
    }

    #[test]
    fn strip_reserved_on_non_object_borrows_unchanged() {
        for v in [json!([1, 2]), json!("s"), json!(7), Value::Null] {
            let out = strip_reserved_top_level(&v, &["owner_id"]);
            assert!(matches!(out, Cow::Borrowed(_)));
            assert_eq!(&*out, &v);
        }
    }

    #[test]
    fn strip_reserved_empty_reserved_list_is_a_noop_borrow() {
        let v = json!({ "owner_id": "x" });
        let out = strip_reserved_top_level(&v, &[]);
        assert!(matches!(out, Cow::Borrowed(_)));
        assert_eq!(&*out, &v);
    }

    // ---- guard_constraining_filter: refuses full-table mutations ------------

    #[test]
    fn guard_refuses_none_and_tautologies() {
        let reserved = ["owner_id", "tenant_id"];
        let unconstrained = [
            None,
            Some(json!({})),
            Some(json!({ "$and": [] })),
            Some(json!({ "$not": { "$or": [] } })),
            Some(json!({ "owner_id": "x" })), // empty after strip
            Some(json!({ "owner_id": "x", "tenant_id": "y" })),
        ];
        for f in unconstrained {
            let err = guard_constraining_filter(f.as_ref(), &reserved).unwrap_err();
            assert!(
                matches!(err, DataPlaneError::InvalidRequest { .. }),
                "{f:?} → {err:?}"
            );
        }
    }

    #[test]
    fn guard_accepts_a_constraining_filter() {
        let reserved = ["owner_id"];
        for f in [
            json!({ "id": 1 }),
            json!({ "age": { "$gte": 18 } }),
            json!({ "owner_id": "x", "name": "real" }), // survives the strip
            json!({ "$or": [] }),                       // matches nothing, but constrains
        ] {
            assert!(
                guard_constraining_filter(Some(&f), &reserved).is_ok(),
                "filter {f} should be accepted"
            );
        }
    }

    #[test]
    fn guard_propagates_parse_errors() {
        // A malformed filter (unknown operator) is a parse error, not a silent
        // full-table pass.
        let err = guard_constraining_filter(Some(&json!({ "a": { "$drop": 1 } })), &[]).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{err:?}");
    }

    // ---- Cmp × every CmpOp × every value type -------------------------------

    #[test]
    fn cmp_every_op_emits_correct_symbol_and_one_param() {
        for op in ALL_OPS {
            let (sql, n) = lowered(&cmp("c", op, json!(1)));
            assert_eq!(sql, format!("\"c\" {} ?", cmp_op_sql(op)), "op {op:?}");
            assert_eq!(n, 1, "op {op:?} binds exactly one param");
        }
    }

    #[test]
    fn cmp_op_sql_is_total_and_distinct() {
        let mut seen = std::collections::HashSet::new();
        for op in ALL_OPS {
            let sym = cmp_op_sql(op);
            assert!(!sym.is_empty());
            assert!(seen.insert(sym), "duplicate symbol for {op:?}");
        }
        assert_eq!(seen.len(), 6, "all six operators map to a distinct token");
    }

    #[test]
    fn cmp_eq_over_every_value_type_binds_exactly_one_param() {
        for v in value_menu() {
            let (sql, n) = lowered(&cmp("col", CmpOp::Eq, v.clone()));
            assert_eq!(sql, "\"col\" = ?", "value {v}");
            assert_eq!(n, 1, "value {v} must bind exactly one param");
        }
    }

    #[test]
    fn cmp_records_the_exact_value_object_unchanged() {
        for v in value_menu() {
            let mut sink = TestSink::default();
            lower_filter(&cmp("c", CmpOp::Ne, v.clone()), &mut sink).unwrap();
            assert_eq!(sink.params, vec![v.clone()], "round-trip {v}");
        }
    }

    // ---- In: empty / 1 / many, value types ----------------------------------

    #[test]
    fn in_empty_renders_false_constant_and_binds_nothing() {
        let f = Filter::In {
            field: "a".into(),
            values: vec![],
        };
        let (sql, n) = lowered(&f);
        assert_eq!(sql, "0 = 1");
        assert_eq!(n, 0, "an empty IN binds no params");
    }

    #[test]
    fn in_single_value_has_one_placeholder() {
        let f = Filter::In {
            field: "a".into(),
            values: vec![json!("x")],
        };
        let (sql, n) = lowered(&f);
        assert_eq!(sql, "\"a\" IN (?)");
        assert_eq!(n, 1);
    }

    #[test]
    fn in_many_values_placeholder_count_matches_list_len() {
        for len in [2usize, 3, 7, 50, 1000] {
            let values: Vec<Value> = (0..len).map(|i| json!(i as i64)).collect();
            let f = Filter::In {
                field: "a".into(),
                values,
            };
            let (sql, n) = lowered(&f);
            assert_eq!(n, len, "len {len}");
            assert_eq!(sql.matches('?').count(), len, "len {len}");
            assert!(sql.starts_with("\"a\" IN ("));
        }
    }

    #[test]
    fn in_mixed_value_types_each_bind_one_placeholder() {
        let values = value_menu();
        let len = values.len();
        let f = Filter::In {
            field: "mix".into(),
            values: values.clone(),
        };
        let (sql, n) = lowered(&f);
        assert_eq!(n, len);
        assert_eq!(sql.matches('?').count(), len);
        // bind preserves order & identity
        let mut sink = TestSink::default();
        lower_filter(&f, &mut sink).unwrap();
        assert_eq!(sink.params, values);
    }

    // ---- Like: case-insensitive both ways, value types ----------------------

    #[test]
    fn like_case_sensitive_and_insensitive_shapes() {
        let cs = Filter::Like {
            field: "n".into(),
            pattern: json!("a%"),
            ci: false,
        };
        let ci = Filter::Like {
            field: "n".into(),
            pattern: json!("a%"),
            ci: true,
        };
        assert_eq!(lowered(&cs).0, "\"n\" LIKE ?");
        assert_eq!(lowered(&ci).0, "LOWER(\"n\") LIKE LOWER(?)");
        assert_eq!(lowered(&cs).1, 1);
        assert_eq!(lowered(&ci).1, 1);
    }

    #[test]
    fn like_binds_any_pattern_value_type() {
        // The lowerer never inspects the pattern's JSON shape — it always binds
        // exactly one param, even for a non-string pattern.
        for pat in [json!("x%"), json!(""), json!(42), Value::Null, json!(["a"])] {
            for ci in [false, true] {
                let f = Filter::Like {
                    field: "f".into(),
                    pattern: pat.clone(),
                    ci,
                };
                let (sql, n) = lowered(&f);
                assert_eq!(n, 1, "pattern {pat} ci {ci}");
                assert_eq!(sql.matches('?').count(), 1);
            }
        }
    }

    // ---- Between: shape, value types, low==high -----------------------------

    #[test]
    fn between_binds_low_then_high_in_order() {
        let f = Filter::Between {
            field: "age".into(),
            low: json!(18),
            high: json!(65),
        };
        let (sql, n) = lowered(&f);
        assert_eq!(sql, "\"age\" BETWEEN ? AND ?");
        assert_eq!(n, 2);
        let mut sink = TestSink::default();
        lower_filter(&f, &mut sink).unwrap();
        assert_eq!(sink.params, vec![json!(18), json!(65)]);
    }

    #[test]
    fn between_over_value_types_always_binds_two() {
        for (lo, hi) in [
            (Value::Null, Value::Null),
            (json!(0.0), json!(1.0e9)),
            (json!("a"), json!("z")),
            (json!(i64::MIN), json!(i64::MAX)),
            (json!([1]), json!({ "k": 2 })),
            (json!(5), json!(5)), // low == high is still two params
        ] {
            let f = Filter::Between {
                field: "x".into(),
                low: lo.clone(),
                high: hi.clone(),
            };
            let (sql, n) = lowered(&f);
            assert_eq!(n, 2, "between {lo}..{hi}");
            assert_eq!(sql.matches('?').count(), 2);
        }
    }

    // ---- IsNull both directions, binds nothing ------------------------------

    #[test]
    fn is_null_both_directions_bind_no_params() {
        let yes = Filter::IsNull {
            field: "a".into(),
            negate: false,
        };
        let no = Filter::IsNull {
            field: "a".into(),
            negate: true,
        };
        assert_eq!(lowered(&yes), ("\"a\" IS NULL".to_string(), 0));
        assert_eq!(lowered(&no), ("\"a\" IS NOT NULL".to_string(), 0));
    }

    // ---- Not: single, double, over each leaf --------------------------------

    #[test]
    fn not_wraps_inner_and_preserves_param_count() {
        let inner = cmp("a", CmpOp::Eq, json!(1));
        let f = Filter::Not(Box::new(inner));
        assert_eq!(lowered(&f), ("NOT (\"a\" = ?)".to_string(), 1));
    }

    #[test]
    fn double_not_nests_twice() {
        let f = Filter::Not(Box::new(Filter::Not(Box::new(cmp(
            "a",
            CmpOp::Gt,
            json!(0),
        )))));
        assert_eq!(lowered(&f), ("NOT (NOT (\"a\" > ?))".to_string(), 1));
    }

    #[test]
    fn not_over_in_empty_wraps_the_false_constant() {
        // Not's map only fires on Some; In([]) is Some("0 = 1").
        let f = Filter::Not(Box::new(Filter::In {
            field: "a".into(),
            values: vec![],
        }));
        assert_eq!(lowered(&f), ("NOT (0 = 1)".to_string(), 0));
    }

    #[test]
    fn not_of_empty_and_is_none_so_yields_empty_string() {
        // And([]) lowers to None; Not maps over None → None → "".
        let f = Filter::Not(Box::new(Filter::And(vec![])));
        assert_eq!(lowered(&f), (String::new(), 0));
    }

    // ---- And / Or: empty, singleton, many, nested-empty pruning -------------

    #[test]
    fn and_empty_is_none_or_empty_is_false_constant() {
        assert_eq!(lowered(&Filter::And(vec![])), (String::new(), 0));
        assert_eq!(lowered(&Filter::Or(vec![])), ("0 = 1".to_string(), 0));
    }

    #[test]
    fn and_drops_none_children_keeps_real_ones() {
        // An inner And([]) contributes None and is skipped, not joined as empty.
        let f = Filter::And(vec![
            Filter::And(vec![]),
            cmp("a", CmpOp::Eq, json!(1)),
            Filter::And(vec![]),
            cmp("b", CmpOp::Ne, json!(2)),
        ]);
        let (sql, n) = lowered(&f);
        assert_eq!(sql, "\"a\" = ? AND \"b\" <> ?");
        assert_eq!(n, 2);
    }

    #[test]
    fn and_of_only_none_children_is_none() {
        let f = Filter::And(vec![Filter::And(vec![]), Filter::And(vec![])]);
        assert_eq!(lowered(&f), (String::new(), 0));
    }

    #[test]
    fn or_parenthesizes_each_branch() {
        let f = Filter::Or(vec![
            cmp("a", CmpOp::Eq, json!(1)),
            cmp("b", CmpOp::Lt, json!(2)),
            cmp("c", CmpOp::Gte, json!(3)),
        ]);
        let (sql, n) = lowered(&f);
        assert_eq!(sql, "(\"a\" = ?) OR (\"b\" < ?) OR (\"c\" >= ?)");
        assert_eq!(n, 3);
    }

    #[test]
    fn or_skips_none_children_then_falls_to_false_if_all_none() {
        // Or over children that lower to None (And([])) → no branches → "0 = 1".
        let f = Filter::Or(vec![Filter::And(vec![]), Filter::And(vec![])]);
        assert_eq!(lowered(&f), ("0 = 1".to_string(), 0));
    }

    #[test]
    fn or_single_real_branch_among_none_keeps_just_it() {
        let f = Filter::Or(vec![
            Filter::And(vec![]),
            cmp("a", CmpOp::Eq, json!(1)),
        ]);
        assert_eq!(lowered(&f), ("(\"a\" = ?)".to_string(), 1));
    }

    // ---- Deep nesting: stress recursion + param numbering -------------------

    #[test]
    fn deeply_nested_mixed_tree_keeps_placeholders_balanced() {
        let f = Filter::And(vec![
            cmp("a", CmpOp::Eq, json!(1)),
            Filter::Or(vec![
                cmp("b", CmpOp::Lt, json!(2)),
                Filter::Not(Box::new(Filter::Between {
                    field: "c".into(),
                    low: json!(3),
                    high: json!(4),
                })),
                Filter::In {
                    field: "d".into(),
                    values: vec![json!(5), json!(6), json!(7)],
                },
            ]),
            Filter::Like {
                field: "e".into(),
                pattern: json!("x%"),
                ci: true,
            },
        ]);
        let (sql, n) = lowered(&f);
        // 1 (a) + 1 (b) + 2 (between) + 3 (in) + 1 (like) = 8.
        assert_eq!(n, 8);
        assert_eq!(sql.matches('?').count(), 8);
    }

    #[test]
    fn left_leaning_not_chain_does_not_panic() {
        // 64-deep Not chain over a single Cmp — recursion must not overflow on
        // the kind of tree the parser's recursion limit permits.
        let mut f = cmp("a", CmpOp::Eq, json!(1));
        for _ in 0..64 {
            f = Filter::Not(Box::new(f));
        }
        let (sql, n) = lowered(&f);
        assert_eq!(n, 1);
        assert_eq!(sql.matches("NOT (").count(), 64);
    }

    // ---- quote_ident is applied to EVERY field-bearing arm ------------------

    #[test]
    fn quote_ident_is_applied_to_every_arm_field() {
        // A sentinel sink that wraps idents distinctively so we can confirm the
        // lowerer routes every field through quote_ident (never raw).
        #[derive(Default)]
        struct MarkSink {
            n: usize,
        }
        impl SqlParamSink for MarkSink {
            fn bind(&mut self, _v: &Value) -> String {
                self.n += 1;
                "?".to_string()
            }
            fn quote_ident(&self, name: &str) -> DataPlaneResult<String> {
                Ok(format!("<<{name}>>"))
            }
        }
        let arms: Vec<Filter> = vec![
            cmp("f1", CmpOp::Eq, json!(1)),
            Filter::In {
                field: "f2".into(),
                values: vec![json!(1)],
            },
            Filter::Like {
                field: "f3".into(),
                pattern: json!("a"),
                ci: false,
            },
            Filter::Like {
                field: "f4".into(),
                pattern: json!("a"),
                ci: true,
            },
            Filter::Between {
                field: "f5".into(),
                low: json!(1),
                high: json!(2),
            },
            Filter::IsNull {
                field: "f6".into(),
                negate: false,
            },
        ];
        for (i, f) in arms.iter().enumerate() {
            let mut sink = MarkSink::default();
            let sql = lower_filter(f, &mut sink).unwrap().unwrap();
            let field = format!("f{}", i + 1);
            assert!(
                sql.contains(&format!("<<{field}>>")),
                "arm {i} ({sql}) must quote its field via quote_ident"
            );
        }
    }

    #[test]
    fn quote_ident_failure_propagates_from_any_arm() {
        // A sink whose quote_ident always fails proves the `?` propagation in
        // every arm (the lowerer returns Err, never panics or emits raw).
        #[derive(Default)]
        struct FailSink;
        impl SqlParamSink for FailSink {
            fn bind(&mut self, _v: &Value) -> String {
                "?".to_string()
            }
            fn quote_ident(&self, name: &str) -> DataPlaneResult<String> {
                Err(DataPlaneError::InvalidIdentifier {
                    value: name.to_string(),
                })
            }
        }
        let arms: Vec<Filter> = vec![
            cmp("a", CmpOp::Eq, json!(1)),
            Filter::In {
                field: "a".into(),
                values: vec![json!(1)],
            },
            Filter::Like {
                field: "a".into(),
                pattern: json!("x"),
                ci: true,
            },
            Filter::Between {
                field: "a".into(),
                low: json!(1),
                high: json!(2),
            },
            Filter::IsNull {
                field: "a".into(),
                negate: true,
            },
        ];
        for f in &arms {
            let mut sink = FailSink;
            assert!(
                matches!(
                    lower_filter(f, &mut sink),
                    Err(DataPlaneError::InvalidIdentifier { .. })
                ),
                "arm {f:?} should propagate the quote_ident error"
            );
        }
        // Even an empty In validates (quotes) its field BEFORE the empty-list
        // short-circuit, so a bad field name is still rejected — the quoted
        // ident is just discarded when the list is empty (it renders "0 = 1").
        let mut sink = FailSink;
        let empty_in = Filter::In {
            field: "a".into(),
            values: vec![],
        };
        assert!(matches!(
            lower_filter(&empty_in, &mut sink),
            Err(DataPlaneError::InvalidIdentifier { .. })
        ));
        // With a permissive sink, the empty In renders "0 = 1" and the quoted
        // field is NOT emitted.
        let mut ok_sink = TestSink::default();
        let rendered = lower_filter(&empty_in, &mut ok_sink).unwrap().unwrap();
        assert_eq!(rendered, "0 = 1");
        assert!(!rendered.contains("\"a\""), "empty In discards its quoted field");
    }

    // ---- Determinism: same filter lowers identically twice ------------------

    #[test]
    fn lowering_is_deterministic_across_repeats() {
        for f in [
            cmp("a", CmpOp::Eq, json!(1)),
            Filter::Or(vec![
                cmp("a", CmpOp::Eq, json!(1)),
                cmp("b", CmpOp::Ne, json!(2)),
            ]),
            Filter::And(vec![
                Filter::Between {
                    field: "n".into(),
                    low: json!(1),
                    high: json!(9),
                },
                Filter::In {
                    field: "s".into(),
                    values: vec![json!("a"), json!("b")],
                },
            ]),
        ] {
            let first = lowered(&f);
            let second = lowered(&f);
            assert_eq!(first, second, "filter {f:?} must lower identically twice");
        }
    }

    // ---- The @P{n} numbered sink mirrors the invariant ----------------------

    #[test]
    fn numbered_sink_emits_sequential_placeholders() {
        let f = Filter::And(vec![
            cmp("a", CmpOp::Eq, json!(1)),
            cmp("b", CmpOp::Ne, json!(2)),
        ]);
        let (sql, n) = lowered_numbered(&f);
        assert_eq!(sql, "[a] = @P1 AND [b] <> @P2");
        assert_eq!(n, 2);
    }

    #[test]
    fn numbered_sink_in_clause_numbers_each_element() {
        let f = Filter::In {
            field: "x".into(),
            values: vec![json!(1), json!(2), json!(3)],
        };
        let (sql, n) = lowered_numbered(&f);
        assert_eq!(sql, "[x] IN (@P1, @P2, @P3)");
        assert_eq!(n, 3);
    }

    #[test]
    fn numbered_sink_between_and_like_number_in_bind_order() {
        let between = Filter::Between {
            field: "a".into(),
            low: json!(1),
            high: json!(2),
        };
        assert_eq!(lowered_numbered(&between).0, "[a] BETWEEN @P1 AND @P2");
        let like = Filter::Like {
            field: "n".into(),
            pattern: json!("p%"),
            ci: true,
        };
        assert_eq!(lowered_numbered(&like).0, "LOWER([n]) LIKE LOWER(@P1)");
    }

    proptest! {
        /// The numbered (`@P{n}`) dialect upholds the same invariant: distinct
        /// emitted placeholders == bound params == the highest index n.
        #[test]
        fn numbered_placeholder_count_equals_param_count(f in arb_filter()) {
            let (sql, params) = lowered_numbered(&f);
            prop_assert_eq!(count_at_p(&sql), params);
        }

        /// Determinism, fuzzed: lowering any tree twice gives the same SQL and
        /// the same param count (no hidden global/ordering state).
        #[test]
        fn lowering_is_deterministic_fuzz(f in arb_filter()) {
            let a = lowered(&f);
            let b = lowered(&f);
            prop_assert_eq!(a, b);
        }

        /// No-panic + structural invariant: for any generated tree the positional
        /// (`?`) and numbered (`@P{n}`) dialects record the SAME number of params
        /// (the dialect changes only the placeholder text, not the bind count).
        #[test]
        fn both_dialects_bind_the_same_param_count(f in arb_filter()) {
            let (_, pos) = lowered(&f);
            let (_, num) = lowered_numbered(&f);
            prop_assert_eq!(pos, num);
        }
    }
}
