//! The `Pred` filter compiler (JSON filter → Postgres boolean with constant
//! folding) and the ORDER BY builder. Shared by the read and mutating paths.

use super::convert::json_param;
use super::BoxedParam;
use crate::ident::quote_ident;
use data_plane_core::{CmpOp, DataPlaneError, DataPlaneResult, Filter};
use serde_json::Value;

/// A compiled predicate, with **constant folding** so a filter that reduces to a
/// tautology (`NOT (FALSE)`, `a OR TRUE`) is recognised as [`Pred::Unconstrained`]
/// and refused by the mutation guards — never silently turned into `WHERE TRUE`.
/// Constants never carry bound params (the params of a discarded branch are
/// rolled back), so placeholder numbering stays correct.
#[derive(Debug)]
pub(super) enum Pred {
    /// Constrains nothing (logical TRUE) → rendered as no `WHERE` clause, so
    /// update/delete's empty-filter guard fires.
    Unconstrained,
    /// Matches no rows (logical FALSE) → rendered as `FALSE`. A real predicate.
    AlwaysFalse,
    /// A concrete SQL boolean expression referencing bound params.
    Sql(String),
}

/// Wraps [`compile_filter`] into a ` WHERE …` clause. A tautology folds to
/// `Unconstrained` → `""`, so the no-full-table guard on update/delete fires;
/// an explicit match-nothing (`$or:[]`, `$in:[]`) renders ` WHERE FALSE`.
pub(super) fn build_where(
    filter: Option<&Value>,
    params: &mut Vec<BoxedParam>,
) -> DataPlaneResult<String> {
    Ok(match compile_filter(filter, params)? {
        Pred::Unconstrained => String::new(),
        Pred::AlwaysFalse => " WHERE FALSE".to_string(),
        // Parenthesize the whole client predicate so a caller that appends an
        // owner predicate (`{where_sql} AND owner_id = $n` in update/delete) ANDs
        // it as one unit — a top-level `$or` must not leave a branch unscoped.
        Pred::Sql(clause) => format!(" WHERE ({clause})"),
    })
}

/// Parses the JSON filter into the shared engine-neutral [`Filter`] tree (the
/// single grammar + validation, in `data-plane-core`) and lowers it to a
/// Postgres boolean [`Pred`]. `None` constrains nothing. A thin wrapper so
/// `build_where` and the unit tests share one entry point.
pub(super) fn compile_filter(
    filter: Option<&Value>,
    params: &mut Vec<BoxedParam>,
) -> DataPlaneResult<Pred> {
    match filter {
        Some(value) => lower_pg(&Filter::parse(value)?, params),
        None => Ok(Pred::Unconstrained),
    }
}

/// Joins AND-parts into a [`Pred`]; an empty set constrains nothing.
fn and_join(parts: Vec<String>) -> Pred {
    if parts.is_empty() {
        Pred::Unconstrained
    } else {
        Pred::Sql(parts.join(" AND "))
    }
}

/// `NOT` with constant folding: `NOT TRUE = FALSE`, `NOT FALSE = TRUE`.
fn negate(p: Pred) -> Pred {
    match p {
        Pred::Unconstrained => Pred::AlwaysFalse,
        Pred::AlwaysFalse => Pred::Unconstrained,
        Pred::Sql(s) => Pred::Sql(format!("NOT ({s})")),
    }
}

