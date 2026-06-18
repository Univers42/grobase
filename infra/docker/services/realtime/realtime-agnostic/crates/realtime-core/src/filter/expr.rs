/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   expr.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Filter expression evaluation and JSON parsing.

use super::{FieldPath, FilterExpr, FilterValue};

impl FilterExpr {
    /// Evaluate this filter expression against an event.
    ///
    /// The `field_getter` closure extracts field values from the event.
    /// Use [`envelope_field_getter()`](super::envelope_field_getter) as
    /// the standard implementation.
    pub fn evaluate(&self, field_getter: &dyn Fn(&FieldPath) -> Option<FilterValue>) -> bool {
        match self {
            Self::Eq(f, expected) => field_getter(f).as_ref() == Some(expected),
            Self::Ne(f, expected) => field_getter(f).as_ref() != Some(expected),
            Self::In(f, values) => field_getter(f).is_some_and(|v| values.contains(&v)),
            Self::And(l, r) => l.evaluate(field_getter) && r.evaluate(field_getter),
            Self::Or(l, r) => l.evaluate(field_getter) || r.evaluate(field_getter),
            Self::Not(inner) => !inner.evaluate(field_getter),
        }
    }

    /// Parse a JSON object into a `FilterExpr` tree.
    ///
    /// Multiple top-level fields are implicitly `ANDed` together.
    /// Returns `None` if the JSON is empty or contains unknown operators.
    #[must_use]
    pub fn from_json(value: &serde_json::Value) -> Option<Self> {
        let obj = value.as_object()?;
        let mut exprs: Vec<Self> = Vec::new();
        for (field, condition) in obj {
            let cond_obj = condition.as_object()?;
            for (op, val) in cond_obj {
                let path = FieldPath::new(field.clone());
                exprs.push(parse_operator(path, op, val)?);
            }
        }
        combine_exprs(exprs)
    }
}

/// Parse a single operator clause into a [`FilterExpr`] leaf.
fn parse_operator(field: FieldPath, op: &str, val: &serde_json::Value) -> Option<FilterExpr> {
    match op {
        "eq" => Some(FilterExpr::Eq(field, json_to_filter_value(val))),
        "ne" => Some(FilterExpr::Ne(field, json_to_filter_value(val))),
        "in" => {
            let arr = val.as_array()?;
            let values = arr.iter().map(json_to_filter_value).collect();
            Some(FilterExpr::In(field, values))
        }
        _ => None,
    }
}

/// Combine a `Vec` of expressions into a single AND tree.
fn combine_exprs(mut exprs: Vec<FilterExpr>) -> Option<FilterExpr> {
    match exprs.len() {
        0 => None,
        1 => Some(exprs.remove(0)),
        _ => {
            let mut combined = exprs.remove(0);
            for expr in exprs {
                combined = FilterExpr::And(Box::new(combined), Box::new(expr));
            }
            Some(combined)
        }
    }
}

/// Convert a raw `serde_json::Value` into a [`FilterValue`].
#[allow(clippy::option_if_let_else)]
fn json_to_filter_value(v: &serde_json::Value) -> FilterValue {
    match v {
        serde_json::Value::String(s) => FilterValue::String(s.clone()),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                FilterValue::Integer(i)
            } else if let Some(f) = n.as_f64() {
                FilterValue::Float(f)
            } else {
                FilterValue::Null
            }
        }
        serde_json::Value::Bool(b) => FilterValue::Bool(*b),
        _ => FilterValue::Null,
    }
}
