//! CRUD/aggregate executors on [`super::pool::MongoPool`] — the single-document
//! dispatch targets and the ordered batch runner. The tenant-scoped filter and
//! document builders they call live in [`super::filter`]; the JSON↔BSON
//! conversion in [`super::convert`].
//
// ponytail: one file holds all 7 `run_*` executors + dispatch + batch (~320
//   lines, no unit tests — they need a live DB, exercised by the m27
//   conformance gate). They share one shape (build filter → driver call →
//   normalize); splitting per-op would scatter a single concern across 7 files
//   for no gain. Split only if an executor grows its own logic.

use bson::{doc, Bson, Document};
use data_plane_core::{
    BatchItemOutcome, BatchItemStatus, BatchSummary, DataOperation, DataOperationKind,
    DataPlaneError, DataPlaneResult, DataResult, RequestIdentity,
};
use futures::TryStreamExt;
use mongodb::{
    options::{FindOptions, UpdateOptions},
    Collection,
};
use serde_json::Value;

use super::convert::{normalize_doc, value_to_bson};
use super::error::mongo_err;
use super::filter::{
    build_mongo_aggregate_expr, build_owned_doc, build_sort, build_tenant_filter,
    require_row_filter, safe_agg_key,
};
use super::pool::MongoPool;

impl MongoPool {
    /// Ordered, non-atomic batch: items execute in order; the first failure
    /// stops execution. Items already executed STAY PERSISTED (mongo has no
    /// cross-document rollback here) — the summary reports ok / error /
    /// skipped per item so the caller can reconcile.
    pub(super) async fn run_batch(
        &self,
        operation: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let items = operation
            .batch_items()
            .map_err(|message| DataPlaneError::InvalidRequest { message })?;
        let mut outcomes = Vec::with_capacity(items.len());
        let mut total: u64 = 0;
        let mut failed = false;
        for (idx, item) in items.iter().enumerate() {
            if failed {
                outcomes.push(BatchItemOutcome {
                    index: idx as u32,
                    status: BatchItemStatus::Skipped,
                    affected_rows: 0,
                    error: None,
                });
                continue;
            }
            match self.dispatch_single(item, identity).await {
                Ok(result) => {
                    total += result.affected_rows;
                    outcomes.push(BatchItemOutcome {
                        index: idx as u32,
                        status: BatchItemStatus::Ok,
                        affected_rows: result.affected_rows,
                        error: None,
                    });
                }
                Err(e) => {
                    failed = true;
                    outcomes.push(BatchItemOutcome {
                        index: idx as u32,
                        status: BatchItemStatus::Error,
                        affected_rows: 0,
                        error: Some(e.to_string()),
                    });
                }
            }
        }
        Ok(DataResult {
            rows: vec![],
            affected_rows: total,
            next_cursor: None,
            batch: Some(BatchSummary {
                atomic: false,
                items: outcomes,
            }),
        })
    }

    /// Single (non-batch) operation dispatch — resolves the collection from
    /// the operation's own `resource`, so batch items can span collections.
    /// Exhaustive by enumeration so the match can't drift from SUPPORTED_OPS.
    pub(super) async fn dispatch_single(
        &self,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let col = self.collection(&op.resource)?;
        match op.op {
            DataOperationKind::List => self.run_list(&col, op, identity).await,
            DataOperationKind::Get => self.run_get(&col, op, identity).await,
            DataOperationKind::Insert => self.run_insert(&col, op, identity).await,
            DataOperationKind::Update => self.run_update(&col, op, identity).await,
            DataOperationKind::Delete => self.run_delete(&col, op, identity).await,
            DataOperationKind::Upsert => self.run_upsert(&col, op, identity).await,
            DataOperationKind::Aggregate => self.run_aggregate(&col, op, identity).await,
            DataOperationKind::Batch => Err(DataPlaneError::InvalidRequest {
                message: "nested batches are not allowed".to_string(),
            }),
        }
    }