/// Lowers an engine-neutral [`Filter`] (already parsed + validated by
/// `data-plane-core`) to a Postgres boolean [`Pred`], pushing every value as a
/// bound `$n` parameter. Identifiers via `quote_ident`; comparison symbols are
/// fixed — values are never interpolated. The [`Pred`] folding gives the mutation
/// guard (a tautology → `Unconstrained` → empty `WHERE` → refused).
// ponytail: this 46-line lowering is one match over the `Filter` variants —
// irreducible data (one arm per operator), each arm already minimal.
fn lower_pg(filter: &Filter, params: &mut Vec<BoxedParam>) -> DataPlaneResult<Pred> {
    Ok(match filter {
        Filter::And(parts) => lower_and(parts, params)?,
        Filter::Or(parts) => lower_or(parts, params)?,
        Filter::Not(inner) => negate(lower_pg(inner, params)?),
        Filter::Cmp { field, op, value } => {
            let ident = quote_ident(field)?;
            params.push(json_param(value));
            Pred::Sql(format!("{ident} {} ${}", cmp_sql(*op), params.len()))
        }
        Filter::In { field, values } => {
            let ident = quote_ident(field)?;
            if values.is_empty() {
                Pred::AlwaysFalse // `x IN ()` matches nothing
            } else {
                let mut ph = Vec::with_capacity(values.len());
                for v in values {
                    params.push(json_param(v));
                    ph.push(format!("${}", params.len()));
                }
                Pred::Sql(format!("{ident} IN ({})", ph.join(", ")))
            }
        }
        Filter::Like { field, pattern, ci } => {
            let ident = quote_ident(field)?;
            params.push(json_param(pattern));
            Pred::Sql(format!(
                "{ident} {} ${}",
                if *ci { "ILIKE" } else { "LIKE" },
                params.len()
            ))
        }
        Filter::Between { field, low, high } => {
            let ident = quote_ident(field)?;
            params.push(json_param(low));
            let lo = params.len();
            params.push(json_param(high));
            let hi = params.len();
            Pred::Sql(format!("{ident} BETWEEN ${lo} AND ${hi}"))
        }
        Filter::IsNull { field, negate } => {
            let ident = quote_ident(field)?;
            Pred::Sql(format!("{ident} IS {}NULL", if *negate { "NOT " } else { "" }))
        }
    })
}

/// AND-combine: fold `AlwaysFalse` (rolling back its params) and drop
/// `Unconstrained`; an empty/all-true set constrains nothing.
fn lower_and(parts: &[Filter], params: &mut Vec<BoxedParam>) -> DataPlaneResult<Pred> {
    let start = params.len();
    let mut sql_parts: Vec<String> = Vec::with_capacity(parts.len());
    for part in parts {
        match lower_pg(part, params)? {
            Pred::AlwaysFalse => {
                params.truncate(start);
                return Ok(Pred::AlwaysFalse);
            }
            Pred::Unconstrained => {}
            Pred::Sql(s) => sql_parts.push(s),
        }
    }
    Ok(and_join(sql_parts))
}

/// OR-combine: fold `Unconstrained` to TRUE (rolling back params) and drop
/// `AlwaysFalse`; an empty/all-false `$or` matches nothing.
fn lower_or(parts: &[Filter], params: &mut Vec<BoxedParam>) -> DataPlaneResult<Pred> {
    let start = params.len();
    let mut sql_parts: Vec<String> = Vec::with_capacity(parts.len());
    for part in parts {
        match lower_pg(part, params)? {
            Pred::Sql(s) => sql_parts.push(s),
            Pred::AlwaysFalse => {} // OR FALSE = identity
            Pred::Unconstrained => {
                params.truncate(start);
                return Ok(Pred::Unconstrained); // OR TRUE = TRUE
            }
        }
    }
    if sql_parts.is_empty() {
        return Ok(Pred::AlwaysFalse);
    }
    let ored: Vec<String> = sql_parts.into_iter().map(|p| format!("({p})")).collect();
    Ok(Pred::Sql(ored.join(" OR ")))
}

pub(super) fn cmp_sql(op: CmpOp) -> &'static str {
    match op {
        CmpOp::Eq => "=",
        CmpOp::Ne => "<>",
        CmpOp::Lt => "<",
        CmpOp::Lte => "<=",
        CmpOp::Gt => ">",
        CmpOp::Gte => ">=",
    }
}

