/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   edge_operation.rs                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:35:02 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:35:03 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Edge-case suite for operation.rs (`DataOperation` / `DataResult` /
//! `DataOperationKind` / batch / projection / aggregate / search / vector) and
//! ports.rs (`EngineHealth::unknown`).
//!
//! Tests only — no source logic changed. Behavior asserted against the code.

use data_plane_core::*;
use proptest::prelude::*;
use serde_json::{json, Value};
use std::collections::BTreeMap;

// ════════════════════════════════════════════════════════════════════════════
//  DataOperationKind::ALL + wire_name round-trip
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn all_contains_exactly_eight_kinds() {
    assert_eq!(DataOperationKind::ALL.len(), 8);
}

#[test]
fn all_has_no_duplicates() {
    let v = DataOperationKind::ALL;
    for i in 0..v.len() {
        for j in (i + 1)..v.len() {
            assert_ne!(v[i], v[j], "duplicate at {i},{j}");
        }
    }
}

#[test]
fn wire_name_is_the_documented_string_per_kind() {
    assert_eq!(DataOperationKind::List.wire_name(), "list");
    assert_eq!(DataOperationKind::Get.wire_name(), "get");
    assert_eq!(DataOperationKind::Insert.wire_name(), "insert");
    assert_eq!(DataOperationKind::Update.wire_name(), "update");
    assert_eq!(DataOperationKind::Delete.wire_name(), "delete");
    assert_eq!(DataOperationKind::Upsert.wire_name(), "upsert");
    assert_eq!(DataOperationKind::Batch.wire_name(), "batch");
    assert_eq!(DataOperationKind::Aggregate.wire_name(), "aggregate");
}

#[test]
fn wire_name_matches_serde_tag_for_every_kind() {
    // wire_name() must equal the snake_case serde tag, byte-for-byte.
    for kind in DataOperationKind::ALL {
        let serde_tag = serde_json::to_value(&kind).unwrap();
        assert_eq!(serde_tag, json!(kind.wire_name()), "{kind:?}");
    }
}

#[test]
fn wire_name_round_trips_back_to_the_kind() {
    for kind in DataOperationKind::ALL {
        let parsed: DataOperationKind = serde_json::from_value(json!(kind.wire_name())).unwrap();
        assert_eq!(parsed, kind);
    }
}

#[test]
fn data_operation_kind_rejects_unknown_wire_name() {
    assert!(serde_json::from_value::<DataOperationKind>(json!("truncate")).is_err());
    assert!(serde_json::from_value::<DataOperationKind>(json!("LIST")).is_err());
    assert!(serde_json::from_value::<DataOperationKind>(json!("")).is_err());
}

// ════════════════════════════════════════════════════════════════════════════
//  DataResult::new — the common (non-batch, non-paginated) shape
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn data_result_new_sets_rows_and_affected() {
    let r = DataResult::new(vec![json!({"id": 1})], 1);
    assert_eq!(r.rows.len(), 1);
    assert_eq!(r.affected_rows, 1);
    assert!(r.next_cursor.is_none());
    assert!(r.batch.is_none());
}

#[test]
fn data_result_new_with_empty_rows() {
    let r = DataResult::new(vec![], 0);
    assert!(r.rows.is_empty());
    assert_eq!(r.affected_rows, 0);
    assert!(r.next_cursor.is_none());
    assert!(r.batch.is_none());
}

#[test]
fn data_result_new_with_large_affected_count() {
    let r = DataResult::new(vec![], u64::MAX);
    assert_eq!(r.affected_rows, u64::MAX);
}

#[test]
fn data_result_new_preserves_row_order_and_content() {
    let rows = vec![json!({"a": 1}), json!({"b": 2}), json!({"c": 3})];
    let r = DataResult::new(rows.clone(), 3);
    assert_eq!(r.rows, rows);
}

#[test]
fn data_result_round_trips_through_json() {
    let r = DataResult::new(vec![json!({"id": 7})], 1);
    let s = serde_json::to_string(&r).unwrap();
    let back: DataResult = serde_json::from_str(&s).unwrap();
    assert_eq!(r, back);
}

#[test]
fn data_result_batch_none_is_skipped_in_serialization() {
    let r = DataResult::new(vec![], 0);
    let s = serde_json::to_string(&r).unwrap();
    assert!(!s.contains("batch"), "None batch must not serialize: {s}");
}

#[test]
fn data_result_deserializes_with_defaulted_rows() {
    // rows has #[serde(default)] → an absent rows field deserializes to empty.
    let r: DataResult = serde_json::from_value(json!({"affected_rows": 5})).unwrap();
    assert!(r.rows.is_empty());
    assert_eq!(r.affected_rows, 5);
}

// ════════════════════════════════════════════════════════════════════════════
//  DataOperation::project_rows — in-place column projection
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn project_rows_keeps_only_requested_columns() {
    let mut rows = vec![json!({"id": 1, "title": "a", "secret": "x"})];
    DataOperation::project_rows(&Some(vec!["id".into(), "title".into()]), &mut rows);
    assert_eq!(rows[0], json!({"id": 1, "title": "a"}));
}

#[test]
fn project_rows_none_is_noop() {
    let mut rows = vec![json!({"id": 1, "x": 2})];
    let original = rows.clone();
    DataOperation::project_rows(&None, &mut rows);
    assert_eq!(rows, original);
}

#[test]
fn project_rows_empty_list_is_noop() {
    // Empty projection = full rows (NOT empty objects).
    let mut rows = vec![json!({"id": 1, "x": 2})];
    let original = rows.clone();
    DataOperation::project_rows(&Some(vec![]), &mut rows);
    assert_eq!(rows, original);
}

#[test]
fn project_rows_unknown_columns_yield_empty_objects() {
    let mut rows = vec![json!({"id": 1})];
    DataOperation::project_rows(&Some(vec!["nope".into()]), &mut rows);
    assert_eq!(rows, vec![json!({})]);
}

#[test]
fn project_rows_leaves_non_object_rows_untouched() {
    // A scalar / array row isn't an object → retain doesn't apply, stays as-is.
    let mut rows = vec![json!(42), json!(["a", "b"]), json!("str"), Value::Null];
    let original = rows.clone();
    DataOperation::project_rows(&Some(vec!["id".into()]), &mut rows);
    assert_eq!(rows, original);
}

#[test]
fn project_rows_on_empty_slice_does_not_panic() {
    let mut rows: Vec<Value> = vec![];
    DataOperation::project_rows(&Some(vec!["id".into()]), &mut rows);
    assert!(rows.is_empty());
}

#[test]
fn project_rows_keeps_all_when_all_columns_requested() {
    let mut rows = vec![json!({"a": 1, "b": 2})];
    DataOperation::project_rows(&Some(vec!["a".into(), "b".into()]), &mut rows);
    assert_eq!(rows[0], json!({"a": 1, "b": 2}));
}

#[test]
fn project_rows_partial_overlap_keeps_intersection() {
    let mut rows = vec![json!({"a": 1, "b": 2, "c": 3})];
    DataOperation::project_rows(&Some(vec!["a".into(), "z".into()]), &mut rows);
    assert_eq!(rows[0], json!({"a": 1}));
}

#[test]
fn project_rows_handles_mixed_object_and_scalar_rows() {
    let mut rows = vec![json!({"id": 1, "x": 9}), json!(7), json!({"id": 2, "y": 8})];
    DataOperation::project_rows(&Some(vec!["id".into()]), &mut rows);
    assert_eq!(rows[0], json!({"id": 1}));
    assert_eq!(rows[1], json!(7));
    assert_eq!(rows[2], json!({"id": 2}));
}

#[test]
fn project_rows_duplicate_requested_columns_are_harmless() {
    let mut rows = vec![json!({"a": 1, "b": 2})];
    DataOperation::project_rows(&Some(vec!["a".into(), "a".into()]), &mut rows);
    assert_eq!(rows[0], json!({"a": 1}));
}

// ════════════════════════════════════════════════════════════════════════════
//  DataOperation::batch_items — shape validation
// ════════════════════════════════════════════════════════════════════════════

fn op(kind: DataOperationKind, resource: &str, data: Option<Value>) -> DataOperation {
    DataOperation {
        op: kind,
        resource: resource.into(),
        data,
        filter: None,
        sort: None,
        limit: None,
        offset: None,
        idempotency_key: None,
        expected_version: None,
        returning: None,
        aggregate: None,
        fields: None,
        search: None,
        vector: None,
    }
}

#[test]
fn batch_items_parses_valid_sub_operations() {
    let data = json!([
        {"op": "insert", "resource": "t", "data": {"a": 1}},
        {"op": "update", "resource": "t", "filter": {"id": 1}, "data": {"a": 2}}
    ]);
    let items = op(DataOperationKind::Batch, "t", Some(data))
        .batch_items()
        .unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].op, DataOperationKind::Insert);
    assert_eq!(items[1].op, DataOperationKind::Update);
}

