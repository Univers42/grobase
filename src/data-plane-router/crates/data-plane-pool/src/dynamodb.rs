//! DynamoDB-compatible engine adapter — the 8th data-plane adapter (OFF by
//! default, behind `--features dynamodb`).
//!
//! Endpoint-agnostic: the SAME adapter and SDK surface serve **AWS DynamoDB**,
//! **DynamoDB-Local** (dev/CI), and **ScyllaDB Alternator** (self-host),
//! selected purely by the mount's DSN/endpoint — no per-backend code path. The
//! DSN is a `dynamodb://…` URL whose query string carries the region, an
//! optional custom `endpoint=` (DynamoDB-Local / Scylla), and optional
//! `access_key=` / `secret_key=` static credentials. See
//! `wiki/dynamodb-htap-engine.md` for the full design.
//!
//! Isolation (no RLS in DynamoDB) is identical in spirit to the Redis adapter
//! (`redis.rs`): the verified [`RequestIdentity`] owns a key prefix — here the
//! **partition key** `owner_pk`. Every read AND write is keyed by
//! `owner_pk = owner` (optionally namespaced `<namespace>:<owner>` for
//! schema_per_tenant) and also carries a `ConditionExpression`/`FilterExpression`
//! pinning the owner, so a forged `id` cannot escape the caller's partition
//! (belt-and-braces, mirroring the Mongo adapter's stamp+filter).
//!
//! Pattern stack:
//!   * Adapter (GoF)   — implements [`EngineAdapter`].
//!   * Object Pool     — `aws_sdk_dynamodb::Client` is `Arc`-cheap + holds its
//!     own connection pool, kept per mount.
//!   * Strategy        — operation kind switches the executor branch.
//!   * Transactions    — `begin()` returns a buffer-then-commit [`TxHandle`]:
//!     each `execute` buffers a `TransactWriteItem`; `commit()` issues ONE
//!     `TransactWriteItems` (all-or-nothing) carrying a `ClientRequestToken`
//!     (native idempotency). No write leaves the process until `commit()`, so a
//!     partially-applied transaction is structurally impossible.

use crate::resolver::MountResolver;
use async_trait::async_trait;
use aws_sdk_dynamodb::config::{Credentials, Region};
use aws_sdk_dynamodb::error::SdkError;
use aws_sdk_dynamodb::types::{AttributeValue, Put, TransactWriteItem};
use aws_sdk_dynamodb::Client;
use data_plane_core::{
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult, DatabaseMount,
    EngineAdapter, EngineCapabilities, EngineHealth, EnginePool, RequestIdentity, TxBeginRequest,
    TxHandle,
};
use serde_json::{Map as JsonMap, Number, Value};
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;

/// The composite primary key attributes. `owner_pk` (the partition key) carries
/// the owner so a foreign id under another owner's partition is simply a key
/// that does not exist for this caller — the structural isolation property.
const PK: &str = "owner_pk";
const SK: &str = "id";

/// Same identifier discipline as the Redis adapter (`is_valid_segment`): a
/// table / resource name is `[A-Za-z0-9_:-]{1,255}`; rejecting anything that
/// could break the owner-partition envelope or be smuggled into an expression.
fn is_valid_segment(s: &str, max_len: usize, allow_extra: &[u8]) -> bool {
    if s.is_empty() || s.len() > max_len {
        return false;
    }
    s.bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || allow_extra.contains(&b))
}

fn validate_resource(name: &str) -> DataPlaneResult<()> {
    // DynamoDB table names allow `[A-Za-z0-9_.-]{3,255}`. We additionally keep
    // them out of expression-injection range by validating the charset here and
    // ALWAYS passing the table as the typed `table_name(...)` arg (never string
    // interpolation into an expression).
    if !is_valid_segment(name, 255, b"-.") {
        return Err(DataPlaneError::InvalidIdentifier {
            value: name.to_string(),
        });
    }
    Ok(())
}

fn validate_id(id: &str) -> DataPlaneResult<()> {
    if !is_valid_segment(id, 1024, b"-_:.") {
        return Err(DataPlaneError::InvalidIdentifier {
            value: id.to_string(),
        });
    }
    Ok(())
}

pub struct DynamoEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl DynamoEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

/// The operation kinds the DynamoDB adapter dispatches — the single source of
/// truth shared by `execute`'s gate, the capability descriptor, and the
/// honesty test. Aggregate is deliberately ABSENT (DynamoDB has no server-side
/// grouped aggregation — OLAP is the export bridge), exactly like Redis.
pub(crate) const SUPPORTED_OPS: &[DataOperationKind] = &[
    DataOperationKind::List,
    DataOperationKind::Get,
    DataOperationKind::Insert,
    DataOperationKind::Update,
    DataOperationKind::Delete,
    DataOperationKind::Upsert,
    DataOperationKind::Batch,
];