/// Compiles the `sort` map (`{column: "asc"|"desc"}`) into ` ORDER BY …`, or
/// `""` when absent. Columns via `quote_ident`; direction is an allowlist. The
/// `BTreeMap` iterates in key order, so the clause is deterministic.
pub(super) fn build_order_by(
    sort: Option<&std::collections::BTreeMap<String, String>>,
) -> DataPlaneResult<String> {
    let Some(sort) = sort.filter(|s| !s.is_empty()) else {
        return Ok(String::new());
    };
    let mut parts = Vec::with_capacity(sort.len());
    for (col, dir) in sort {
        let ident = quote_ident(col)?;
        let dir_sql = match dir.to_ascii_lowercase().as_str() {
            "asc" => "ASC",
            "desc" => "DESC",
            other => {
                return Err(DataPlaneError::InvalidRequest {
                    message: format!("invalid sort direction '{other}' (use 'asc' or 'desc')"),
                })
            }
        };
        parts.push(format!("{ident} {dir_sql}"));
    }
    Ok(format!(" ORDER BY {}", parts.join(", ")))
}

#[cfg(test)]
mod tests {
    use super::super::crud_build::{build_delete_sql, build_update_sql};
    use super::*;
    use serde_json::json;

    fn obj(v: Value) -> serde_json::Map<String, Value> {
        match v {
            Value::Object(m) => m,
            _ => panic!("expected a JSON object"),
        }
    }

    // --- filter compiler (rich reads): operators, boolean, injection-safety ---

    /// Compile a filter and return (sql_without_where, n_params). `Unconstrained`
    /// renders `""`, `AlwaysFalse` renders `FALSE`.
    fn wsql(filter: Value) -> (String, usize) {
        let mut params: Vec<BoxedParam> = Vec::new();
        let sql = match compile_filter(Some(&filter), &mut params).unwrap() {
            Pred::Unconstrained => String::new(),
            Pred::AlwaysFalse => "FALSE".to_string(),
            Pred::Sql(s) => s,
        };
        (sql, params.len())
    }

    #[test]
    fn filter_equality_is_backward_compatible_and_sorted() {
        // Legacy `{col: scalar}` map still compiles to sorted equality predicates.
        let (sql, n) = wsql(json!({ "b": 2, "a": 1 }));
        assert_eq!(sql, "\"a\" = $1 AND \"b\" = $2", "{sql}");
        assert_eq!(n, 2);
    }

    #[test]
    fn filter_empty_contributes_no_predicate() {
        // `{}`, absent, and empty `$and` constrain nothing → render to "" so the
        // update/delete empty-filter guard fires.
        assert_eq!(wsql(json!({})).0, "");
        assert_eq!(wsql(json!({ "$and": [] })).0, "");
        let mut p: Vec<BoxedParam> = Vec::new();
        assert!(matches!(
            compile_filter(None, &mut p).unwrap(),
            Pred::Unconstrained
        ));
    }

    #[test]
    fn filter_tautology_folds_to_unconstrained_and_mutation_guard_refuses() {
        // THE data-loss fix: a filter that constant-folds to TRUE must be treated
        // as "no predicate" so update/delete refuse it, not run WHERE TRUE.
        assert_eq!(wsql(json!({ "$not": { "$or": [] } })).0, "", "NOT(FALSE) → unconstrained");
        assert_eq!(wsql(json!({ "$not": { "a": { "$in": [] } } })).0, "", "NOT(col IN ()) → unconstrained");
        assert_eq!(wsql(json!({ "$or": [{ "a": 1 }, { "$not": { "$or": [] } }] })).0, "", "x OR TRUE → unconstrained");
        // the discarded branch's param is rolled back (no orphan placeholders).
        assert_eq!(wsql(json!({ "$or": [{ "a": 1 }, { "$not": { "$or": [] } }] })).1, 0);
        // and the guard actually refuses it on a real mutation:
        let data = obj(json!({ "name": "x" }));
        for taut in [json!({ "$not": { "$or": [] } }), json!({ "$or": [{ "a": 1 }, { "$not": { "$or": [] } }] })] {
            let e = build_update_sql("\"t\"", &data, Some(&taut), Some("u"), true).unwrap_err();
            assert!(matches!(e, DataPlaneError::InvalidRequest { .. }), "update {taut}: {e:?}");
            let e = build_delete_sql("\"t\"", Some(&taut), Some("u"), true).unwrap_err();
            assert!(matches!(e, DataPlaneError::InvalidRequest { .. }), "delete {taut}: {e:?}");
        }
        // an explicit match-nothing is NOT a tautology — it's a safe predicate.
        assert_eq!(wsql(json!({ "$or": [] })).0, "FALSE");
        assert_eq!(wsql(json!({ "$not": {} })).0, "FALSE", "NOT(everything) = nothing");
    }