#[test]
fn batch_items_rejects_missing_data() {
    let err = op(DataOperationKind::Batch, "t", None)
        .batch_items()
        .unwrap_err();
    assert!(err.contains("JSON array"), "{err}");
}

#[test]
fn batch_items_rejects_non_array_data() {
    let err = op(DataOperationKind::Batch, "t", Some(json!({"a": 1})))
        .batch_items()
        .unwrap_err();
    assert!(err.contains("JSON array"), "{err}");
}

#[test]
fn batch_items_rejects_scalar_data() {
    assert!(op(DataOperationKind::Batch, "t", Some(json!(5)))
        .batch_items()
        .is_err());
    assert!(op(DataOperationKind::Batch, "t", Some(json!("x")))
        .batch_items()
        .is_err());
    assert!(op(DataOperationKind::Batch, "t", Some(Value::Null))
        .batch_items()
        .is_err());
}

#[test]
fn batch_items_rejects_empty_array() {
    let err = op(DataOperationKind::Batch, "t", Some(json!([])))
        .batch_items()
        .unwrap_err();
    assert!(err.contains("at least one"), "{err}");
}

#[test]
fn batch_items_rejects_nested_batch() {
    let data =
        json!([{"op": "batch", "resource": "t", "data": [{"op": "insert", "resource": "t"}]}]);
    let err = op(DataOperationKind::Batch, "t", Some(data))
        .batch_items()
        .unwrap_err();
    assert!(err.contains("nested batches"), "{err}");
}