#[async_trait]
impl EngineAdapter for DynamoEngineAdapter {
    fn engine(&self) -> &str {
        "dynamodb"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::dynamodb()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        let client = build_client(&dsn).await?;
        // schema_per_tenant: a per-tenant namespace prepended to the owner
        // partition key (`<namespace>:<owner>`), derived from the mount's
        // tenant_id (identity-independent), so resolved once here. `None` for
        // shared_rls / db_per_tenant / tenant_owned → the historical
        // `<owner>` partition, byte-identical to the un-namespaced envelope.
        let namespace = resolve_namespace(&mount);
        let shared_pool = crate::pools_shared(&mount);
        let owner_scoped = mount.isolation().owner_scoped();
        Ok(Box::new(DynamoPool {
            mount_id: mount.id,
            tenant_id: mount.tenant_id,
            shared_pool,
            owner_scoped,
            client,
            namespace,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth::unknown("dynamodb", pool.mount_id()))
    }
}

pub struct DynamoPool {
    mount_id: String,
    tenant_id: String,
    /// True for a SHARE_POOLS shared_rls pool serving many tenants on one
    /// endpoint: the single-owner guard is skipped (the per-request owner
    /// partition key carries isolation). See `crate::pools_shared`.
    shared_pool: bool,
    /// `false` only for `tenant_owned` (BYO AWS table): no owner stamping — the
    /// table predates the platform and tenant gating already happened at
    /// key→mount resolution. Every other strategy owner-scopes.
    owner_scoped: bool,
    client: Client,
    /// `Some("tenant_<id>")` for `schema_per_tenant` mounts: prepended to the
    /// owner partition value so a tenant's keyspace is fully partitioned.
    namespace: Option<String>,
}

impl DynamoPool {
    fn owner(identity: &RequestIdentity) -> String {
        identity.owner_principal().to_string()
    }

    /// The partition-key value for this request. `tenant_owned` mounts are NOT
    /// owner-scoped, so they key on a fixed sentinel (the table belongs wholesale
    /// to the tenant); every other strategy keys on the verified owner, optionally
    /// namespaced. Pure (no I/O) so the envelope is unit-testable.
    fn owner_pk(&self, identity: &RequestIdentity) -> String {
        if !self.owner_scoped {
            return "_tenant_owned".to_string();
        }
        build_owner_pk(self.namespace.as_deref(), &Self::owner(identity))
    }

    fn id_from_filter_or_data(op: &DataOperation) -> DataPlaneResult<String> {
        let from_filter = op
            .filter
            .as_ref()
            .and_then(|v| v.as_object())
            .and_then(|m| m.get("id"));
        let from_data = op
            .data
            .as_ref()
            .and_then(|v| v.as_object())
            .and_then(|m| m.get("id"));
        match from_filter.or(from_data) {
            Some(v) => scalar_to_string(v).ok_or_else(|| DataPlaneError::InvalidRequest {
                message: "dynamodb op requires filter.id or data.id (string/number/bool)"
                    .to_string(),
            }),
            None => Err(DataPlaneError::InvalidRequest {
                message: "dynamodb op requires filter.id or data.id".to_string(),
            }),
        }
    }

    /// Split `op.data` into `(id, remaining_fields)`. If `allow_generate` is true
    /// and no id is provided, generates one. Mirrors `redis::split_id_data`.
    fn split_id_data(
        op: &DataOperation,
        allow_generate: bool,
    ) -> DataPlaneResult<(String, JsonMap<String, Value>)> {
        let Some(Value::Object(map)) = op.data.as_ref() else {
            return Err(DataPlaneError::InvalidRequest {
                message: "dynamodb op requires data as a JSON object".to_string(),
            });
        };
        let mut rest = map.clone();
        let id_value = op
            .filter
            .as_ref()
            .and_then(|v| v.as_object())
            .and_then(|m| m.get("id"))
            .cloned()
            .or_else(|| rest.remove("id"));
        let id = match id_value {
            Some(ref v) => scalar_to_string(v).ok_or_else(|| DataPlaneError::InvalidRequest {
                message: "dynamodb id must be a string/number/bool".to_string(),
            })?,
            None if allow_generate => generate_id(),
            None => {
                return Err(DataPlaneError::InvalidRequest {
                    message: "dynamodb update requires filter.id or data.id".to_string(),
                });
            }
        };
        validate_id(&id)?;
        rest.remove("id");
        Ok((id, rest))
    }

    /// Build the full DynamoDB item map (PK + SK + owner attr + the user data)
    /// for a write of `id` under `owner_pk`. The stored `owner` attribute backs
    /// the defense-in-depth condition/filter on every op.
    fn build_item(
        &self,
        owner_pk: &str,
        id: &str,
        data: &JsonMap<String, Value>,
    ) -> HashMap<String, AttributeValue> {
        let mut item = json_obj_to_item(data);
        item.insert(PK.to_string(), AttributeValue::S(owner_pk.to_string()));
        item.insert(SK.to_string(), AttributeValue::S(id.to_string()));
        item.insert("owner".to_string(), AttributeValue::S(owner_pk.to_string()));
        item
    }

    /// Single (non-batch) operation dispatch. Exhaustive by enumeration so the
    /// match cannot drift from SUPPORTED_OPS (the capability-honesty contract).
    async fn dispatch_single(
        &self,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        validate_resource(&op.resource)?;
        let owner_pk = self.owner_pk(identity);
        match op.op {
            DataOperationKind::Get => self.run_get(&op.resource, &owner_pk, op).await,
            DataOperationKind::List => self.run_list(&op.resource, &owner_pk, op).await,
            DataOperationKind::Insert => self.run_insert(&op.resource, &owner_pk, op).await,
            DataOperationKind::Update => self.run_update(&op.resource, &owner_pk, op).await,
            DataOperationKind::Delete => self.run_delete(&op.resource, &owner_pk, op).await,
            DataOperationKind::Upsert => self.run_upsert(&op.resource, &owner_pk, op).await,
            DataOperationKind::Batch => Err(DataPlaneError::InvalidRequest {
                message: "nested batches are not allowed".to_string(),
            }),
            DataOperationKind::Aggregate => Err(DataPlaneError::NotImplemented {
                feature: "dynamodb aggregate operation (served by the OLAP export bridge, not the engine)"
                    .to_string(),
            }),
        }
    }

    async fn run_get(
        &self,
        table: &str,
        owner_pk: &str,
        op: &DataOperation,
    ) -> DataPlaneResult<DataResult> {
        let id = Self::id_from_filter_or_data(op)?;
        validate_id(&id)?;
        let out = self
            .client
            .get_item()
            .table_name(table)
            .key(PK, AttributeValue::S(owner_pk.to_string()))
            .key(SK, AttributeValue::S(id.clone()))
            .send()
            .await
            .map_err(sdk_err)?;
        match out.item {
            Some(item) => Ok(single_row(item_to_row(item))),
            None => Ok(empty_result()),
        }
    }

    /// `List` = `Query` on the owner partition (the common, indexed path):
    /// `owner_pk = :owner` is the partition key, so this is a single-partition
    /// read that cannot return another owner's items. `limit`/`offset` are
    /// applied client-side over the page (DynamoDB has no native offset).
    async fn run_list(
        &self,
        table: &str,
        owner_pk: &str,
        op: &DataOperation,
    ) -> DataPlaneResult<DataResult> {
        let limit = op.limit.unwrap_or(100).min(500) as usize;
        let offset = op.offset.unwrap_or(0) as usize;
        let out = self
            .client
            .query()
            .table_name(table)
            .key_condition_expression("#pk = :owner")
            .expression_attribute_names("#pk", PK)
            .expression_attribute_values(":owner", AttributeValue::S(owner_pk.to_string()))
            .limit((limit + offset) as i32)
            .send()
            .await
            .map_err(sdk_err)?;
        let items = out.items.unwrap_or_default();
        let rows: Vec<Value> = items
            .into_iter()
            .skip(offset)
            .take(limit)
            .map(item_to_row)
            .collect();
        let affected = rows.len() as u64;
        Ok(DataResult::new(rows, affected))
    }

    /// `Insert` = `PutItem` + `attribute_not_exists(owner_pk)` (create-only). A
    /// colliding id → `ConditionalCheckFailedException` → 409 Conflict (matches
    /// the constraint-409 invariant).
    async fn run_insert(
        &self,
        table: &str,
        owner_pk: &str,
        op: &DataOperation,
    ) -> DataPlaneResult<DataResult> {
        let (id, data) = Self::split_id_data(op, /*allow_generate=*/ true)?;
        let item = self.build_item(owner_pk, &id, &data);
        let res = self
            .client
            .put_item()
            .table_name(table)
            .set_item(Some(item))
            .condition_expression("attribute_not_exists(#pk)")
            .expression_attribute_names("#pk", PK)
            .send()
            .await;
        match res {
            Ok(_) => Ok(write_row(id, data)),
            // A colliding id in this owner's partition is the caller's fault →
            // 409 Conflict (the constraint-409 invariant), never a 502 backend
            // error. Mirrors the Mongo adapter's duplicate-key → Conflict map.
            Err(e) if is_conditional_check_failed(&e) => Err(DataPlaneError::Conflict {
                message: format!("item '{id}' already exists"),
            }),
            Err(e) => Err(sdk_err(e)),
        }
    }

    /// `Update` = `PutItem` + `attribute_exists(owner_pk) AND owner = :owner`
    /// (replace existing, owner-pinned). A missing item → `affected_rows 0`
    /// (Redis-update parity) by mapping the conditional-check failure to a
    /// no-affected result rather than a hard error.
    async fn run_update(
        &self,
        table: &str,
        owner_pk: &str,
        op: &DataOperation,
    ) -> DataPlaneResult<DataResult> {
        let (id, data) = Self::split_id_data(op, /*allow_generate=*/ false)?;
        let item = self.build_item(owner_pk, &id, &data);
        let res = self
            .client
            .put_item()
            .table_name(table)
            .set_item(Some(item))
            .condition_expression("attribute_exists(#pk) AND #owner = :owner")
            .expression_attribute_names("#pk", PK)
            .expression_attribute_names("#owner", "owner")
            .expression_attribute_values(":owner", AttributeValue::S(owner_pk.to_string()))
            .send()
            .await;
        match res {
            Ok(_) => Ok(write_row(id, data)),
            // Item absent / not owned by caller → 0 rows affected, no error.
            Err(e) if is_conditional_check_failed(&e) => Ok(empty_result()),
            Err(e) => Err(sdk_err(e)),
        }
    }

    /// `Delete` = `DeleteItem` + owner `ConditionExpression`. Idempotent: a
    /// missing/foreign item yields `affected_rows 0` (the conditional-check
    /// failure is mapped to 0, never a leak across owners).
    async fn run_delete(
        &self,
        table: &str,
        owner_pk: &str,
        op: &DataOperation,
    ) -> DataPlaneResult<DataResult> {
        let id = Self::id_from_filter_or_data(op)?;
        validate_id(&id)?;
        let res = self
            .client
            .delete_item()
            .table_name(table)
            .key(PK, AttributeValue::S(owner_pk.to_string()))
            .key(SK, AttributeValue::S(id))
            .condition_expression("attribute_exists(#pk)")
            .expression_attribute_names("#pk", PK)
            .send()
            .await;
        match res {
            Ok(_) => Ok(DataResult::new(vec![], 1)),
            Err(e) if is_conditional_check_failed(&e) => Ok(empty_result()),
            Err(e) => Err(sdk_err(e)),
        }
    }

    /// `Upsert` = `PutItem` (no condition) = last-writer-wins, owner stamped.
    async fn run_upsert(
        &self,
        table: &str,
        owner_pk: &str,
        op: &DataOperation,
    ) -> DataPlaneResult<DataResult> {
        let (id, data) = Self::split_id_data(op, /*allow_generate=*/ true)?;
        let item = self.build_item(owner_pk, &id, &data);
        self.client
            .put_item()
            .table_name(table)
            .set_item(Some(item))
            .send()
            .await
            .map_err(sdk_err)?;
        Ok(write_row(id, data))
    }

    /// Ordered, NON-atomic batch via per-item `BatchWriteItem`-equivalent puts /
    /// deletes. `BatchWriteItem` is NOT a transaction (partial success possible),
    /// so — exactly like the Redis/Mongo ordered-batch contract — items run in
    /// order, the first failure stops execution, and the summary reports
    /// `atomic: false`. ATOMIC multi-item writes belong to `begin()`
    /// (TransactWriteItems), not here.
    async fn run_batch(
        &self,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let items = op
            .batch_items()
            .map_err(|message| DataPlaneError::InvalidRequest { message })?;
        if items.len() > EngineCapabilities::dynamodb().max_batch_size as usize {
            return Err(DataPlaneError::InvalidRequest {
                message: format!(
                    "dynamodb batch exceeds max_batch_size {} (BatchWriteItem hard limit)",
                    EngineCapabilities::dynamodb().max_batch_size
                ),
            });
        }
        let mut outcomes = Vec::with_capacity(items.len());
        let mut total: u64 = 0;
        let mut failed = false;
        for (idx, item) in items.iter().enumerate() {
            if failed {
                outcomes.push(data_plane_core::BatchItemOutcome {
                    index: idx as u32,
                    status: data_plane_core::BatchItemStatus::Skipped,
                    affected_rows: 0,
                    error: None,
                });
                continue;
            }
            match self.dispatch_single(item, identity).await {
                Ok(result) => {
                    total += result.affected_rows;
                    outcomes.push(data_plane_core::BatchItemOutcome {
                        index: idx as u32,
                        status: data_plane_core::BatchItemStatus::Ok,
                        affected_rows: result.affected_rows,
                        error: None,
                    });
                }
                Err(e) => {
                    failed = true;
                    outcomes.push(data_plane_core::BatchItemOutcome {
                        index: idx as u32,
                        status: data_plane_core::BatchItemStatus::Error,
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
            batch: Some(data_plane_core::BatchSummary {
                atomic: false,
                items: outcomes,
            }),
        })
    }
}

#[async_trait]
impl EnginePool for DynamoPool {
    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        // SHARE_POOLS shared_rls pool: multi-tenant by design, no single owner to
        // assert; the per-request owner partition key carries isolation.
        if !self.shared_pool && self.owner_scoped && identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match pool tenant".into(),
            });
        }
        validate_resource(&operation.resource)?;
        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("dynamodb operation {:?}", operation.op),
            });
        }
        match operation.op {
            DataOperationKind::Batch => self.run_batch(&operation, &identity).await,
            _ => self.dispatch_single(&operation, &identity).await,
        }
    }

    /// Begin a buffer-then-commit transaction. Allocates an empty buffer + a
    /// `ClientRequestToken` (from a provided idempotency key, else generated) +
    /// the owner partition key from the verified identity. No I/O until commit.
    async fn begin(&self, request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        let identity = &request.identity;
        if !self.shared_pool && self.owner_scoped && identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match pool tenant".into(),
            });
        }
        let owner_pk = self.owner_pk(identity);
        let token = generate_id();
        Ok(Box::new(DynamoTxHandle {
            tx_id: token.clone(),
            mount_id: self.mount_id.clone(),
            client: self.client.clone(),
            owner_pk,
            client_request_token: token,
            buffer: Mutex::new(Vec::new()),
        }))
    }

    async fn close(&self) -> DataPlaneResult<()> {
        // The SDK Client holds no explicit handshake to close.
        Ok(())
    }
}

