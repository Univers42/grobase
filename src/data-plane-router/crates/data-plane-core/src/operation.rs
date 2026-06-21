/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   operation.rs                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:34:34 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:34:35 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DataOperationKind {
    List,
    Get,
    Insert,
    Update,
    Delete,
    Upsert,
    Batch,
    /// Grouped aggregation (count/sum/avg/min/max + `group_by`) — the carried
    /// [`AggregateSpec`] lives in [`DataOperation::aggregate`].
    Aggregate,
}

impl DataOperationKind {
    /// Every operation kind, for exhaustive iteration (the capability-honesty
    /// gate, the planner, tests). One canonical list so the "all ops" array
    /// isn't hand-copied across the codebase.
    pub const ALL: [DataOperationKind; 8] = [
        Self::List,
        Self::Get,
        Self::Insert,
        Self::Update,
        Self::Delete,
        Self::Upsert,
        Self::Batch,
        Self::Aggregate,
    ];

    /// The wire name (`insert`/`update`/…) — the snake_case serde tag as a
    /// `&'static str`, for audit events, automation trigger matching and
    /// realtime payloads without a serde round-trip.
    #[must_use]
    pub fn wire_name(&self) -> &'static str {
        match self {
            Self::List => "list",
            Self::Get => "get",
            Self::Insert => "insert",
            Self::Update => "update",
            Self::Delete => "delete",
            Self::Upsert => "upsert",
            Self::Batch => "batch",
            Self::Aggregate => "aggregate",
        }
    }
}

/// A SQL aggregate function — an allowlist, so the function name is never
/// taken from client text.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AggFunc {
    Count,
    Sum,
    Avg,
    Min,
    Max,
}

/// One aggregate output column: `func(field) AS alias`. `field` is omitted for
/// `count` (→ `COUNT(*)`); required for the others.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Aggregate {
    pub func: AggFunc,
    #[serde(default)]
    pub field: Option<String>,
    /// `func(DISTINCT field)` — requires a `field` (so `count` distinct is
    /// `count(DISTINCT field)`, never `count(DISTINCT *)`).
    #[serde(default)]
    pub distinct: bool,
    pub alias: String,
}

/// The aggregation request: the `aggregates` (output columns) and the optional
/// `group_by` columns. `filter` (on [`DataOperation`]) scopes the rows before
/// grouping.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct AggregateSpec {
    #[serde(default)]
    pub group_by: Vec<String>,
    pub aggregates: Vec<Aggregate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReturningMode {
    None,
    Changed,
    Full,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DataOperation {
    pub op: DataOperationKind,
    pub resource: String,
    pub data: Option<Value>,
    pub filter: Option<Value>,
    pub sort: Option<BTreeMap<String, String>>,
    pub limit: Option<u32>,
    pub offset: Option<u32>,
    pub idempotency_key: Option<String>,
    pub expected_version: Option<Value>,
    pub returning: Option<ReturningMode>,
    /// Aggregation request — present (and required) only for `op = Aggregate`.
    #[serde(default)]
    pub aggregate: Option<AggregateSpec>,
    /// Response projection: keep only these columns in returned rows.
    /// Applied post-fetch in the server (engine-neutral); absent/empty =
    /// full rows, so the existing wire shape is unchanged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fields: Option<Vec<String>>,
    /// Full-text search (used with `op = List`): rank rows by `ts_rank` over the
    /// `to_tsvector` of the listed columns matched against `query` via
    /// `websearch_to_tsquery`. Capability-gated to engines that advertise it
    /// (Postgres); others reject with 422. Owner-scoping (RLS) still applies.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search: Option<SearchSpec>,
    /// Vector k-NN search (used with `op = List`): order rows by distance from
    /// `query` on a pgvector column, limited to `k`. Capability-gated
    /// (Postgres + pgvector); others reject with 422. Owner-scoping applies.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vector: Option<VectorSpec>,
}

/// Full-text search request (engine-neutral; lowered per adapter).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SearchSpec {
    /// The user's search string (parsed by `websearch_to_tsquery` — supports
    /// `"quoted phrases"`, `-exclude`, `or`). Bound as a parameter, never inlined.
    pub query: String,
    /// Columns to search (their text is concatenated). Empty is rejected.
    #[serde(default)]
    pub columns: Vec<String>,
    /// Text-search config (`english`, `simple`, …). Allowlisted; default `english`.
    #[serde(default)]
    pub language: Option<String>,
}

/// Vector k-NN request (engine-neutral; lowered to pgvector on Postgres).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VectorSpec {
    /// The pgvector column to rank against.
    pub column: String,
    /// The query embedding. Bound as a parameter (`'[…]'::vector`), never inlined.
    pub query: Vec<f64>,
    /// How many nearest neighbours to return (default 10, capped at 1000).
    #[serde(default)]
    pub k: Option<u32>,
    /// Distance metric: `cosine` (`<=>`, default), `l2` (`<->`), `ip` (`<#>`).
    #[serde(default)]
    pub metric: Option<String>,
}