    /// Grouped aggregation lowered to a `$match → $group → $project` pipeline.
    /// The `$match` stage is the SAME tenant/owner-intersected filter every
    /// read uses, so aggregation cannot see rows a `list` could not. Output
    /// keys (group columns, aliases) are validated by [`safe_agg_key`] so no
    /// client text can smuggle a `$`-operator or a dotted path into the
    /// pipeline. `distinct` is not supported on mongo (clean 400, the SQL
    /// engines serve it).
    async fn run_aggregate(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let spec = op
            .aggregate
            .as_ref()
            .ok_or_else(|| DataPlaneError::InvalidRequest {
                message: "aggregate requires an `aggregate` spec".to_string(),
            })?;
        if spec.aggregates.is_empty() {
            return Err(DataPlaneError::InvalidRequest {
                message: "aggregate requires at least one aggregate function".to_string(),
            });
        }
        if spec.aggregates.iter().any(|a| a.distinct) {
            return Err(DataPlaneError::InvalidRequest {
                message: "distinct aggregates are not supported on mongodb".to_string(),
            });
        }
        let mut seen: std::collections::BTreeSet<&str> = std::collections::BTreeSet::new();
        for name in spec
            .group_by
            .iter()
            .map(String::as_str)
            .chain(spec.aggregates.iter().map(|a| a.alias.as_str()))
        {
            safe_agg_key(name)?;
            if !seen.insert(name) {
                return Err(DataPlaneError::InvalidRequest {
                    message: format!("duplicate aggregate output column '{name}'"),
                });
            }
        }

        let match_doc = build_tenant_filter(
            op.filter.as_ref(),
            identity,
            &identity.tenant_id,
            self.is_shared(&op.resource),
        )?;

        // `_id` carries the group key (null = single global group).
        let mut group = Document::new();
        if spec.group_by.is_empty() {
            group.insert("_id", Bson::Null);
        } else {
            let mut id_doc = Document::new();
            for col_name in &spec.group_by {
                id_doc.insert(col_name.clone(), format!("${col_name}"));
            }
            group.insert("_id", id_doc);
        }
        for agg in &spec.aggregates {
            let expr = build_mongo_aggregate_expr(agg)?;
            group.insert(agg.alias.clone(), expr);
        }

        // Flatten the group key back into named columns; drop `_id`.
        let mut project = doc! { "_id": 0 };
        for col_name in &spec.group_by {
            project.insert(col_name.clone(), format!("$_id.{col_name}"));
        }
        for agg in &spec.aggregates {
            project.insert(agg.alias.clone(), 1);
        }

        let limit = i64::from(op.limit.unwrap_or(1000).min(10_000));
        let mut pipeline = vec![
            doc! { "$match": match_doc },
            doc! { "$group": group },
            doc! { "$project": project },
        ];
        if let Some(sort_doc) = build_sort(op.sort.as_ref()) {
            pipeline.push(doc! { "$sort": sort_doc });
        }
        pipeline.push(doc! { "$limit": limit });

        let cursor = col.aggregate(pipeline).await.map_err(mongo_err)?;
        let docs: Vec<Document> = cursor.try_collect().await.map_err(mongo_err)?;
        let rows: Vec<Value> = docs.into_iter().map(normalize_doc).collect();
        let affected = rows.len() as u64;
        Ok(DataResult::new(rows, affected))
    }

    async fn run_list(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let filter = build_tenant_filter(
            op.filter.as_ref(),
            identity,
            &identity.tenant_id,
            self.is_shared(&op.resource),
        )?;
        let limit = op.limit.unwrap_or(100).min(1_000) as i64;
        let skip = op.offset.unwrap_or(0) as u64;
        let find_opts = FindOptions::builder()
            .limit(Some(limit))
            .skip(Some(skip))
            .sort(build_sort(op.sort.as_ref()))
            .build();

        let cursor = col
            .find(filter)
            .with_options(find_opts)
            .await
            .map_err(mongo_err)?;
        let docs: Vec<Document> = cursor.try_collect().await.map_err(mongo_err)?;
        let rows: Vec<Value> = docs.into_iter().map(normalize_doc).collect();
        let affected = rows.len() as u64;
        Ok(DataResult::new(rows, affected))
    }

