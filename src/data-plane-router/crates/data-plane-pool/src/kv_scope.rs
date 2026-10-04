//! Predicate guards for the key-addressed adapters (redis, dynamodb).
//!
//! Both engines address one row by its `id` and list a whole key space (a key
//! prefix, a partition). Neither evaluates a filter or a sort, so a predicate
//! they were handed used to be dropped and the caller got rows it had excluded,
//! or a write it had made conditional. These guards refuse such a request with
//! `UnsupportedCapability` (422) instead: honest absence, not a silent answer.

use data_plane_core::{
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, Filter, Folded,
};

/// Refuse the predicates a key-addressed engine would ignore for this
/// operation: any constraint or sort on a `list`, and any filter key but `id`
/// on a single-row operation. Insert, batch and aggregate carry none to check.
///
/// # Errors
/// As [`refuse_list_predicates`] and [`refuse_non_id_filter`].
pub(crate) fn refuse_ignored_predicates(engine: &str, op: &DataOperation) -> DataPlaneResult<()> {
    match op.op {
        DataOperationKind::List => refuse_list_predicates(engine, op),
        DataOperationKind::Get
        | DataOperationKind::Update
        | DataOperationKind::Delete
        | DataOperationKind::Upsert => refuse_non_id_filter(engine, op),
        DataOperationKind::Insert | DataOperationKind::Batch | DataOperationKind::Aggregate => {
            Ok(())
        }
    }
}

/// Refuse a `list` whose filter constrains anything or whose sort names a
/// field. An empty filter (`{}`, `{"$and": []}`) and an empty sort pass.
///
/// # Errors
/// `UnsupportedCapability` (422) for a constraining filter or a non-empty sort;
/// `InvalidRequest` (400) when the filter itself does not parse.
fn refuse_list_predicates(engine: &str, op: &DataOperation) -> DataPlaneResult<()> {
    if let Some(raw) = op.filter.as_ref() {
        if Filter::parse(raw)?.fold() != Folded::AlwaysTrue {
            return Err(unsupported(engine, "filter"));
        }
    }
    if op.sort.as_ref().is_some_and(|s| !s.is_empty()) {
        return Err(unsupported(engine, "sort"));
    }
    Ok(())
}

/// Refuse a filter that names anything but `id` on an operation the engine
/// addresses by id alone (get, update, delete, upsert): a condition on another
/// field would be ignored and the read or write would land anyway.
///
/// # Errors
/// `UnsupportedCapability` (422) naming the first key that is not `id`.
fn refuse_non_id_filter(engine: &str, op: &DataOperation) -> DataPlaneResult<()> {
    let Some(map) = op.filter.as_ref().and_then(|v| v.as_object()) else {
        return Ok(());
    };
    match map.keys().find(|k| k.as_str() != "id") {
        Some(_) => Err(unsupported(engine, "filter_on_non_id_field")),
        None => Ok(()),
    }
}

fn unsupported(engine: &str, capability: &str) -> DataPlaneError {
    DataPlaneError::UnsupportedCapability {
        engine: engine.to_string(),
        capability: capability.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use data_plane_core::DataOperationKind;
    use serde_json::{json, Value};
    use std::collections::BTreeMap;

    fn op(kind: DataOperationKind, filter: Option<Value>) -> DataOperation {
        DataOperation {
            op: kind,
            resource: "items".into(),
            data: None,
            filter,
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

    fn is_unsupported(r: DataPlaneResult<()>, want: &str) -> bool {
        matches!(r, Err(DataPlaneError::UnsupportedCapability { capability, .. }) if capability == want)
    }

    #[test]
    fn list_without_predicates_passes() {
        assert!(refuse_list_predicates("redis", &op(DataOperationKind::List, None)).is_ok());
        for empty in [json!({}), json!({"$and": []})] {
            assert!(
                refuse_list_predicates("redis", &op(DataOperationKind::List, Some(empty))).is_ok()
            );
        }
    }

    #[test]
    fn list_with_a_constraining_filter_is_refused() {
        for f in [
            json!({"status": "active"}),
            json!({"name": {"$like": "ab%"}}),
            json!({"$or": []}),
            json!({"id": "a"}),
        ] {
            let r = refuse_list_predicates("redis", &op(DataOperationKind::List, Some(f.clone())));
            assert!(is_unsupported(r, "filter"), "{f} must be refused");
        }
    }

    #[test]
    fn list_with_a_sort_is_refused_and_an_empty_sort_passes() {
        let mut sorted = op(DataOperationKind::List, None);
        sorted.sort = Some(BTreeMap::from([("name".to_string(), "asc".to_string())]));
        assert!(is_unsupported(
            refuse_list_predicates("dynamodb", &sorted),
            "sort"
        ));
        sorted.sort = Some(BTreeMap::new());
        assert!(refuse_list_predicates("dynamodb", &sorted).is_ok());
    }

    #[test]
    fn a_malformed_list_filter_is_a_400_not_a_422() {
        let r = refuse_list_predicates(
            "redis",
            &op(DataOperationKind::List, Some(json!({"a": {"$where": 1}}))),
        );
        assert!(matches!(r, Err(DataPlaneError::InvalidRequest { .. })));
    }

    #[test]
    fn id_only_filters_pass_and_any_other_key_is_refused() {
        for ok in [None, Some(json!({})), Some(json!({"id": "a"}))] {
            assert!(refuse_non_id_filter("redis", &op(DataOperationKind::Update, ok)).is_ok());
        }
        for f in [
            json!({"id": "a", "status": "x"}),
            json!({"$and": [{"id": "a"}]}),
        ] {
            let r =
                refuse_non_id_filter("dynamodb", &op(DataOperationKind::Delete, Some(f.clone())));
            assert!(
                is_unsupported(r, "filter_on_non_id_field"),
                "{f} must be refused"
            );
        }
    }
}
