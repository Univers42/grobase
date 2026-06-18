/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mod.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Server-side event filter expressions.
//!
//! Clients can attach a filter to their subscriptions so that only
//! events matching the filter are delivered. Filters are evaluated on
//! the server, saving bandwidth and client-side CPU.
//!
//! ## Supported operators
//!
//! | Operator | JSON syntax              | Description              |
//! |----------|--------------------------|--------------------------|
//! | `eq`     | `{ "field": { "eq": V }}` | Field equals value       |
//! | `ne`     | `{ "field": { "ne": V }}` | Field not equals value   |
//! | `in`     | `{ "field": { "in": [..] }}` | Field is one of values |
//!
//! Multiple conditions are implicitly `ANDed`.

mod expr;
mod getter;
#[cfg(test)]
mod tests;

pub use getter::*;

use serde::{Deserialize, Serialize};

/// A composable, tree-structured filter expression.
///
/// Built from JSON at subscribe time (via [`from_json()`](Self::from_json))
/// and evaluated against each event using [`evaluate()`](Self::evaluate).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum FilterExpr {
    /// Field equals value: `{ "event_type": { "eq": "created" } }`
    Eq(FieldPath, FilterValue),
    /// Field not equals value.
    Ne(FieldPath, FilterValue),
    /// Field is one of several values.
    In(FieldPath, Vec<FilterValue>),
    /// Both sub-expressions must be true.
    And(Box<Self>, Box<Self>),
    /// At least one sub-expression must be true.
    Or(Box<Self>, Box<Self>),
    /// Inverts the inner expression.
    Not(Box<Self>),
}

/// A dot-separated path identifying a field on the
/// [`EventEnvelope`](crate::types::EventEnvelope).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct FieldPath(pub String);

impl FieldPath {
    /// Create a new field path from a string.
    pub fn new(s: impl Into<String>) -> Self {
        Self(s.into())
    }
}

/// A typed value used in filter comparisons.
///
/// Supports JSON primitive types. Uses `#[serde(untagged)]`
/// so JSON values deserialize naturally.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum FilterValue {
    /// A string value.
    String(String),
    /// An integer value.
    Integer(i64),
    /// A floating-point value.
    Float(f64),
    /// A boolean value.
    Bool(bool),
    /// A null value.
    Null,
}

impl FilterValue {
    /// Try to extract the inner string, returning `None` for
    /// non-string values.
    #[must_use]
    pub const fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(s) => Some(s.as_str()),
            _ => None,
        }
    }
}