#[test]
fn batch_items_reports_nested_batch_index() {
    let data = json!([
        {"op": "insert", "resource": "t"},
        {"op": "batch", "resource": "t", "data": [{"op": "get", "resource": "t"}]}
    ]);
    let err = op(DataOperationKind::Batch, "t", Some(data))
        .batch_items()
        .unwrap_err();
    assert!(err.contains("item 1"), "should name index 1: {err}");
}

#[test]
fn batch_items_rejects_blank_resource() {
    let data = json!([{"op": "insert", "resource": "   "}]);
    let err = op(DataOperationKind::Batch, "t", Some(data))
        .batch_items()
        .unwrap_err();
    assert!(err.contains("`resource` is required"), "{err}");
}

#[test]
fn batch_items_rejects_empty_resource() {
    let data = json!([{"op": "insert", "resource": ""}]);
    assert!(op(DataOperationKind::Batch, "t", Some(data))
        .batch_items()
        .is_err());
}

#[test]
fn batch_items_rejects_invalid_sub_operation_shape() {
    // Missing the required `op` field on a sub-op.
    let data = json!([{"resource": "t", "data": {"a": 1}}]);
    let err = op(DataOperationKind::Batch, "t", Some(data))
        .batch_items()
        .unwrap_err();
    assert!(err.contains("not a valid operation"), "{err}");
}

#[test]
fn batch_items_reports_invalid_sub_op_index() {
    let data = json!([
        {"op": "insert", "resource": "t"},
        {"op": "insert", "resource": "t"},
        {"op": "bogus_op", "resource": "t"}
    ]);
    let err = op(DataOperationKind::Batch, "t", Some(data))
        .batch_items()
        .unwrap_err();
    assert!(err.contains("item 2"), "should name index 2: {err}");
}

