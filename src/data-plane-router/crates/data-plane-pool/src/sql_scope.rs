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
}