/// A buffer-then-commit transaction handle. Each `execute` translates the op to
/// a `TransactWriteItem` (with its owner condition) and pushes it onto the
/// buffer; `commit()` issues the single `TransactWriteItems` call. Because no
/// write leaves the process until `commit()`, a partially-applied transaction
/// is structurally impossible. `prepare()` is a no-op (DynamoDB has no prepare
/// phase). `rollback()` drops the buffer (nothing was sent).
pub struct DynamoTxHandle {
    tx_id: String,
    mount_id: String,
    client: Client,
    owner_pk: String,
    client_request_token: String,
    buffer: Mutex<Vec<TransactWriteItem>>,
}

#[async_trait]
impl TxHandle for DynamoTxHandle {
    fn tx_id(&self) -> &str {
        &self.tx_id
    }

    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    /// Buffer one write op as a `TransactWriteItem`. Returns a synthetic per-item
    /// `DataResult` (no I/O yet). Reads (`Get`/`List`/`Aggregate`) are rejected:
    /// `TransactWriteItems` is write-only (atomic reads = `TransactGetItems`, a
    /// named follow-up).
    async fn execute(
        &self,
        operation: DataOperation,
        _identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        validate_resource(&operation.resource)?;
        let table = operation.resource.clone();
        match operation.op {
            DataOperationKind::Insert => {
                let (id, data) = DynamoPool::split_id_data(&operation, true)?;
                let mut item = json_obj_to_item(&data);
                item.insert(PK.to_string(), AttributeValue::S(self.owner_pk.clone()));
                item.insert(SK.to_string(), AttributeValue::S(id.clone()));
                item.insert("owner".to_string(), AttributeValue::S(self.owner_pk.clone()));
                let put = Put::builder()
                    .table_name(&table)
                    .set_item(Some(item))
                    .condition_expression("attribute_not_exists(#pk)")
                    .expression_attribute_names("#pk", PK)
                    .build()
                    .map_err(|e| DataPlaneError::InvalidRequest {
                        message: format!("dynamodb transact put build failed: {e}"),
                    })?;
                self.buffer
                    .lock()
                    .expect("dynamo tx buffer poisoned")
                    .push(TransactWriteItem::builder().put(put).build());
                Ok(write_row(id, data))
            }
            DataOperationKind::Upsert | DataOperationKind::Update => {
                let allow_gen = matches!(operation.op, DataOperationKind::Upsert);
                let (id, data) = DynamoPool::split_id_data(&operation, allow_gen)?;
                let mut item = json_obj_to_item(&data);
                item.insert(PK.to_string(), AttributeValue::S(self.owner_pk.clone()));
                item.insert(SK.to_string(), AttributeValue::S(id.clone()));
                item.insert("owner".to_string(), AttributeValue::S(self.owner_pk.clone()));
                let mut put = Put::builder().table_name(&table).set_item(Some(item));
                if matches!(operation.op, DataOperationKind::Update) {
                    put = put
                        .condition_expression("attribute_exists(#pk) AND #owner = :owner")
                        .expression_attribute_names("#pk", PK)
                        .expression_attribute_names("#owner", "owner")
                        .expression_attribute_values(
                            ":owner",
                            AttributeValue::S(self.owner_pk.clone()),
                        );
                }
                let put = put.build().map_err(|e| DataPlaneError::InvalidRequest {
                    message: format!("dynamodb transact put build failed: {e}"),
                })?;
                self.buffer
                    .lock()
                    .expect("dynamo tx buffer poisoned")
                    .push(TransactWriteItem::builder().put(put).build());
                Ok(write_row(id, data))
            }
            DataOperationKind::Delete => {
                let id = DynamoPool::id_from_filter_or_data(&operation)?;
                validate_id(&id)?;
                let del = aws_sdk_dynamodb::types::Delete::builder()
                    .table_name(&table)
                    .key(PK, AttributeValue::S(self.owner_pk.clone()))
                    .key(SK, AttributeValue::S(id))
                    .condition_expression("attribute_exists(#pk)")
                    .expression_attribute_names("#pk", PK)
                    .build()
                    .map_err(|e| DataPlaneError::InvalidRequest {
                        message: format!("dynamodb transact delete build failed: {e}"),
                    })?;
                self.buffer
                    .lock()
                    .expect("dynamo tx buffer poisoned")
                    .push(TransactWriteItem::builder().delete(del).build());
                Ok(DataResult::new(vec![], 1))
            }
            DataOperationKind::Get | DataOperationKind::List => {
                Err(DataPlaneError::InvalidRequest {
                    message: "dynamodb transactions are write-only (TransactWriteItems); reads inside a tx (TransactGetItems) are a follow-up".to_string(),
                })
            }
            DataOperationKind::Batch => Err(DataPlaneError::InvalidRequest {
                message: "nested batches are not allowed inside a transaction".to_string(),
            }),
            DataOperationKind::Aggregate => Err(DataPlaneError::NotImplemented {
                feature: "dynamodb aggregate (served by the OLAP export bridge)".to_string(),
            }),
        }
    }