#[test]
fn batch_items_accepts_single_item() {
    let data = json!([{"op": "delete", "resource": "t", "filter": {"id": 1}}]);
    let items = op(DataOperationKind::Batch, "t", Some(data))
        .batch_items()
        .unwrap();
    assert_eq!(items.len(), 1);
}

#[test]
fn batch_items_preserves_order_for_many_items() {
    let data = json!([
        {"op": "insert", "resource": "a"},
        {"op": "update", "resource": "b"},
        {"op": "delete", "resource": "c"},
        {"op": "upsert", "resource": "d"},
        {"op": "get", "resource": "e"}
    ]);
    let items = op(DataOperationKind::Batch, "t", Some(data))
        .batch_items()
        .unwrap();
    assert_eq!(items.len(), 5);
    assert_eq!(items[0].resource, "a");
    assert_eq!(items[4].resource, "e");
    assert_eq!(items[3].op, DataOperationKind::Upsert);
}

#[test]
fn batch_items_works_regardless_of_outer_op_kind() {
    // batch_items only inspects `data`, not the outer `op`.
    let data = json!([{"op": "insert", "resource": "t"}]);
    let items = op(DataOperationKind::Insert, "t", Some(data))
        .batch_items()
        .unwrap();
    assert_eq!(items.len(), 1);
}

// ════════════════════════════════════════════════════════════════════════════
//  DataOperation serde — required vs optional fields
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn data_operation_minimal_payload_deserializes() {
    let o: DataOperation = serde_json::from_value(json!({"op": "list", "resource": "t"})).unwrap();
    assert_eq!(o.op, DataOperationKind::List);
    assert_eq!(o.resource, "t");
    assert!(o.data.is_none() && o.filter.is_none() && o.fields.is_none());
    assert!(o.aggregate.is_none() && o.search.is_none() && o.vector.is_none());
}

#[test]
fn data_operation_missing_op_is_rejected() {
    assert!(serde_json::from_value::<DataOperation>(json!({"resource": "t"})).is_err());
}

#[test]
fn data_operation_missing_resource_is_rejected() {
    assert!(serde_json::from_value::<DataOperation>(json!({"op": "list"})).is_err());
}

#[test]
fn data_operation_fields_is_wire_optional_and_round_trips() {
    let o: DataOperation =
        serde_json::from_value(json!({"op": "list", "resource": "t", "fields": ["id", "name"]}))
            .unwrap();
    assert_eq!(
        o.fields.as_deref(),
        Some(["id".to_string(), "name".to_string()].as_slice())
    );
    // None fields is skipped in serialization.
    let plain = op(DataOperationKind::List, "t", None);
    let s = serde_json::to_string(&plain).unwrap();
    assert!(!s.contains("fields"), "None fields skipped: {s}");
}

#[test]
fn data_operation_full_round_trip() {
    let mut sort = BTreeMap::new();
    sort.insert("created_at".to_string(), "desc".to_string());
    let o = DataOperation {
        op: DataOperationKind::List,
        resource: "events".into(),
        data: Some(json!({"k": "v"})),
        filter: Some(json!({"a": 1})),
        sort: Some(sort),
        limit: Some(50),
        offset: Some(10),
        idempotency_key: Some("idem-1".into()),
        expected_version: Some(json!(3)),
        returning: Some(ReturningMode::Full),
        aggregate: None,
        fields: Some(vec!["id".into()]),
        search: None,
        vector: None,
    };
    let s = serde_json::to_string(&o).unwrap();
    let back: DataOperation = serde_json::from_str(&s).unwrap();
    assert_eq!(o, back);
}

#[test]
fn returning_mode_wire_names() {
    assert_eq!(
        serde_json::to_value(ReturningMode::None).unwrap(),
        json!("none")
    );
    assert_eq!(
        serde_json::to_value(ReturningMode::Changed).unwrap(),
        json!("changed")
    );
    assert_eq!(
        serde_json::to_value(ReturningMode::Full).unwrap(),
        json!("full")
    );
}