    async fn run_get(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let filter = build_tenant_filter(
            op.filter.as_ref(),
            identity,
            &identity.tenant_id,
            self.is_shared(&op.resource),
        )?;
        let doc = col.find_one(filter).await.map_err(mongo_err)?;
        match doc {
            Some(d) => Ok(DataResult::new(vec![normalize_doc(d)], 1)),
            None => Ok(DataResult::new(vec![], 0)),
        }
    }

    async fn run_insert(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let data = op
            .data
            .as_ref()
            .ok_or_else(|| DataPlaneError::InvalidRequest {
                message: "insert requires operation.data".to_string(),
            })?;
        let doc = build_owned_doc(data, identity, &identity.tenant_id)?;
        let result = col.insert_one(doc.clone()).await.map_err(mongo_err)?;
        let mut out = doc;
        out.insert("_id", result.inserted_id);
        Ok(DataResult::new(vec![normalize_doc(out)], 1))
    }

    async fn run_update(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        require_row_filter(op.filter.as_ref(), "update")?;
        let filter = build_tenant_filter(op.filter.as_ref(), identity, &identity.tenant_id, false)?;
        let data = op
            .data
            .as_ref()
            .ok_or_else(|| DataPlaneError::InvalidRequest {
                message: "update requires operation.data".to_string(),
            })?;
        // Strip RESERVED_FIELDS (`_id`/`owner_id`/`tenant_id`) from the client
        // `$set` and re-inject the trusted owner/tenant, exactly as insert/upsert
        // do via `build_owned_doc`. Without this a client could `$set` a foreign
        // `owner_id`/`tenant_id` on its OWN (correctly owner-scoped) document and
        // re-home it into another tenant's namespace. `build_owned_doc` also runs
        // `reject_top_level_operators`, so the `$`-key rejection is preserved.
        let set_doc = build_owned_doc(data, identity, &identity.tenant_id)?;
        let update = bson::doc! { "$set": set_doc };
        let result = col.update_many(filter, update).await.map_err(mongo_err)?;
        Ok(DataResult::new(vec![], result.modified_count))
    }

    async fn run_delete(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        require_row_filter(op.filter.as_ref(), "delete")?;
        let filter = build_tenant_filter(op.filter.as_ref(), identity, &identity.tenant_id, false)?;
        let result = col.delete_many(filter).await.map_err(mongo_err)?;
        Ok(DataResult::new(vec![], result.deleted_count))
    }

    async fn run_upsert(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let data = op
            .data
            .as_ref()
            .ok_or_else(|| DataPlaneError::InvalidRequest {
                message: "upsert requires operation.data".to_string(),
            })?;
        let Value::Object(obj) = data else {
            return Err(DataPlaneError::InvalidRequest {
                message: "upsert requires data to be a JSON object".to_string(),
            });
        };
        // Upsert needs an identifier — `id` or `_id` from the client. It must be
        // a scalar: an upsert targets one specific document, and accepting an
        // object here would let a client inject query operators (`{$gt:""}`) into
        // the `_id` filter (the upsert path doesn't run `build_tenant_filter`).
        let mut filter = bson::doc! {};
        if let Some(id_val) = obj.get("id").or_else(|| obj.get("_id")) {
            if !matches!(id_val, Value::String(_) | Value::Number(_) | Value::Bool(_)) {
                return Err(DataPlaneError::InvalidRequest {
                    message: "upsert `id`/`_id` must be a scalar value".to_string(),
                });
            }
            filter.insert("_id", value_to_bson(id_val)?);
        }
        // Always enforce tenant scope on the filter side too.
        filter.insert("owner_id", MongoPool::owner(identity));
        filter.insert("tenant_id", identity.tenant_id.clone());

        let set_doc = build_owned_doc(data, identity, &identity.tenant_id)?;
        let update = bson::doc! { "$set": set_doc };
        let update_opts = UpdateOptions::builder().upsert(true).build();
        let result = col
            .update_one(filter, update)
            .with_options(update_opts)
            .await
            .map_err(mongo_err)?;
        Ok(DataResult::new(
            vec![],
            result.modified_count + u64::from(result.upserted_id.is_some()),
        ))
    }
}
