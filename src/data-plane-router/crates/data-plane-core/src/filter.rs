//! Engine-neutral filter AST (product-plan 02 — "one tree, many backends").
//!
//! The wire grammar (a MongoDB-style `$`-operator JSON) is parsed and validated
//! **once** into a [`Filter`] tree; each adapter then *lowers* that tree to its
//! own dialect (SQL `WHERE`, a Mongo BSON doc, Trino SQL). Because validation —
//! the operator allowlist and field-name rules — happens here, every adapter
//! that lowers a `Filter` inherits the same safety (no `$where` injection, no
//! silently-mis-evaluated operator) instead of re-parsing raw JSON its own way.
//!
//! Grammar:
//! - `{col: scalar}` → equality (`Cmp Eq`)
//! - `{col: {"$op": v}}` → operator predicate: `$eq $ne $lt $lte $gt $gte`
//!   (→ [`Cmp`]), `$like`/`$ilike` (→ [`Like`]), `$in` (→ [`In`]),
//!   `$between` (→ [`Between`]), `$null` (→ [`IsNull`]); multiple ops on one
//!   column are AND-ed
//! - `{"$and": [..]}` / `{"$or": [..]}` / `{"$not": f}` → boolean composition
//!
//! An empty object is `And([])` (constrains nothing). Field names may not start
//! with `$` (operator-ambiguous); unknown operators are rejected with a 400.
//!
//! [`Cmp`]: Filter::Cmp
//! [`Like`]: Filter::Like
//! [`In`]: Filter::In
//! [`Between`]: Filter::Between
//! [`IsNull`]: Filter::IsNull

use crate::DataPlaneError;
use serde_json::Value;

/// Maximum elements in a single `$in` list — a defense-in-depth cap so a huge
/// array can't balloon the generated predicate / parameter count.
pub const MAX_IN_LEN: usize = 1000;

/// The result of constant-folding a [`Filter`] — whether it constrains nothing
/// (a tautology, e.g. `NOT (FALSE)`), matches nothing, or is a real predicate.
/// Used by mutation guards: an `AlwaysTrue` filter on update/delete is a full-
/// table operation and must be refused, exactly as an empty filter is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Folded {
    /// Constrains nothing (logical TRUE): empty `{}`, empty `$and`, `NOT(FALSE)`.
    AlwaysTrue,
    /// Matches no rows (logical FALSE): empty `$or`, empty `$in`, `NOT(TRUE)`.
    AlwaysFalse,
    /// A genuine predicate that constrains the row set.
    Constrained,
}

/// Engine-neutral scalar comparison operator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CmpOp {
    Eq,
    Ne,
    Lt,
    Lte,
    Gt,
    Gte,
}

/// A validated, engine-neutral predicate tree. Values stay as [`serde_json::Value`]
/// — each adapter binds them as parameters in its own driver's type.
#[derive(Debug, Clone, PartialEq)]
pub enum Filter {
    And(Vec<Filter>),
    Or(Vec<Filter>),
    Not(Box<Filter>),
    /// `field <op> value`
    Cmp { field: String, op: CmpOp, value: Value },
    /// `field IN (values…)` — empty list matches nothing
    In { field: String, values: Vec<Value> },
    /// SQL `LIKE` (`ci=false`) / case-insensitive (`ci=true`, → `ILIKE`/`LOWER`)
    Like { field: String, pattern: Value, ci: bool },
    /// `field BETWEEN low AND high`
    Between { field: String, low: Value, high: Value },
    /// `field IS NULL` (`negate=false`) / `IS NOT NULL` (`negate=true`)
    IsNull { field: String, negate: bool },
}

fn invalid(message: impl Into<String>) -> DataPlaneError {
    DataPlaneError::InvalidRequest {
        message: message.into(),
    }
}

/// A column/field name must be non-empty and must not start with `$` (which
/// would be ambiguous with an operator). Engine-specific character rules (e.g.
/// the SQL identifier allowlist) are enforced again when the adapter quotes it.
fn validate_field(field: &str) -> Result<(), DataPlaneError> {
    if field.is_empty() {
        return Err(invalid("filter field name must not be empty"));
    }
    if field.starts_with('$') {
        return Err(invalid(format!(
            "filter field name '{field}' must not start with '$'"
        )));
    }
    Ok(())
}