// ════════════════════════════════════════════════════════════════════════════
//  Aggregate / AggregateSpec round-trips
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn agg_func_wire_names() {
    assert_eq!(
        serde_json::to_value(AggFunc::Count).unwrap(),
        json!("count")
    );
    assert_eq!(serde_json::to_value(AggFunc::Sum).unwrap(), json!("sum"));
    assert_eq!(serde_json::to_value(AggFunc::Avg).unwrap(), json!("avg"));
    assert_eq!(serde_json::to_value(AggFunc::Min).unwrap(), json!("min"));
    assert_eq!(serde_json::to_value(AggFunc::Max).unwrap(), json!("max"));
}

#[test]
fn agg_func_rejects_unknown() {
    assert!(serde_json::from_value::<AggFunc>(json!("median")).is_err());
}

#[test]
fn aggregate_count_without_field_round_trips() {
    let a = Aggregate {
        func: AggFunc::Count,
        field: None,
        distinct: false,
        alias: "n".into(),
    };
    let s = serde_json::to_string(&a).unwrap();
    let back: Aggregate = serde_json::from_str(&s).unwrap();
    assert_eq!(a, back);
}

#[test]
fn aggregate_sum_with_field_round_trips() {
    let a = Aggregate {
        func: AggFunc::Sum,
        field: Some("amount".into()),
        distinct: false,
        alias: "total".into(),
    };
    let back: Aggregate = serde_json::from_str(&serde_json::to_string(&a).unwrap()).unwrap();
    assert_eq!(a, back);
}

#[test]
fn aggregate_distinct_count_round_trips() {
    let a = Aggregate {
        func: AggFunc::Count,
        field: Some("user".into()),
        distinct: true,
        alias: "uniq".into(),
    };
    let back: Aggregate = serde_json::from_str(&serde_json::to_string(&a).unwrap()).unwrap();
    assert_eq!(a, back);
    assert!(back.distinct);
}

#[test]
fn aggregate_defaults_field_to_none_and_distinct_to_false() {
    let a: Aggregate = serde_json::from_value(json!({"func": "count", "alias": "n"})).unwrap();
    assert!(a.field.is_none());
    assert!(!a.distinct);
}

#[test]
fn aggregate_spec_default_is_empty() {
    let spec = AggregateSpec::default();
    assert!(spec.group_by.is_empty());
    assert!(spec.aggregates.is_empty());
}

#[test]
fn aggregate_spec_with_group_by_round_trips() {
    let spec = AggregateSpec {
        group_by: vec!["country".into(), "city".into()],
        aggregates: vec![
            Aggregate {
                func: AggFunc::Count,
                field: None,
                distinct: false,
                alias: "n".into(),
            },
            Aggregate {
                func: AggFunc::Avg,
                field: Some("age".into()),
                distinct: false,
                alias: "avg_age".into(),
            },
        ],
    };
    let back: AggregateSpec = serde_json::from_str(&serde_json::to_string(&spec).unwrap()).unwrap();
    assert_eq!(spec, back);
}

#[test]
fn aggregate_spec_group_by_defaults_empty_when_absent() {
    let spec: AggregateSpec = serde_json::from_value(json!({"aggregates": []})).unwrap();
    assert!(spec.group_by.is_empty());
}

#[test]
fn data_operation_with_aggregate_round_trips() {
    let o = DataOperation {
        aggregate: Some(AggregateSpec {
            group_by: vec!["g".into()],
            aggregates: vec![Aggregate {
                func: AggFunc::Max,
                field: Some("x".into()),
                distinct: false,
                alias: "mx".into(),
            }],
        }),
        ..op(DataOperationKind::Aggregate, "t", None)
    };
    let back: DataOperation = serde_json::from_str(&serde_json::to_string(&o).unwrap()).unwrap();
    assert_eq!(o, back);
}