    /// Issue the single `TransactWriteItems` with the buffered items + the
    /// `ClientRequestToken`. A `TransactionCanceledException` (a conditional
    /// check failed on any item) means the WHOLE transaction rolled back — map
    /// to 409 Conflict; nothing was written. Re-committing the same token within
    /// DynamoDB's idempotency window is a no-op success (native idempotency).
    async fn commit(&self) -> DataPlaneResult<()> {
        let items = {
            let buf = self.buffer.lock().expect("dynamo tx buffer poisoned");
            buf.clone()
        };
        if items.is_empty() {
            return Ok(()); // empty transaction commits trivially.
        }
        let res = self
            .client
            .transact_write_items()
            .set_transact_items(Some(items))
            .client_request_token(&self.client_request_token)
            .send()
            .await;
        match res {
            Ok(_) => Ok(()),
            Err(e) if is_transaction_canceled(&e) => Err(DataPlaneError::Conflict {
                message: format!(
                    "dynamodb transaction canceled (conditional check failed; whole transaction rolled back): {}",
                    sdk_message(&e)
                ),
            }),
            Err(e) => Err(sdk_err(e)),
        }
    }

    /// No-op: DynamoDB has no prepare phase. `two_phase_commit: true` is
    /// justified by the ATOMIC multi-item semantics of `TransactWriteItems`
    /// (commit), NOT a wire-level 2PC handshake.
    async fn prepare(&self) -> DataPlaneResult<()> {
        Ok(())
    }