impl Filter {
    /// Parse and validate the JSON wire grammar into a [`Filter`] tree. Keys are
    /// processed in sorted order so the lowering is deterministic.
    pub fn parse(value: &Value) -> Result<Filter, DataPlaneError> {
        let Value::Object(map) = value else {
            return Err(invalid("filter must be a JSON object"));
        };
        let mut entries: Vec<(&str, &Value)> = map.iter().map(|(k, v)| (k.as_str(), v)).collect();
        entries.sort_by(|a, b| a.0.cmp(b.0));
        let mut parts = Vec::with_capacity(entries.len());
        for (key, val) in entries {
            let node = match key {
                "$and" => Filter::And(parse_array(val)?),
                "$or" => Filter::Or(parse_array(val)?),
                "$not" => Filter::Not(Box::new(Filter::parse(val)?)),
                col => parse_column(col, val)?,
            };
            parts.push(node);
        }
        // A single entry is itself; multiple entries are AND-ed.
        Ok(match parts.len() {
            1 => parts.pop().expect("len checked"),
            _ => Filter::And(parts),
        })
    }

    /// Constant-fold the tree to detect a tautology (`AlwaysTrue`) or a
    /// contradiction (`AlwaysFalse`). Adapters use this to refuse a full-table
    /// mutation (an `AlwaysTrue` filter on update/delete) instead of silently
    /// affecting every row — the same protection on every engine that lowers a
    /// `Filter`.
    #[must_use]
    pub fn fold(&self) -> Folded {
        match self {
            Filter::And(parts) => {
                if parts.iter().any(|p| p.fold() == Folded::AlwaysFalse) {
                    Folded::AlwaysFalse // AND with FALSE = FALSE
                } else if parts.iter().all(|p| p.fold() == Folded::AlwaysTrue) {
                    Folded::AlwaysTrue // empty AND, or all-true children
                } else {
                    Folded::Constrained
                }
            }
            Filter::Or(parts) => {
                if parts.iter().any(|p| p.fold() == Folded::AlwaysTrue) {
                    Folded::AlwaysTrue // OR with TRUE = TRUE
                } else if parts.is_empty()
                    || parts.iter().all(|p| p.fold() == Folded::AlwaysFalse)
                {
                    Folded::AlwaysFalse // empty OR, or all-false children
                } else {
                    Folded::Constrained
                }
            }
            Filter::Not(inner) => match inner.fold() {
                Folded::AlwaysTrue => Folded::AlwaysFalse,
                Folded::AlwaysFalse => Folded::AlwaysTrue,
                Folded::Constrained => Folded::Constrained,
            },
            Filter::In { values, .. } if values.is_empty() => Folded::AlwaysFalse,
            _ => Folded::Constrained,
        }
    }
}

fn parse_array(val: &Value) -> Result<Vec<Filter>, DataPlaneError> {
    let Value::Array(items) = val else {
        return Err(invalid("`$and`/`$or` expects an array of filters"));
    };
    items.iter().map(Filter::parse).collect()
}

fn parse_column(col: &str, val: &Value) -> Result<Filter, DataPlaneError> {
    validate_field(col)?;
    if let Value::Object(ops) = val {
        if ops.keys().any(|k| k.starts_with('$')) {
            let mut entries: Vec<(&str, &Value)> =
                ops.iter().map(|(k, v)| (k.as_str(), v)).collect();
            entries.sort_by(|a, b| a.0.cmp(b.0));
            let mut parts = Vec::with_capacity(entries.len());
            for (op, opval) in entries {
                parts.push(parse_operator(col, op, opval)?);
            }
            return Ok(match parts.len() {
                1 => parts.pop().expect("len checked"),
                _ => Filter::And(parts),
            });
        }
    }
    // Scalar or jsonb-literal equality.
    Ok(Filter::Cmp {
        field: col.to_string(),
        op: CmpOp::Eq,
        value: val.clone(),
    })
}