// ════════════════════════════════════════════════════════════════════════════
//  SearchSpec / VectorSpec round-trips + defaults
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn search_spec_minimal_round_trips() {
    let s = SearchSpec {
        query: "hello world".into(),
        columns: vec![],
        language: None,
    };
    let back: SearchSpec = serde_json::from_str(&serde_json::to_string(&s).unwrap()).unwrap();
    assert_eq!(s, back);
}

#[test]
fn search_spec_defaults_columns_and_language() {
    let s: SearchSpec = serde_json::from_value(json!({"query": "x"})).unwrap();
    assert!(s.columns.is_empty());
    assert!(s.language.is_none());
}

#[test]
fn search_spec_full_round_trips() {
    let s = SearchSpec {
        query: "\"quoted phrase\" -exclude".into(),
        columns: vec!["title".into(), "body".into()],
        language: Some("english".into()),
    };
    let back: SearchSpec = serde_json::from_str(&serde_json::to_string(&s).unwrap()).unwrap();
    assert_eq!(s, back);
}

#[test]
fn search_spec_requires_query() {
    assert!(serde_json::from_value::<SearchSpec>(json!({"columns": ["a"]})).is_err());
}

#[test]
fn vector_spec_minimal_round_trips() {
    let v = VectorSpec {
        column: "embedding".into(),
        query: vec![0.1, 0.2, 0.3],
        k: None,
        metric: None,
    };
    let back: VectorSpec = serde_json::from_str(&serde_json::to_string(&v).unwrap()).unwrap();
    assert_eq!(v, back);
}

#[test]
fn vector_spec_defaults_k_and_metric() {
    let v: VectorSpec =
        serde_json::from_value(json!({"column": "e", "query": [1.0, 2.0]})).unwrap();
    assert!(v.k.is_none());
    assert!(v.metric.is_none());
}

#[test]
fn vector_spec_full_round_trips() {
    let v = VectorSpec {
        column: "emb".into(),
        query: vec![1.5, -2.5, 0.0],
        k: Some(20),
        metric: Some("cosine".into()),
    };
    let back: VectorSpec = serde_json::from_str(&serde_json::to_string(&v).unwrap()).unwrap();
    assert_eq!(v, back);
}

#[test]
fn vector_spec_empty_query_vector_round_trips() {
    let v = VectorSpec {
        column: "e".into(),
        query: vec![],
        k: Some(1),
        metric: None,
    };
    let back: VectorSpec = serde_json::from_str(&serde_json::to_string(&v).unwrap()).unwrap();
    assert_eq!(v, back);
}

#[test]
fn vector_spec_requires_column_and_query() {
    assert!(serde_json::from_value::<VectorSpec>(json!({"query": [1.0]})).is_err());
    assert!(serde_json::from_value::<VectorSpec>(json!({"column": "e"})).is_err());
}

// ════════════════════════════════════════════════════════════════════════════
//  BatchSummary / BatchItemOutcome / BatchItemStatus
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn batch_item_status_wire_names() {
    assert_eq!(
        serde_json::to_value(BatchItemStatus::Ok).unwrap(),
        json!("ok")
    );
    assert_eq!(
        serde_json::to_value(BatchItemStatus::Error).unwrap(),
        json!("error")
    );
    assert_eq!(
        serde_json::to_value(BatchItemStatus::Skipped).unwrap(),
        json!("skipped")
    );
}

#[test]
fn batch_item_status_rejects_unknown() {
    assert!(serde_json::from_value::<BatchItemStatus>(json!("pending")).is_err());
}

#[test]
fn batch_item_outcome_round_trips_with_error() {
    let o = BatchItemOutcome {
        index: 2,
        status: BatchItemStatus::Error,
        affected_rows: 0,
        error: Some("dup key".into()),
    };
    let back: BatchItemOutcome = serde_json::from_str(&serde_json::to_string(&o).unwrap()).unwrap();
    assert_eq!(o, back);
}

#[test]
fn batch_item_outcome_skips_none_error() {
    let o = BatchItemOutcome {
        index: 0,
        status: BatchItemStatus::Ok,
        affected_rows: 1,
        error: None,
    };
    let s = serde_json::to_string(&o).unwrap();
    assert!(!s.contains("error"), "None error must be skipped: {s}");
}