    #[test]
    fn filter_comparison_operators() {
        assert_eq!(wsql(json!({ "age": { "$gte": 18 } })).0, "\"age\" >= $1");
        assert_eq!(wsql(json!({ "age": { "$ne": 0 } })).0, "\"age\" <> $1");
        // multiple operators on one column AND together, operator keys sorted.
        let (sql, n) = wsql(json!({ "age": { "$lt": 65, "$gte": 18 } }));
        assert_eq!(sql, "\"age\" >= $1 AND \"age\" < $2", "{sql}");
        assert_eq!(n, 2);
    }

    #[test]
    fn filter_in_between_null_like() {
        assert_eq!(wsql(json!({ "s": { "$in": ["a", "b"] } })).0, "\"s\" IN ($1, $2)");
        assert_eq!(wsql(json!({ "s": { "$in": [] } })).0, "FALSE"); // matches nothing
        assert_eq!(wsql(json!({ "age": { "$between": [18, 65] } })).0, "\"age\" BETWEEN $1 AND $2");
        assert_eq!(wsql(json!({ "x": { "$null": true } })).0, "\"x\" IS NULL");
        assert_eq!(wsql(json!({ "x": { "$null": false } })).0, "\"x\" IS NOT NULL");
        assert_eq!(wsql(json!({ "n": { "$ilike": "%a%" } })).0, "\"n\" ILIKE $1");
    }

    #[test]
    fn filter_all_binary_operators_map_to_correct_sql() {
        for (op, sym) in [
            ("$eq", "="), ("$ne", "<>"), ("$lt", "<"), ("$lte", "<="),
            ("$gt", ">"), ("$gte", ">="), ("$like", "LIKE"), ("$ilike", "ILIKE"),
        ] {
            let (sql, n) = wsql(json!({ "c": { op: 1 } }));
            assert_eq!(sql, format!("\"c\" {sym} $1"), "operator {op}");
            assert_eq!(n, 1, "operator {op} binds one param");
        }
    }

    #[test]
    fn filter_nested_boolean_recursion() {
        // $or containing a nested $and, and $not of a compound filter.
        let (sql, n) = wsql(json!({ "$or": [{ "$and": [{ "a": 1 }, { "b": 2 }] }, { "c": 3 }] }));
        assert_eq!(sql, "(\"a\" = $1 AND \"b\" = $2) OR (\"c\" = $3)", "{sql}");
        assert_eq!(n, 3);
        assert_eq!(
            wsql(json!({ "$not": { "$or": [{ "a": 1 }, { "b": 2 }] } })).0,
            "NOT ((\"a\" = $1) OR (\"b\" = $2))"
        );
    }

    #[test]
    fn filter_in_list_length_is_capped() {
        let big: Vec<i64> = (0..=(data_plane_core::filter::MAX_IN_LEN as i64)).collect();
        let mut p: Vec<BoxedParam> = Vec::new();
        let e = compile_filter(Some(&json!({ "a": { "$in": big } })), &mut p).unwrap_err();
        assert!(matches!(e, DataPlaneError::InvalidRequest { .. }), "{e:?}");
    }

    #[test]
    fn filter_boolean_composition() {
        let (sql, n) = wsql(json!({ "$or": [{ "a": 1 }, { "b": 2 }] }));
        assert_eq!(sql, "(\"a\" = $1) OR (\"b\" = $2)", "{sql}");
        assert_eq!(n, 2);
        assert_eq!(wsql(json!({ "$not": { "a": 1 } })).0, "NOT (\"a\" = $1)");
        // empty `$or` matches nothing.
        assert_eq!(wsql(json!({ "$or": [] })).0, "FALSE");
        // mixed: column predicate AND a nested $or ('$or' sorts before 'age').
        let (sql, _) = wsql(json!({ "age": { "$gte": 18 }, "$or": [{ "a": 1 }, { "b": 2 }] }));
        assert_eq!(sql, "(\"a\" = $1) OR (\"b\" = $2) AND \"age\" >= $3", "{sql}");
    }