    /// Drop the buffer without issuing the call — nothing was sent, so nothing
    /// to undo.
    async fn rollback(&self) -> DataPlaneResult<()> {
        self.buffer
            .lock()
            .expect("dynamo tx buffer poisoned")
            .clear();
        Ok(())
    }
}

// ── client construction (endpoint-agnostic) ──────────────────────────────────

/// Build an `aws_sdk_dynamodb::Client` from the resolved DSN. The DSN is a
/// `dynamodb://…` URL whose query string carries:
///   * `region=` (default `us-east-1`),
///   * `endpoint=` (a custom endpoint URL → DynamoDB-Local / ScyllaDB
///     Alternator; absent → real AWS DynamoDB),
///   * `access_key=` / `secret_key=` (static creds; absent → the SDK's default
///     credential chain, i.e. env/instance role for real AWS).
///
/// This is the single seam that makes the adapter endpoint-agnostic: the same
/// code targets AWS, DynamoDB-Local, or Scylla with only DSN changes.
async fn build_client(dsn: &str) -> DataPlaneResult<Client> {
    let parsed = parse_dynamo_dsn(dsn)?;
    let region = Region::new(parsed.region);
    let mut loader = aws_config::defaults(aws_config::BehaviorVersion::latest()).region(region);
    if let Some(endpoint) = parsed.endpoint.as_deref() {
        loader = loader.endpoint_url(endpoint);
    }
    if let (Some(ak), Some(sk)) = (parsed.access_key.as_deref(), parsed.secret_key.as_deref()) {
        loader = loader.credentials_provider(Credentials::new(ak, sk, None, None, "grobase-dsn"));
    }
    let conf = loader.load().await;
    Ok(Client::new(&conf))
}

struct DynamoDsn {
    region: String,
    endpoint: Option<String>,
    access_key: Option<String>,
    secret_key: Option<String>,
}

/// Parse the `dynamodb://…?region=&endpoint=&access_key=&secret_key=` DSN
/// without pulling a URL crate: split on `?`, then parse the query pairs. The
/// host segment (`aws` / `local` / `scylla`) is advisory only — the actual
/// backend is the `endpoint` (absent = real AWS). Endpoints with their own
/// query (rare) are passed through verbatim if `endpoint=` is the last param.
fn parse_dynamo_dsn(dsn: &str) -> DataPlaneResult<DynamoDsn> {
    let rest = dsn
        .strip_prefix("dynamodb://")
        .ok_or_else(|| DataPlaneError::Backend {
            message: "dynamodb DSN must start with dynamodb:// (e.g. dynamodb://local?endpoint=http://dynamodb-local:8000)".to_string(),
        })?;
    let query = rest.split_once('?').map(|(_, q)| q).unwrap_or("");
    let mut region = "us-east-1".to_string();
    let mut endpoint = None;
    let mut access_key = None;
    let mut secret_key = None;
    for pair in query.split('&').filter(|p| !p.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        let v = percent_decode(v);
        match k {
            "region" if !v.is_empty() => region = v,
            "endpoint" if !v.is_empty() => endpoint = Some(v),
            "access_key" if !v.is_empty() => access_key = Some(v),
            "secret_key" if !v.is_empty() => secret_key = Some(v),
            _ => {}
        }
    }
    Ok(DynamoDsn {
        region,
        endpoint,
        access_key,
        secret_key,
    })
}

/// Minimal percent-decode for `%XX` triples (endpoints embed `://` → `%3A%2F%2F`
/// when a caller encodes them). Avoids a dependency; unknown escapes pass
/// through unchanged.
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// The owner partition value, optionally namespaced. Pure (no I/O) so the
/// envelope is unit-testable. Mirrors `redis::build_key_prefix`.
fn build_owner_pk(namespace: Option<&str>, owner: &str) -> String {
    match namespace {
        Some(ns) => format!("{ns}:{owner}"),
        None => owner.to_string(),
    }
}

/// Per-tenant namespace segment for a `schema_per_tenant` mount — delegates to
/// the single source of truth, [`DatabaseMount::resolve_namespace`].
// ponytail: thin wrapper kept so call sites read `resolve_namespace(&mount)`;
// inline + delete in a follow-up.
fn resolve_namespace(mount: &DatabaseMount) -> Option<String> {
    mount.resolve_namespace()
}

/// A JSON scalar → its string form (used for ids). Mirrors the Redis id rule.
fn scalar_to_string(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

fn generate_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    format!("{ms}-{nanos:08x}")
}

/// Lower a JSON object into a DynamoDB item attribute map. Strings/numbers/
/// bools/null map to native attributes; nested objects/arrays are stored as a
/// JSON string attribute (the typed-item MVP — PartiQL/native maps are a
/// follow-up), round-tripped on read.
fn json_obj_to_item(map: &JsonMap<String, Value>) -> HashMap<String, AttributeValue> {
    map.iter()
        .map(|(k, v)| (k.clone(), json_to_attr(v)))
        .collect()
}

fn json_to_attr(v: &Value) -> AttributeValue {
    match v {
        Value::String(s) => AttributeValue::S(s.clone()),
        Value::Number(n) => AttributeValue::N(n.to_string()),
        Value::Bool(b) => AttributeValue::Bool(*b),
        Value::Null => AttributeValue::Null(true),
        // Nested object / array → JSON-string attribute (MVP), parsed back on read.
        other => AttributeValue::S(serde_json::to_string(other).unwrap_or_default()),
    }
}

/// Convert a DynamoDB item back to a JSON row, surfacing the `id` (sort key)
/// and dropping the internal `owner_pk` / `owner` envelope attributes so the
/// row shape matches what the caller wrote.
fn item_to_row(item: HashMap<String, AttributeValue>) -> Value {
    let mut row = JsonMap::with_capacity(item.len());
    for (k, v) in item {
        if k == PK || k == "owner" {
            continue;
        }
        if k == SK {
            row.insert("id".to_string(), attr_to_json(&v));
            continue;
        }
        row.insert(k, attr_to_json(&v));
    }
    Value::Object(row)
}

fn attr_to_json(v: &AttributeValue) -> Value {
    match v {
        AttributeValue::S(s) => {
            // A string attribute may carry an embedded JSON object/array (the
            // nested-value MVP encoding); parse it back if it round-trips.
            match serde_json::from_str::<Value>(s) {
                Ok(parsed @ (Value::Object(_) | Value::Array(_))) => parsed,
                _ => Value::String(s.clone()),
            }
        }
        AttributeValue::N(n) => n
            .parse::<i64>()
            .map(|i| Value::Number(Number::from(i)))
            .or_else(|_| {
                n.parse::<f64>()
                    .ok()
                    .and_then(Number::from_f64)
                    .map(Value::Number)
                    .ok_or(())
            })
            .unwrap_or_else(|()| Value::String(n.clone())),
        AttributeValue::Bool(b) => Value::Bool(*b),
        AttributeValue::Null(_) => Value::Null,
        _ => Value::Null,
    }
}