#[test]
fn batch_item_outcome_defaults_error_to_none() {
    let o: BatchItemOutcome =
        serde_json::from_value(json!({"index": 0, "status": "ok", "affected_rows": 3})).unwrap();
    assert!(o.error.is_none());
}

#[test]
fn batch_summary_round_trips() {
    let summary = BatchSummary {
        atomic: true,
        items: vec![
            BatchItemOutcome {
                index: 0,
                status: BatchItemStatus::Ok,
                affected_rows: 1,
                error: None,
            },
            BatchItemOutcome {
                index: 1,
                status: BatchItemStatus::Error,
                affected_rows: 0,
                error: Some("x".into()),
            },
            BatchItemOutcome {
                index: 2,
                status: BatchItemStatus::Skipped,
                affected_rows: 0,
                error: None,
            },
        ],
    };
    let back: BatchSummary =
        serde_json::from_str(&serde_json::to_string(&summary).unwrap()).unwrap();
    assert_eq!(summary, back);
}

#[test]
fn data_result_with_batch_summary_round_trips() {
    let r = DataResult {
        rows: vec![],
        affected_rows: 2,
        next_cursor: None,
        batch: Some(BatchSummary {
            atomic: false,
            items: vec![BatchItemOutcome {
                index: 0,
                status: BatchItemStatus::Ok,
                affected_rows: 2,
                error: None,
            }],
        }),
    };
    let back: DataResult = serde_json::from_str(&serde_json::to_string(&r).unwrap()).unwrap();
    assert_eq!(r, back);
}

// ════════════════════════════════════════════════════════════════════════════
//  EngineHealth::unknown (ports.rs)
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn engine_health_unknown_sets_status_unknown() {
    let h = EngineHealth::unknown("postgresql", "mount-1");
    assert_eq!(h.engine, "postgresql");
    assert_eq!(h.mount_id, "mount-1");
    assert_eq!(h.status, "unknown");
}

#[test]
fn engine_health_unknown_accepts_string_and_str() {
    let h1 = EngineHealth::unknown("mysql".to_string(), "m".to_string());
    let h2 = EngineHealth::unknown("mysql", "m");
    assert_eq!(h1, h2);
}

#[test]
fn engine_health_unknown_with_empty_args() {
    let h = EngineHealth::unknown("", "");
    assert_eq!(h.engine, "");
    assert_eq!(h.mount_id, "");
    assert_eq!(h.status, "unknown");
}

#[test]
fn engine_health_round_trips_through_json() {
    let h = EngineHealth::unknown("redis", "cache-1");
    let back: EngineHealth = serde_json::from_str(&serde_json::to_string(&h).unwrap()).unwrap();
    assert_eq!(h, back);
}

// ════════════════════════════════════════════════════════════════════════════
//  RawStatement / MigrationRequest / PoolStats serde (ports.rs)
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn raw_statement_defaults_params_and_expect_rows() {
    let r: RawStatement = serde_json::from_value(json!({"statement": "SELECT 1"})).unwrap();
    assert!(r.params.is_empty());
    assert!(!r.expect_rows);
}

#[test]
fn raw_statement_round_trips() {
    let r = RawStatement {
        statement: "INSERT …".into(),
        params: vec![json!(1), json!("x")],
        expect_rows: true,
    };
    let back: RawStatement = serde_json::from_str(&serde_json::to_string(&r).unwrap()).unwrap();
    assert_eq!(r, back);
}

#[test]
fn migration_status_wire_names() {
    assert_eq!(
        serde_json::to_value(MigrationStatus::Applied).unwrap(),
        json!("applied")
    );
    assert_eq!(
        serde_json::to_value(MigrationStatus::Skipped).unwrap(),
        json!("skipped")
    );
}

#[test]
fn migration_result_round_trips() {
    let m = MigrationResult {
        name: "001_init".into(),
        status: MigrationStatus::Applied,
        statements_run: 7,
    };
    let back: MigrationResult = serde_json::from_str(&serde_json::to_string(&m).unwrap()).unwrap();
    assert_eq!(m, back);
}