    #[test]
    fn filter_rejects_injection_and_unknown_operators() {
        let mut p: Vec<BoxedParam> = Vec::new();
        // column name injection → InvalidIdentifier (via quote_ident)
        let e = compile_filter(Some(&json!({ "a;DROP TABLE x;--": 1 })), &mut p).unwrap_err();
        assert!(matches!(e, DataPlaneError::InvalidIdentifier { .. }), "{e:?}");
        // injection inside an operator column
        let e = compile_filter(Some(&json!({ "x\"--": { "$gt": 1 } })), &mut p).unwrap_err();
        assert!(matches!(e, DataPlaneError::InvalidIdentifier { .. }), "{e:?}");
        // unknown operator → InvalidRequest (never interpolated)
        let e = compile_filter(Some(&json!({ "a": { "$drop": 1 } })), &mut p).unwrap_err();
        assert!(matches!(e, DataPlaneError::InvalidRequest { .. }), "{e:?}");
        // malformed $between / $in / $null
        assert!(compile_filter(Some(&json!({ "a": { "$between": [1] } })), &mut p).is_err());
        assert!(compile_filter(Some(&json!({ "a": { "$in": 5 } })), &mut p).is_err());
        assert!(compile_filter(Some(&json!({ "a": { "$null": 1 } })), &mut p).is_err());
    }