impl DataOperation {
    /// Strip non-requested columns from `rows` in place. No-op when the
    /// projection is absent or empty.
    pub fn project_rows(fields: &Option<Vec<String>>, rows: &mut [Value]) {
        let Some(fields) = fields.as_ref().filter(|f| !f.is_empty()) else {
            return;
        };
        for row in rows {
            if let Value::Object(map) = row {
                map.retain(|k, _| fields.iter().any(|f| f == k));
            }
        }
    }
}

#[cfg(test)]
mod projection_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn project_rows_keeps_only_requested_columns() {
        let mut rows = vec![
            json!({"id": 1, "title": "a", "secret": "x"}),
            json!({"id": 2, "title": "b", "secret": "y"}),
        ];
        DataOperation::project_rows(&Some(vec!["id".into(), "title".into()]), &mut rows);
        assert_eq!(rows[0], json!({"id": 1, "title": "a"}));
        assert_eq!(rows[1], json!({"id": 2, "title": "b"}));
    }

    #[test]
    fn project_rows_noop_when_absent_or_empty() {
        let original = vec![json!({"id": 1, "x": 2})];
        let mut rows = original.clone();
        DataOperation::project_rows(&None, &mut rows);
        assert_eq!(rows, original);
        DataOperation::project_rows(&Some(vec![]), &mut rows);
        assert_eq!(rows, original, "empty projection means full rows, not none");
        // Unknown columns simply project to empty objects (no error).
        DataOperation::project_rows(&Some(vec!["nope".into()]), &mut rows);
        assert_eq!(rows, vec![json!({})]);
    }

    #[test]
    fn fields_is_wire_optional() {
        let op: DataOperation =
            serde_json::from_value(json!({"op": "list", "resource": "t"})).unwrap();
        assert!(op.fields.is_none(), "absent fields deserializes to None");
        let op: DataOperation =
            serde_json::from_value(json!({"op": "list", "resource": "t", "fields": ["id"]}))
                .unwrap();
        assert_eq!(op.fields.as_deref(), Some(["id".to_string()].as_slice()));
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DataResult {
    #[serde(default)]
    pub rows: Vec<Value>,
    pub affected_rows: u64,
    pub next_cursor: Option<String>,
    /// Per-item outcomes — present only for `op = Batch`. Absent on every
    /// other operation so the wire shape of existing responses is unchanged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch: Option<BatchSummary>,
}

impl DataResult {
    /// A non-batch, non-paginated result — the common shape. Collapses the
    /// repeated `next_cursor: None, batch: None` tail across the adapters.
    #[must_use]
    pub fn new(rows: Vec<Value>, affected_rows: u64) -> Self {
        Self {
            rows,
            affected_rows,
            next_cursor: None,
            batch: None,
        }
    }
}

/// The result envelope of a batch: whether the engine executed it atomically
/// (SQL engines wrap the items in one transaction; document/KV engines run
/// them *ordered*, stopping at the first error) and one outcome per item.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BatchSummary {
    /// `true` → all-or-nothing (a failed item rolled the whole batch back);
    /// `false` → ordered execution, items before a failure are persisted.
    pub atomic: bool,
    pub items: Vec<BatchItemOutcome>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BatchItemOutcome {
    pub index: u32,
    pub status: BatchItemStatus,
    pub affected_rows: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BatchItemStatus {
    Ok,
    Error,
    /// Not executed because an earlier item failed (non-atomic engines only).
    Skipped,
}

impl DataOperation {
    /// Parses and validates the batch payload: `data` must be a non-empty JSON
    /// array of sub-operations, none of which may itself be a batch. The
    /// per-engine size ceiling is the planner's job (`max_batch_size`); this
    /// guards shape only, so every adapter shares one wire contract.
    pub fn batch_items(&self) -> Result<Vec<DataOperation>, String> {
        let Some(Value::Array(raw)) = self.data.as_ref() else {
            return Err("batch requires `data` to be a JSON array of sub-operations".to_string());
        };
        if raw.is_empty() {
            return Err("batch requires at least one sub-operation".to_string());
        }
        let mut items = Vec::with_capacity(raw.len());
        for (idx, item) in raw.iter().enumerate() {
            let sub: DataOperation = serde_json::from_value(item.clone())
                .map_err(|e| format!("batch item {idx} is not a valid operation: {e}"))?;
            if sub.op == DataOperationKind::Batch {
                return Err(format!("batch item {idx}: nested batches are not allowed"));
            }
            if sub.resource.trim().is_empty() {
                return Err(format!("batch item {idx}: `resource` is required"));
            }
            items.push(sub);
        }
        Ok(items)
    }
}