#[test]
fn pool_stats_round_trips() {
    let p = PoolStats {
        mount_id: "m".into(),
        engine: "postgresql".into(),
        active_connections: 3,
        idle_connections: 2,
        waiting_requests: 0,
    };
    let back: PoolStats = serde_json::from_str(&serde_json::to_string(&p).unwrap()).unwrap();
    assert_eq!(p, back);
}

// ── PROPERTY-BASED ────────────────────────────────────────────────────────────

proptest! {
    /// wire_name ↔ serde tag round-trips for every kind, always.
    #[test]
    fn prop_kind_wire_name_round_trip(idx in 0usize..8) {
        let kind = DataOperationKind::ALL[idx].clone();
        let parsed: DataOperationKind = serde_json::from_value(json!(kind.wire_name())).unwrap();
        prop_assert_eq!(parsed, kind);
    }

    /// DataResult::new always leaves next_cursor and batch None, and echoes the
    /// affected count, for any count.
    #[test]
    fn prop_data_result_new_invariants(affected in any::<u64>(), n in 0usize..8) {
        let rows: Vec<Value> = (0..n).map(|i| json!({"i": i})).collect();
        let r = DataResult::new(rows.clone(), affected);
        prop_assert_eq!(r.affected_rows, affected);
        prop_assert!(r.next_cursor.is_none());
        prop_assert!(r.batch.is_none());
        prop_assert_eq!(r.rows.len(), n);
    }

    /// project_rows with an empty or None projection never alters the rows.
    #[test]
    fn prop_project_rows_noop_when_empty(n in 0usize..6) {
        let rows: Vec<Value> = (0..n).map(|i| json!({"id": i, "x": i * 2})).collect();
        let mut a = rows.clone();
        DataOperation::project_rows(&None, &mut a);
        prop_assert_eq!(&a, &rows);
        let mut b = rows.clone();
        DataOperation::project_rows(&Some(vec![]), &mut b);
        prop_assert_eq!(b, rows);
    }

    /// project_rows output object never contains a key outside the requested set.
    #[test]
    fn prop_project_rows_only_requested_keys(n in 1usize..6) {
        let rows: Vec<Value> = (0..n).map(|i| json!({"a": i, "b": i, "c": i})).collect();
        let mut rows2 = rows;
        DataOperation::project_rows(&Some(vec!["a".into(), "b".into()]), &mut rows2);
        for row in &rows2 {
            if let Value::Object(m) = row {
                prop_assert!(m.keys().all(|k| k == "a" || k == "b"));
            }
        }
    }

    /// batch_items rejects an empty array and accepts any array of n valid,
    /// non-batch sub-ops (n >= 1), returning exactly n items.
    #[test]
    fn prop_batch_items_count(n in 0usize..8) {
        let data: Vec<Value> = (0..n).map(|_| json!({"op": "insert", "resource": "t"})).collect();
        let o = op(DataOperationKind::Batch, "t", Some(json!(data)));
        let res = o.batch_items();
        if n == 0 {
            prop_assert!(res.is_err());
        } else {
            prop_assert_eq!(res.unwrap().len(), n);
        }
    }

    /// A DataOperation built from a minimal payload + any resource string
    /// deserializes and round-trips.
    #[test]
    fn prop_data_operation_round_trip(resource in "[a-z_][a-z0-9_]{0,20}", idx in 0usize..8) {
        let o = op(DataOperationKind::ALL[idx].clone(), &resource, None);
        let back: DataOperation = serde_json::from_str(&serde_json::to_string(&o).unwrap()).unwrap();
        prop_assert_eq!(o, back);
    }

    /// EngineHealth::unknown always reports status "unknown" for any inputs.
    #[test]
    fn prop_engine_health_unknown_status(engine in ".{0,20}", mount in ".{0,20}") {
        let h = EngineHealth::unknown(engine.clone(), mount.clone());
        prop_assert_eq!(h.status, "unknown");
        prop_assert_eq!(h.engine, engine);
        prop_assert_eq!(h.mount_id, mount);
    }
}