    #[test]
    fn order_by_is_quoted_directioned_and_injection_safe() {
        use std::collections::BTreeMap;
        let mut s = BTreeMap::new();
        s.insert("name".to_string(), "asc".to_string());
        s.insert("age".to_string(), "DESC".to_string()); // case-insensitive
        // BTreeMap key order → age before name.
        assert_eq!(build_order_by(Some(&s)).unwrap(), " ORDER BY \"age\" DESC, \"name\" ASC");
        assert_eq!(build_order_by(None).unwrap(), "");

        let mut bad_dir = BTreeMap::new();
        bad_dir.insert("a".to_string(), "sideways".to_string());
        assert!(matches!(
            build_order_by(Some(&bad_dir)).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));

        let mut bad_col = BTreeMap::new();
        bad_col.insert("a; DROP".to_string(), "asc".to_string());
        assert!(matches!(
            build_order_by(Some(&bad_col)).unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
    }

    #[test]
    fn cmp_sql_maps_every_operator_distinctly() {
        let pairs = [
            (CmpOp::Eq, "="),
            (CmpOp::Ne, "<>"),
            (CmpOp::Lt, "<"),
            (CmpOp::Lte, "<="),
            (CmpOp::Gt, ">"),
            (CmpOp::Gte, ">="),
        ];
        let mut seen = std::collections::HashSet::new();
        for (op, sym) in pairs {
            assert_eq!(cmp_sql(op), sym, "op {op:?}");
            assert!(seen.insert(sym), "duplicate symbol {sym}");
        }
    }

    // ── compile_filter / lower_pg: value-type coverage + edge predicates ──────

    #[test]
    fn filter_value_types_each_bind_one_param() {
        // Every scalar/composite value type binds exactly one $n in an equality.
        for v in [
            json!(null),
            json!(true),
            json!(0),
            json!(i64::MAX),
            json!(3.14),
            json!(""),
            json!("str"),
            json!([1, 2]),
            json!({ "k": 1 }),
        ] {
            let (sql, n) = wsql(json!({ "c": { "$eq": v.clone() } }));
            assert_eq!(sql, "\"c\" = $1", "value {v}");
            assert_eq!(n, 1, "value {v}");
        }
    }

    #[test]
    fn filter_in_param_count_follows_list_length() {
        for len in [1usize, 2, 5, 50, 1000] {
            let arr: Vec<Value> = (0..len).map(|i| json!(i as i64)).collect();
            let (sql, n) = wsql(json!({ "c": { "$in": arr } }));
            assert_eq!(n, len, "len {len}");
            assert!(sql.starts_with("\"c\" IN ("));
        }
    }

    #[test]
    fn filter_in_at_limit_compiles_over_limit_rejected() {
        // MAX_IN_LEN is enforced by Filter::parse; at the limit compiles, +1 errors.
        let at_limit: Vec<i64> = (0..1000).collect();
        assert_eq!(wsql(json!({ "c": { "$in": at_limit } })).1, 1000);
        let over: Vec<i64> = (0..1001).collect();
        let mut p: Vec<BoxedParam> = Vec::new();
        assert!(compile_filter(Some(&json!({ "c": { "$in": over } })), &mut p).is_err());
    }

    #[test]
    fn filter_between_binds_low_high_in_order() {
        let (sql, n) = wsql(json!({ "ts": { "$between": ["2020-01-01", "2020-12-31"] } }));
        assert_eq!(sql, "\"ts\" BETWEEN $1 AND $2");
        assert_eq!(n, 2);
    }

    #[test]
    fn filter_is_null_binds_no_params() {
        assert_eq!(wsql(json!({ "x": { "$null": true } })), ("\"x\" IS NULL".to_string(), 0));
        assert_eq!(wsql(json!({ "x": { "$null": false } })), ("\"x\" IS NOT NULL".to_string(), 0));
    }

    #[test]
    fn filter_schema_qualified_field_is_quoted_both_segments() {
        // quote_ident accepts a single schema qualifier; lower_pg routes through it.
        assert_eq!(
            wsql(json!({ "public.col": { "$gte": 1 } })).0,
            "\"public\".\"col\" >= $1"
        );
    }

    #[test]
    fn filter_invalid_field_name_is_rejected_by_quote_ident() {
        // A field that survives Filter::parse (non-empty, not $-prefixed) but
        // fails the SQL identifier allowlist is rejected at lowering time.
        let mut p: Vec<BoxedParam> = Vec::new();
        for bad_field in ["a-b", "a b", "a;b", "1col", "a\"b"] {
            let res = compile_filter(Some(&json!({ bad_field: 1 })), &mut p);
            assert!(
                matches!(res, Err(DataPlaneError::InvalidIdentifier { .. })),
                "field {bad_field:?} should be rejected"
            );
        }
    }

    #[test]
    fn filter_deeply_nested_keeps_placeholder_numbering_monotonic() {
        // $and of [$or, between, in] — params number 1..N strictly increasing.
        let (sql, n) = wsql(json!({
            "$and": [
                { "$or": [ { "a": 1 }, { "b": { "$lt": 2 } } ] },
                { "c": { "$between": [3, 4] } },
                { "d": { "$in": [5, 6, 7] } }
            ]
        }));
        // 1(a) + 1(b) + 2(between) + 3(in) = 7.
        assert_eq!(n, 7);
        // Placeholders $1..$7 all present, none missing/duplicated.
        for i in 1..=7 {
            assert!(sql.contains(&format!("${i}")), "missing ${i} in {sql}");
        }
        assert!(!sql.contains("$8"));
    }

    #[test]
    fn filter_or_with_tautology_branch_rolls_back_params() {
        // `x OR TRUE` folds to Unconstrained and the discarded branch's bound
        // param is truncated — no orphan $n left behind.
        let (sql, n) = wsql(json!({ "$or": [ { "a": 1 }, { "$not": { "$or": [] } } ] }));
        assert_eq!(sql, "", "x OR TRUE → unconstrained");
        assert_eq!(n, 0, "the a=1 param is rolled back");
    }

    #[test]
    fn filter_and_with_contradiction_short_circuits_to_false() {
        // `a AND FALSE` → AlwaysFalse, the a-param truncated.
        let (sql, n) = wsql(json!({ "$and": [ { "a": 1 }, { "b": { "$in": [] } } ] }));
        assert_eq!(sql, "FALSE");
        assert_eq!(n, 0, "the a=1 param is rolled back on the FALSE short-circuit");
    }
}