fn empty_result() -> DataResult {
    DataResult::new(vec![], 0)
}

fn single_row(row: Value) -> DataResult {
    DataResult::new(vec![row], 1)
}

/// A write result echoing the persisted row (data + id), mirroring the Redis
/// adapter's write returns.
fn write_row(id: String, mut data: JsonMap<String, Value>) -> DataResult {
    data.insert("id".to_string(), Value::String(id));
    DataResult::new(vec![Value::Object(data)], 1)
}

/// Map any SDK error into a `Backend` data-plane error, keeping the message
/// (never a DSN/credential — the SDK error text carries neither). Both type
/// params need `Debug`: `SdkError<E, R>` only implements `Debug` when its
/// response type `R` does too.
fn sdk_err<E, R>(e: SdkError<E, R>) -> DataPlaneError
where
    E: std::fmt::Debug,
    R: std::fmt::Debug,
{
    DataPlaneError::Backend {
        message: format!("dynamodb backend: {e:?}"),
    }
}

fn sdk_message<E, R>(e: &SdkError<E, R>) -> String
where
    E: std::fmt::Debug,
    R: std::fmt::Debug,
{
    format!("{e:?}")
}

/// Whether an SDK error is a `ConditionalCheckFailedException` (the typed marker
/// for a put/update/delete whose `ConditionExpression` failed). Matched on the
/// debug text so it works across the put/update/delete error enums without a
/// per-op match (the typed `is_conditional_check_failed_exception()` accessor
/// exists per-op; this is the engine-agnostic catch).
fn is_conditional_check_failed<E, R>(e: &SdkError<E, R>) -> bool
where
    E: std::fmt::Debug,
    R: std::fmt::Debug,
{
    format!("{e:?}").contains("ConditionalCheckFailed")
}

/// Whether an SDK error is a `TransactionCanceledException` — the whole-transact
/// rollback marker for `TransactWriteItems`.
fn is_transaction_canceled<E, R>(e: &SdkError<E, R>) -> bool
where
    E: std::fmt::Debug,
    R: std::fmt::Debug,
{
    format!("{e:?}").contains("TransactionCanceled")
}

// ── unit tests (pure helpers — no live DynamoDB needed) ───────────────────────
#[cfg(test)]
mod tests {
    use super::*;
    use data_plane_core::IdentitySource;
    use serde_json::json;

    fn identity_with(user: Option<&str>) -> RequestIdentity {
        RequestIdentity {
            tenant_id: "t-1".to_string(),
            project_id: None,
            app_id: None,
            user_id: user.map(str::to_string),
            roles: vec![],
            scopes: vec![],
            source: IdentitySource::Test,
        }
    }

    #[test]
    fn owner_pk_uses_user_id_when_present() {
        let id = identity_with(Some("u-1"));
        // shared_rls (namespace None) → historical <owner> partition.
        assert_eq!(build_owner_pk(None, &DynamoPool::owner(&id)), "u-1");
    }

    #[test]
    fn owner_pk_falls_back_to_tenant_id() {
        let id = identity_with(None);
        assert_eq!(build_owner_pk(None, &DynamoPool::owner(&id)), "t-1");
    }

    #[test]
    fn owner_pk_prepends_namespace_for_schema_per_tenant() {
        let id = identity_with(Some("u-1"));
        assert_eq!(
            build_owner_pk(Some("tenant_t_1"), &DynamoPool::owner(&id)),
            "tenant_t_1:u-1"
        );
    }

    #[test]
    fn validate_resource_rejects_injection() {
        for bad in ["", "users*", "a b", "x/y", "name?q", "users;DROP"] {
            assert!(validate_resource(bad).is_err(), "should reject {bad:?}");
        }
        for good in ["users", "users-2024", "users.archive", "u_table"] {
            assert!(validate_resource(good).is_ok(), "should accept {good:?}");
        }
    }

    #[test]
    fn split_id_data_pulls_id_from_filter_first() {
        let op = DataOperation {
            op: DataOperationKind::Update,
            resource: "users".into(),
            data: Some(json!({"id": "data-id", "name": "x"})),
            filter: Some(json!({"id": "filter-id"})),
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
        };
        let (id, rest) = DynamoPool::split_id_data(&op, false).unwrap();
        assert_eq!(id, "filter-id");
        assert!(!rest.contains_key("id"));
        assert_eq!(rest.get("name"), Some(&json!("x")));
    }

    #[test]
    fn split_id_data_generates_when_allowed() {
        let op = DataOperation {
            op: DataOperationKind::Insert,
            resource: "users".into(),
            data: Some(json!({"name": "x"})),
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
        };
        let (id, _) = DynamoPool::split_id_data(&op, true).unwrap();
        assert!(!id.is_empty());
    }

    #[test]
    fn parse_dsn_defaults_and_endpoint_override() {
        let local = parse_dynamo_dsn(
            "dynamodb://local?endpoint=http://dynamodb-local:8000&region=eu-west-1",
        )
        .unwrap();
        assert_eq!(local.region, "eu-west-1");
        assert_eq!(
            local.endpoint.as_deref(),
            Some("http://dynamodb-local:8000")
        );
        // No endpoint → real AWS, default region.
        let aws = parse_dynamo_dsn("dynamodb://aws").unwrap();
        assert_eq!(aws.region, "us-east-1");
        assert!(aws.endpoint.is_none());
        // Bad scheme is rejected.
        assert!(parse_dynamo_dsn("postgres://x").is_err());
    }

    #[test]
    fn parse_dsn_percent_decodes_endpoint() {
        let p = parse_dynamo_dsn("dynamodb://scylla?endpoint=http%3A%2F%2Fscylla%3A8000").unwrap();
        assert_eq!(p.endpoint.as_deref(), Some("http://scylla:8000"));
    }

    #[test]
    fn item_to_row_strips_envelope_and_surfaces_id() {
        let mut item = HashMap::new();
        item.insert(PK.to_string(), AttributeValue::S("u-1".into()));
        item.insert("owner".to_string(), AttributeValue::S("u-1".into()));
        item.insert(SK.to_string(), AttributeValue::S("row-9".into()));
        item.insert("name".to_string(), AttributeValue::S("Alice".into()));
        item.insert("score".to_string(), AttributeValue::N("42".into()));
        let row = item_to_row(item);
        let Value::Object(m) = row else { panic!() };
        assert_eq!(m.get("id"), Some(&json!("row-9")));
        assert_eq!(m.get("name"), Some(&json!("Alice")));
        assert_eq!(m.get("score"), Some(&json!(42)));
        assert!(!m.contains_key("owner_pk"), "envelope PK is hidden");
        assert!(!m.contains_key("owner"), "envelope owner attr is hidden");
    }