fn parse_operator(col: &str, op: &str, opval: &Value) -> Result<Filter, DataPlaneError> {
    let field = col.to_string();
    let cmp = |op: CmpOp| Filter::Cmp {
        field: field.clone(),
        op,
        value: opval.clone(),
    };
    Ok(match op {
        "$eq" => cmp(CmpOp::Eq),
        "$ne" => cmp(CmpOp::Ne),
        "$lt" => cmp(CmpOp::Lt),
        "$lte" => cmp(CmpOp::Lte),
        "$gt" => cmp(CmpOp::Gt),
        "$gte" => cmp(CmpOp::Gte),
        "$like" => Filter::Like {
            field,
            pattern: opval.clone(),
            ci: false,
        },
        "$ilike" => Filter::Like {
            field,
            pattern: opval.clone(),
            ci: true,
        },
        "$in" => {
            let Value::Array(items) = opval else {
                return Err(invalid("`$in` expects an array"));
            };
            if items.len() > MAX_IN_LEN {
                return Err(invalid(format!(
                    "`$in` list exceeds the {MAX_IN_LEN}-element limit"
                )));
            }
            Filter::In {
                field,
                values: items.clone(),
            }
        }
        "$between" => {
            let Value::Array(a) = opval else {
                return Err(invalid("`$between` expects `[low, high]`"));
            };
            if a.len() != 2 {
                return Err(invalid("`$between` expects exactly two values `[low, high]`"));
            }
            Filter::Between {
                field,
                low: a[0].clone(),
                high: a[1].clone(),
            }
        }
        "$null" => match opval {
            Value::Bool(b) => Filter::IsNull {
                field,
                negate: !b,
            },
            _ => return Err(invalid("`$null` expects a boolean")),
        },
        other => return Err(invalid(format!("unknown filter operator '{other}'"))),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_equality_and_sorts_into_and() {
        let f = Filter::parse(&json!({ "b": 2, "a": 1 })).unwrap();
        assert_eq!(
            f,
            Filter::And(vec![
                Filter::Cmp { field: "a".into(), op: CmpOp::Eq, value: json!(1) },
                Filter::Cmp { field: "b".into(), op: CmpOp::Eq, value: json!(2) },
            ])
        );
    }

    #[test]
    fn parses_all_operators() {
        assert!(matches!(
            Filter::parse(&json!({ "x": { "$gte": 1 } })).unwrap(),
            Filter::Cmp { op: CmpOp::Gte, .. }
        ));
        assert!(matches!(
            Filter::parse(&json!({ "x": { "$in": [1, 2] } })).unwrap(),
            Filter::In { .. }
        ));
        assert!(matches!(
            Filter::parse(&json!({ "x": { "$ilike": "a%" } })).unwrap(),
            Filter::Like { ci: true, .. }
        ));
        assert!(matches!(
            Filter::parse(&json!({ "x": { "$between": [1, 9] } })).unwrap(),
            Filter::Between { .. }
        ));
        // $null:true → IS NULL (negate=false); false → IS NOT NULL (negate=true)
        assert!(matches!(
            Filter::parse(&json!({ "x": { "$null": true } })).unwrap(),
            Filter::IsNull { negate: false, .. }
        ));
        assert!(matches!(
            Filter::parse(&json!({ "x": { "$null": false } })).unwrap(),
            Filter::IsNull { negate: true, .. }
        ));
    }

    #[test]
    fn parses_boolean_composition() {
        assert!(matches!(
            Filter::parse(&json!({ "$or": [{ "a": 1 }, { "b": 2 }] })).unwrap(),
            Filter::Or(v) if v.len() == 2
        ));
        assert!(matches!(
            Filter::parse(&json!({ "$not": { "a": 1 } })).unwrap(),
            Filter::Not(_)
        ));
        assert_eq!(Filter::parse(&json!({})).unwrap(), Filter::And(vec![]));
    }

    #[test]
    fn fold_detects_tautologies_and_contradictions() {
        let f = |v| Filter::parse(&v).unwrap().fold();
        // unconstrained (full-table): empty, empty $and, NOT(empty $or)
        assert_eq!(f(json!({})), Folded::AlwaysTrue);
        assert_eq!(f(json!({ "$and": [] })), Folded::AlwaysTrue);
        assert_eq!(f(json!({ "$not": { "$or": [] } })), Folded::AlwaysTrue);
        assert_eq!(f(json!({ "$or": [{ "a": 1 }, { "$not": { "$or": [] } }] })), Folded::AlwaysTrue);
        // matches nothing
        assert_eq!(f(json!({ "$or": [] })), Folded::AlwaysFalse);
        assert_eq!(f(json!({ "a": { "$in": [] } })), Folded::AlwaysFalse);
        assert_eq!(f(json!({ "$not": {} })), Folded::AlwaysFalse);
        // real predicates
        assert_eq!(f(json!({ "a": 1 })), Folded::Constrained);
        assert_eq!(f(json!({ "a": { "$gte": 1 } })), Folded::Constrained);
    }

    #[test]
    fn rejects_unknown_operators_dollar_fields_and_malformed() {
        assert!(Filter::parse(&json!({ "a": { "$drop": 1 } })).is_err());
        assert!(Filter::parse(&json!({ "$where": "x" })).is_err()); // $-field rejected
        assert!(Filter::parse(&json!({ "a": { "$between": [1] } })).is_err());
        assert!(Filter::parse(&json!({ "a": { "$in": 5 } })).is_err());
        assert!(Filter::parse(&json!({ "a": { "$null": 1 } })).is_err());
        assert!(Filter::parse(&json!("not an object")).is_err());
        let big: Vec<i64> = (0..(MAX_IN_LEN as i64 + 1)).collect();
        assert!(Filter::parse(&json!({ "a": { "$in": big } })).is_err());
    }
}