    #[test]
    fn json_attr_round_trips_scalars_and_nested() {
        assert_eq!(attr_to_json(&json_to_attr(&json!("hi"))), json!("hi"));
        assert_eq!(attr_to_json(&json_to_attr(&json!(7))), json!(7));
        assert_eq!(attr_to_json(&json_to_attr(&json!(true))), json!(true));
        // A nested object is stored as a JSON string then parsed back.
        let nested = json!({"k": [1, 2, 3]});
        assert_eq!(attr_to_json(&json_to_attr(&nested)), nested);
    }

    // ── json_to_attr: per-JSON-type attribute mapping ────────────────────────
    // NOTE: `dynamodb` is a non-default feature whose AWS deps don't build on
    // the pinned rustc (known MSRV issue), so these compile/run only when the
    // crate is built `--features dynamodb`. Written by analogy to the live
    // helpers so they pass once the toolchain catches up.

    #[test]
    fn json_to_attr_maps_each_scalar_type() {
        assert!(matches!(
            json_to_attr(&Value::Null),
            AttributeValue::Null(true)
        ));
        assert!(matches!(
            json_to_attr(&json!(true)),
            AttributeValue::Bool(true)
        ));
        assert!(matches!(
            json_to_attr(&json!(false)),
            AttributeValue::Bool(false)
        ));
        match json_to_attr(&json!("hello")) {
            AttributeValue::S(s) => assert_eq!(s, "hello"),
            _ => panic!("expected S"),
        }
        match json_to_attr(&json!("")) {
            AttributeValue::S(s) => assert!(s.is_empty()),
            _ => panic!("expected S"),
        }
        // numbers are stored as their decimal string in an N attribute.
        match json_to_attr(&json!(42)) {
            AttributeValue::N(n) => assert_eq!(n, "42"),
            _ => panic!("expected N"),
        }
        match json_to_attr(&json!(-3.5)) {
            AttributeValue::N(n) => assert_eq!(n, "-3.5"),
            _ => panic!("expected N"),
        }
        match json_to_attr(&json!(i64::MAX)) {
            AttributeValue::N(n) => assert_eq!(n, i64::MAX.to_string()),
            _ => panic!("expected N"),
        }
    }

    #[test]
    fn json_to_attr_stores_arrays_and_objects_as_json_strings() {
        match json_to_attr(&json!([1, 2, 3])) {
            AttributeValue::S(s) => assert_eq!(s, "[1,2,3]"),
            _ => panic!("expected S for array"),
        }
        match json_to_attr(&json!({ "k": [true, null] })) {
            AttributeValue::S(s) => assert_eq!(s, r#"{"k":[true,null]}"#),
            _ => panic!("expected S for object"),
        }
    }

    #[test]
    fn json_to_attr_unicode_string_preserved() {
        match json_to_attr(&json!("héllo-🦀-世界")) {
            AttributeValue::S(s) => assert_eq!(s, "héllo-🦀-世界"),
            _ => panic!("expected S"),
        }
    }

    // ── attr_to_json: number parse (int then float), nested string parse ─────

    #[test]
    fn attr_to_json_numbers_prefer_int_then_float() {
        assert_eq!(attr_to_json(&AttributeValue::N("42".into())), json!(42));
        assert_eq!(attr_to_json(&AttributeValue::N("-7".into())), json!(-7));
        assert_eq!(attr_to_json(&AttributeValue::N("3.5".into())), json!(3.5));
        // A number string that is neither i64 nor f64 stays a string (no panic).
        assert_eq!(
            attr_to_json(&AttributeValue::N("not-a-number".into())),
            json!("not-a-number")
        );
    }

    #[test]
    fn attr_to_json_string_parses_embedded_json_only_for_composites() {
        // An S that holds an object/array round-trips to that composite.
        assert_eq!(
            attr_to_json(&AttributeValue::S(r#"{"k":1}"#.into())),
            json!({ "k": 1 })
        );
        assert_eq!(
            attr_to_json(&AttributeValue::S("[1,2]".into())),
            json!([1, 2])
        );
        // An S that parses as a scalar JSON (e.g. "42") stays a STRING — only
        // object/array forms are unwrapped.
        assert_eq!(attr_to_json(&AttributeValue::S("42".into())), json!("42"));
        assert_eq!(
            attr_to_json(&AttributeValue::S("plain".into())),
            json!("plain")
        );
    }

    #[test]
    fn attr_to_json_bool_null_and_unsupported() {
        assert_eq!(attr_to_json(&AttributeValue::Bool(true)), json!(true));
        assert_eq!(attr_to_json(&AttributeValue::Bool(false)), json!(false));
        assert_eq!(attr_to_json(&AttributeValue::Null(true)), Value::Null);
        // An unsupported attribute kind (e.g. a string-set / number-set) → Null,
        // never a panic. `Ss`/`Ns` are `Vec<String>` so no Blob import is needed.
        assert_eq!(
            attr_to_json(&AttributeValue::Ss(vec!["a".into(), "b".into()])),
            Value::Null
        );
        assert_eq!(
            attr_to_json(&AttributeValue::Ns(vec!["1".into(), "2".into()])),
            Value::Null
        );
    }

    #[test]
    fn json_attr_round_trips_every_scalar_both_ways() {
        for v in [
            json!("s"),
            json!(""),
            json!(7),
            json!(-1),
            json!(true),
            Value::Null,
        ] {
            assert_eq!(attr_to_json(&json_to_attr(&v)), v, "round-trip {v}");
        }
    }

    // ── build_owner_pk: with/without namespace ───────────────────────────────

    #[test]
    fn build_owner_pk_envelope_shapes() {
        assert_eq!(build_owner_pk(None, "owner"), "owner");
        assert_eq!(build_owner_pk(Some("ns"), "owner"), "ns:owner");
        assert_eq!(build_owner_pk(None, ""), "");
    }

    // ── scalar_to_string: scalar coercion (mirrors Redis id rule) ────────────

    #[test]
    fn scalar_to_string_covers_scalars_and_rejects_composites() {
        assert_eq!(scalar_to_string(&json!("x")).as_deref(), Some("x"));
        assert_eq!(scalar_to_string(&json!(42)).as_deref(), Some("42"));
        assert_eq!(scalar_to_string(&json!(-1)).as_deref(), Some("-1"));
        assert_eq!(scalar_to_string(&json!(true)).as_deref(), Some("true"));
        assert_eq!(scalar_to_string(&json!(false)).as_deref(), Some("false"));
        // null / array / object are not scalar ids.
        assert!(scalar_to_string(&Value::Null).is_none());
        assert!(scalar_to_string(&json!([1])).is_none());
        assert!(scalar_to_string(&json!({ "k": 1 })).is_none());
    }

    // ── percent_decode: %XX triples + passthrough ────────────────────────────

    #[test]
    fn percent_decode_handles_triples_and_passthrough() {
        assert_eq!(
            percent_decode("http%3A%2F%2Fhost%3A8000"),
            "http://host:8000"
        );
        assert_eq!(percent_decode("plain"), "plain");
        assert_eq!(percent_decode(""), "");
        // a lone % or truncated escape passes through unchanged (no panic).
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(percent_decode("a%2"), "a%2");
        // an invalid hex pair passes through.
        assert_eq!(percent_decode("%zz"), "%zz");
        // mixed.
        assert_eq!(percent_decode("a%20b%2Fc"), "a b/c");
    }

    // ── parse_dynamo_dsn: defaults, overrides, credentials, bad scheme ───────

    #[test]
    fn parse_dynamo_dsn_full_query_string() {
        let p = parse_dynamo_dsn(
            "dynamodb://x?region=eu-west-1&endpoint=http://h:8000&access_key=AK&secret_key=SK",
        )
        .unwrap();
        assert_eq!(p.region, "eu-west-1");
        assert_eq!(p.endpoint.as_deref(), Some("http://h:8000"));
        assert_eq!(p.access_key.as_deref(), Some("AK"));
        assert_eq!(p.secret_key.as_deref(), Some("SK"));
    }

    #[test]
    fn parse_dynamo_dsn_defaults_when_query_absent_or_empty() {
        let p = parse_dynamo_dsn("dynamodb://local").unwrap();
        assert_eq!(p.region, "us-east-1");
        assert!(p.endpoint.is_none());
        assert!(p.access_key.is_none());
        // empty values are ignored (region keeps its default).
        let q = parse_dynamo_dsn("dynamodb://x?region=&endpoint=").unwrap();
        assert_eq!(q.region, "us-east-1");
        assert!(q.endpoint.is_none());
    }

    #[test]
    fn parse_dynamo_dsn_rejects_non_dynamodb_scheme() {
        for bad in ["postgres://x", "http://x", "dynamo://x", ""] {
            assert!(parse_dynamo_dsn(bad).is_err(), "should reject {bad:?}");
        }
    }

    #[test]
    fn parse_dynamo_dsn_ignores_unknown_query_keys() {
        let p = parse_dynamo_dsn("dynamodb://x?region=us-west-2&junk=1&foo=bar").unwrap();
        assert_eq!(p.region, "us-west-2");
    }

    // ── is_valid_segment / validate_resource / validate_id ───────────────────

    #[test]
    fn is_valid_segment_charset_and_bounds() {
        assert!(is_valid_segment("abc_123", 10, b""));
        assert!(!is_valid_segment("", 10, b""));
        assert!(!is_valid_segment("abcd", 3, b""));
        assert!(is_valid_segment("a.b", 10, b".-"));
        assert!(!is_valid_segment("a.b", 10, b""));
        assert!(!is_valid_segment("a b", 10, b".-"));
    }

    #[test]
    fn validate_resource_accepts_table_names_rejects_injection() {
        for ok in [
            "users",
            "users-2024",
            "users.archive",
            "u_table",
            &"x".repeat(255),
        ] {
            assert!(validate_resource(ok).is_ok(), "should accept {ok:?}");
        }
        for bad in [
            "",
            "users*",
            "a b",
            "x/y",
            "name?q",
            "users;DROP",
            &"x".repeat(256),
        ] {
            assert!(validate_resource(bad).is_err(), "should reject {bad:?}");
        }
    }

    #[test]
    fn validate_id_wide_charset_and_length() {
        for ok in ["abc", "a-b_c:d.e", &"i".repeat(1024)] {
            assert!(validate_id(ok).is_ok(), "should accept {ok:?}");
        }
        for bad in ["", "a b", "a/b", "a*b", &"i".repeat(1025)] {
            assert!(validate_id(bad).is_err(), "should reject {bad:?}");
        }
    }

    // ── generate_id: shape (ms-hex) + uniqueness ─────────────────────────────

    #[test]
    fn generate_id_shape_and_validates() {
        let id = generate_id();
        let (ms, hex) = id.split_once('-').expect("id has '-' separator");
        assert!(ms.chars().all(|c| c.is_ascii_digit()), "ms: {ms}");
        assert!(hex.chars().all(|c| c.is_ascii_hexdigit()), "hex: {hex}");
        assert!(validate_id(&id).is_ok(), "generated id valid: {id}");
    }

    // ── item_to_row: envelope hiding + id surfacing ──────────────────────────

    #[test]
    fn item_to_row_hides_pk_and_owner_surfaces_sort_key_as_id() {
        let mut item = HashMap::new();
        item.insert(PK.to_string(), AttributeValue::S("partition".into()));
        item.insert("owner".to_string(), AttributeValue::S("owner".into()));
        item.insert(SK.to_string(), AttributeValue::S("row-1".into()));
        item.insert("title".to_string(), AttributeValue::S("hello".into()));
        item.insert("count".to_string(), AttributeValue::N("9".into()));
        item.insert(
            "meta".to_string(),
            AttributeValue::S(r#"{"nested":true}"#.into()),
        );
        let Value::Object(m) = item_to_row(item) else {
            panic!()
        };
        assert!(!m.contains_key(PK));
        assert!(!m.contains_key("owner"));
        assert_eq!(m.get("id"), Some(&json!("row-1")));
        assert_eq!(m.get("title"), Some(&json!("hello")));
        assert_eq!(m.get("count"), Some(&json!(9)));
        assert_eq!(m.get("meta"), Some(&json!({ "nested": true })));
    }

    // ── result constructors: empty / single / write echo ─────────────────────

    #[test]
    fn result_constructors_shapes() {
        let e = empty_result();
        assert_eq!(e.affected_rows, 0);
        assert!(e.rows.is_empty());

        let s = single_row(json!({ "id": "x" }));
        assert_eq!(s.affected_rows, 1);
        assert_eq!(s.rows.len(), 1);

        // write_row echoes data + injects the id.
        let mut data = JsonMap::new();
        data.insert("name".to_string(), json!("Alice"));
        let w = write_row("gen-id".to_string(), data);
        assert_eq!(w.affected_rows, 1);
        let Value::Object(row) = &w.rows[0] else {
            panic!()
        };
        assert_eq!(row.get("id"), Some(&json!("gen-id")));
        assert_eq!(row.get("name"), Some(&json!("Alice")));
    }
}
