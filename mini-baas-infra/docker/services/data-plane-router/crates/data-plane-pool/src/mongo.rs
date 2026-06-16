//! MongoDB engine adapter — R3.
//!
//! Mirrors the design of [`crate::postgres`] but for the official `mongodb`
//! crate. The Rust driver already owns a connection pool per [`mongodb::Client`]
//! — we cache one Client per [`DatabaseMount::pool_key`] so the hot path never
//! pays the connect cost the legacy `MongodbEngine` TypeScript adapter does
//! on every request (`new MongoClient(uri).connect()` per call).
//!
//! Tenant isolation:
//!   * Every insert is decorated with `owner_id` and `tenant_id` from the
//!     verified [`RequestIdentity`] before reaching the wire — the document the
//!     client sent cannot override these fields.
//!   * Every read filter is intersected with the same fields, so a forged
//!     resource name still cannot leak cross-tenant rows.
//!
//! Pattern stack:
//!   * Adapter (GoF)       — implements [`EngineAdapter`].
//!   * Object Pool         — `mongodb::Client` is already a connection pool.
//!   * Strategy            — operation kind switches the executor branch.
//!   * Template Method     — `build_tenant_filter`/`build_owned_doc` shared
//!     across all read/write code paths.

use async_trait::async_trait;
use bson::{doc, Bson, Document};
use data_plane_core::{
    AggFunc, Aggregate, BatchItemOutcome, BatchItemStatus, BatchSummary, ColumnSchema,
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult,
    DatabaseMount, DdlColumnDef, EngineAdapter, EngineCapabilities, EngineHealth, EnginePool,
    NormalizedType, RequestIdentity, SchemaDdlOp, SchemaDdlRequest, SchemaDdlResult,
    SchemaDdlStatus, SchemaDescriptor, ScopeDirective, TableSchema, TxBeginRequest, TxHandle,
};
use futures::TryStreamExt;
use mongodb::{
    options::{ClientOptions, CreateCollectionOptions, FindOptions, UpdateOptions},
    results::{CollectionSpecification, CollectionType},
    Client, Collection, Database,
};
use serde_json::Value;
use std::{sync::Arc, time::Duration};

use crate::ident::quote_ident;
use crate::resolver::MountResolver;

/// Fields the server controls — strip from any client payload before write,
/// re-inject from the verified identity. Prevents tenant escape via document
/// shape (the equivalent of SQL injection for document stores).
const RESERVED_FIELDS: [&str; 3] = ["_id", "owner_id", "tenant_id"];

/// Trust fields enforced on FILTERS. `_id` is deliberately NOT here: it is the
/// row selector, not a trust field — stripping it turned every by-pk
/// get/update/delete into an all-owned-documents `update_many`/`delete_many`
/// (a single cell edit in the live UI would overwrite the whole collection).
const FILTER_TRUST_FIELDS: [&str; 2] = ["owner_id", "tenant_id"];

/// MongoDB query operators that are safe to accept from an untrusted client
/// filter — comparison, logical, element and array operators only. This is a
/// **default-deny allowlist**: any `$`-prefixed key not in this set is rejected,
/// which closes the NoSQL-injection surface of the raw `bson::to_document`
/// passthrough — notably the evaluation operators `$where`/`$expr`/`$function`/
/// `$accumulator`/`$jsonSchema` that can execute server-side JavaScript or run
/// arbitrary expressions. (`$regex` is permitted as the standard pattern-search
/// operator; bounding its ReDoS cost is tracked with the shared-Filter follow-up.)
const SAFE_MONGO_OPERATORS: &[&str] = &[
    "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$nin", "$and", "$or", "$nor", "$not",
    "$exists", "$type", "$regex", "$options", "$all", "$elemMatch", "$size", "$mod", "$bitsAllSet",
    "$bitsAnySet", "$bitsAllClear", "$bitsAnyClear",
];

/// Rejects a write `data` document whose top-level keys include a `$`-prefixed
/// name. Such names are never valid stored field names (Mongo rejects them under
/// `$set` with a server error), so this turns a would-be 502 into a clean 400 —
/// keeping the write path symmetric with the filter allowlist. Dotted
/// (nested-path) keys are intentionally allowed: they are legitimate nested
/// updates and cannot escape tenancy (the trust fields are re-injected at the
/// top level).
fn reject_top_level_operators(data: &Value) -> DataPlaneResult<()> {
    if let Value::Object(map) = data {
        for key in map.keys() {
            if key.starts_with('$') {
                return Err(DataPlaneError::InvalidRequest {
                    message: format!("write data must not contain operator key '{key}'"),
                });
            }
        }
    }
    Ok(())
}

/// Recursively rejects any `$`-prefixed key in a client filter that is not in
/// [`SAFE_MONGO_OPERATORS`]. Walked before the filter is handed to
/// `bson::to_document`, so a `$where`/`$expr`/`$function` injection never reaches
/// the driver. Field names (non-`$` keys) are unrestricted — the danger is the
/// operators, and the trust fields are re-injected after this check.
fn reject_unsafe_operators(value: &Value) -> DataPlaneResult<()> {
    match value {
        Value::Object(map) => {
            for (key, val) in map {
                if key.starts_with('$') && !SAFE_MONGO_OPERATORS.contains(&key.as_str()) {
                    return Err(DataPlaneError::InvalidRequest {
                        message: format!("filter operator '{key}' is not permitted"),
                    });
                }
                reject_unsafe_operators(val)?;
            }
            Ok(())
        }
        Value::Array(items) => {
            for item in items {
                reject_unsafe_operators(item)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

/// Adapter that knows how to construct [`MongoPool`] instances from a
/// [`DatabaseMount`]. Held as `Arc<dyn EngineAdapter>` inside the registry.
pub struct MongoEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl MongoEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

/// The operation kinds the Mongo adapter dispatches — the single source of
/// truth shared by `execute`'s gate, the capability descriptor, and the
/// honesty test.
pub(crate) const SUPPORTED_OPS: &[DataOperationKind] = &[
    DataOperationKind::List,
    DataOperationKind::Get,
    DataOperationKind::Insert,
    DataOperationKind::Update,
    DataOperationKind::Delete,
    DataOperationKind::Upsert,
    DataOperationKind::Aggregate,
    DataOperationKind::Batch,
];

#[async_trait]
impl EngineAdapter for MongoEngineAdapter {
    fn engine(&self) -> &str {
        "mongodb"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::mongodb()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        // tenant_owned (no per-row owner scoping) is implemented for
        // PostgreSQL only so far — fail CLOSED here rather than silently
        // owner-scoping a mount that promised not to (wrong rows beat
        // surprising rows, but a clear error beats both).
        if !mount.isolation().owner_scoped() {
            return Err(DataPlaneError::NotImplemented {
                feature: "tenant_owned isolation on this engine (PostgreSQL only for now)"
                    .to_string(),
            });
        }
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        // Phase B: under SECURITY_MODE=max, refuse a DSN that disables TLS
        // verification (the mongodb driver verifies by default otherwise).
        crate::tls::reject_insecure_tls(
            &dsn,
            crate::tls::max_security(),
            &[
                "tlsinsecure=true",
                "tlsallowinvalidcertificates=true",
                "tlsallowinvalidhostnames=true",
            ],
        )?;
        let mut options = ClientOptions::parse(&dsn).await.map_err(|e| {
            DataPlaneError::Backend {
                message: format!("invalid mongo URI: {e}"),
            }
        })?;
        // Bound concurrent connections per mount via pool policy; the
        // driver already enforces this efficiently.
        options.max_pool_size = Some(mount.pool_policy.max);
        options.min_pool_size = Some(mount.pool_policy.min);
        options.server_selection_timeout = Some(Duration::from_millis(
            mount.pool_policy.idle_ttl_ms.max(5_000),
        ));
        options.app_name = Some(format!("mini-baas/{}", mount.id));

        let client = Client::with_options(options).map_err(|e| DataPlaneError::Backend {
            message: format!("mongo client init failed: {e}"),
        })?;

        // Database name resolution mirrors the TypeScript adapter: take the
        // URI path component, fall back to "test" so misconfigured mounts
        // surface a backend error, not a panic.
        //
        // schema_per_tenant: the engine-neutral scope directive selects a
        // per-tenant database (`tenant_<id>`) instead of the DSN-default db.
        // The namespace is derived from the mount's tenant_id (identity-
        // independent), so it's stable for the pool's lifetime and resolved
        // once here. For shared_rls / db_per_tenant the directive is `None` →
        // the DSN-default db, byte-identical to before G5.
        let db_name = resolve_namespace(&mount).unwrap_or_else(|| parse_db_name(&dsn));
        let shared_pool = crate::pools_shared(&mount);

        Ok(Box::new(MongoPool {
            mount_id: mount.id.clone(),
            tenant_id: mount.tenant_id.clone(),
            shared_pool,
            client,
            db_name,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth {
            engine: "mongodb".to_string(),
            mount_id: pool.mount_id().to_string(),
            status: "unknown".to_string(),
        })
    }
}

/// Single mount, single Mongo Client (which itself owns the connection pool).
pub struct MongoPool {
    mount_id: String,
    tenant_id: String,
    /// True for a SHARE_POOLS shared_rls pool serving many tenants: the
    /// single-owner `check_tenant` assertion is skipped AND the per-request
    /// `tenant_id`/`owner_id` stamp is sourced from the request identity (not
    /// this field) so isolation travels with the request. See
    /// `crate::pools_shared` and the postgres adapter.
    shared_pool: bool,
    client: Client,
    db_name: String,
}

impl MongoPool {
    fn collection(&self, name: &str) -> DataPlaneResult<Collection<Document>> {
        // `quote_ident` rejects names with `$`, `.`, control chars etc.
        let safe = quote_ident(name)?;
        // quote_ident wraps in `"..."` for SQL; strip them for Mongo.
        let trimmed = safe.trim_matches('"').to_string();
        Ok(self.client.database(&self.db_name).collection(&trimmed))
    }

    fn owner(identity: &RequestIdentity) -> String {
        identity
            .user_id
            .clone()
            .unwrap_or_else(|| identity.tenant_id.clone())
    }

    /// Defense-in-depth tenant cross-check, skipped for a SHARE_POOLS shared_rls
    /// pool (multi-tenant by design — no single owner to assert). Unlike the
    /// relational adapters, mongo also stamps `tenant_id` onto every document;
    /// the call sites therefore source it from `identity.tenant_id` (not this
    /// pool field) so a shared pool stamps/filters each request's OWN tenant.
    fn check_tenant(&self, identity: &RequestIdentity) -> DataPlaneResult<()> {
        if self.shared_pool {
            return Ok(());
        }
        if identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match pool tenant".into(),
            });
        }
        Ok(())
    }
}

#[async_trait]
impl EnginePool for MongoPool {
    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        // Fail-closed cross-check: the dispatcher should already have rejected
        // identity/mount mismatches, but the pool is the second line of defense.
        self.check_tenant(&identity)?;

        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("mongo operation {:?}", operation.op),
            });
        }
        match operation.op {
            // Ordered, NON-atomic: mongo multi-document transactions need
            // session threading (deferred, like `begin()`), so batch items
            // run in order and execution stops at the first failure —
            // earlier items stay persisted, the summary says exactly which.
            DataOperationKind::Batch => self.run_batch(&operation, &identity).await,
            _ => self.dispatch_single(&operation, &identity).await,
        }
    }

    async fn begin(&self, _request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        // Mongo multi-statement transactions require threading a
        // `ClientSession` through every operation (the mongodb 2.x driver's
        // `*_with_session` variants), and per-tx pinning of a primary on a
        // replica set. That's a wider refactor than the PG/MySQL case and
        // is intentionally deferred. Single-document writes remain atomic.
        // Per-request grouping via the auto-commit `execute()` path is the
        // current parity guarantee.
        Err(DataPlaneError::NotImplemented {
            feature: "mongo multi-statement transactions (session-threading refactor pending)"
                .to_string(),
        })
    }

    async fn close(&self) -> DataPlaneResult<()> {
        // mongodb::Client closes its connections when dropped — no explicit
        // shutdown handshake required.
        Ok(())
    }

    /// Engine-agnostic schema introspection (M22). Lists collections of the
    /// pool's database (the per-tenant database for `schema_per_tenant`, the
    /// DSN-default otherwise — same namespace the request path uses). A
    /// collection with a `$jsonSchema` validator yields its declared columns
    /// exactly (`inferred: false`); otherwise the shape is inferred from a
    /// `$sample` of up to [`SCHEMA_SAMPLE_SIZE`] documents per-field majority
    /// type (`inferred: true`). `primary_key` is always `["_id"]`.
    async fn describe_schema(
        &self,
        identity: RequestIdentity,
    ) -> DataPlaneResult<SchemaDescriptor> {
        self.check_tenant(&identity)?;
        let db = self.client.database(&self.db_name);
        let mut specs: Vec<CollectionSpecification> = db
            .list_collections()
            .await
            .map_err(mongo_err)?
            .try_collect()
            .await
            .map_err(mongo_err)?;
        specs.sort_by(|a, b| a.name.cmp(&b.name));

        let mut tables = Vec::with_capacity(specs.len());
        for spec in specs {
            // Only real collections: views have no stable shape of their own
            // and system collections are internal.
            if !matches!(spec.collection_type, CollectionType::Collection) {
                continue;
            }
            if spec.name.starts_with("system.") {
                continue;
            }
            let json_schema = spec
                .options
                .validator
                .as_ref()
                .and_then(|v| v.get_document("$jsonSchema").ok());
            let columns = match json_schema {
                // Declared contract → exact mapping, not inference.
                Some(schema) => jsonschema_to_columns(schema),
                None => {
                    // The name comes from the server's own listCollections, so
                    // it is trusted — no quote_ident gate (which would reject
                    // legitimate dotted names).
                    let col: Collection<Document> = db.collection(&spec.name);
                    let cursor = col
                        .aggregate(vec![bson::doc! { "$sample": { "size": SCHEMA_SAMPLE_SIZE } }])
                        .await
                        .map_err(mongo_err)?;
                    let docs: Vec<Document> = cursor.try_collect().await.map_err(mongo_err)?;
                    infer_columns_from_samples(&docs)
                }
            };
            tables.push(TableSchema {
                name: spec.name,
                primary_key: vec!["_id".to_string()],
                columns,
            });
        }
        Ok(SchemaDescriptor { engine: "mongodb".to_string(), tables })
    }

    /// Engine-agnostic schema DDL (M22 step 2) over the collection's
    /// `$jsonSchema` validator — the same declared contract
    /// [`Self::describe_schema`] reads back, so DDL and introspection stay
    /// one source of truth:
    ///   * `create_table` → `createCollection` with a built validator
    ///     (owner_id string auto-appended, like the relational adapters);
    ///   * `drop_table`   → `drop()`;
    ///   * column ops     → read the current validator, transform it with
    ///     the pure `jsonschema_*` helpers, and `collMod` it back.
    /// Mongo's PK is always `_id`; a declared `primary_key` is accepted but
    /// only validated (a validator cannot express key constraints).
    async fn apply_schema_ddl(
        &self,
        ddl: SchemaDdlRequest,
        identity: RequestIdentity,
    ) -> DataPlaneResult<SchemaDdlResult> {
        self.check_tenant(&identity)?;
        // Same name gate the request path uses (rejects `$`, dots, etc.).
        let _ = self.collection(&ddl.table)?;
        let db = self.client.database(&self.db_name);
        match ddl.op {
            SchemaDdlOp::CreateTable => {
                let (columns, _primary_key) = ddl.require_create_spec()?;
                let schema = columns_to_jsonschema(columns)?;
                let options = CreateCollectionOptions::builder()
                    .validator(bson::doc! { "$jsonSchema": schema })
                    .build();
                db.create_collection(&ddl.table).with_options(options)
                    .await
                    .map_err(mongo_ddl_err)?;
            }
            SchemaDdlOp::DropTable => {
                db.collection::<Document>(&ddl.table)
                    .drop()
                    .await
                    .map_err(mongo_ddl_err)?;
            }
            SchemaDdlOp::AddColumn | SchemaDdlOp::AlterColumnType | SchemaDdlOp::DropColumn => {
                let current = self.collection_jsonschema(&db, &ddl.table).await?;
                let next = match ddl.op {
                    SchemaDdlOp::AddColumn => {
                        jsonschema_with_column_set(&current, ddl.require_column()?, ColumnMode::Add)?
                    }
                    SchemaDdlOp::AlterColumnType => jsonschema_with_column_set(
                        &current,
                        ddl.require_column()?,
                        ColumnMode::Alter,
                    )?,
                    SchemaDdlOp::DropColumn => {
                        jsonschema_with_column_dropped(&current, ddl.require_column_name()?)?
                    }
                    _ => unreachable!("outer match restricts to column ops"),
                };
                db.run_command(
                    bson::doc! { "collMod": &ddl.table, "validator": { "$jsonSchema": next } },
                )
                .await
                .map_err(mongo_ddl_err)?;
            }
        }
        Ok(SchemaDdlResult {
            op: ddl.op,
            table: ddl.table,
            status: SchemaDdlStatus::Applied,
        })
    }
}

/// How many documents `describe_schema` samples per collection when no
/// `$jsonSchema` validator declares the shape.
const SCHEMA_SAMPLE_SIZE: i32 = 200;

/// Maps a BSON type *name* (a `bsonType` string, or [`bson_value_type_name`]
/// output) to the engine-neutral [`NormalizedType`]. Pure.
fn bson_type_to_normalized(bson_type: &str) -> NormalizedType {
    match bson_type {
        "objectId" => NormalizedType::Objectid,
        "string" => NormalizedType::Text,
        "int" | "long" => NormalizedType::Integer,
        "double" => NormalizedType::Float,
        "decimal" => NormalizedType::Decimal,
        "bool" => NormalizedType::Boolean,
        "date" => NormalizedType::Datetime,
        "array" => NormalizedType::Array,
        "object" => NormalizedType::Json,
        _ => NormalizedType::Unknown,
    }
}

/// The `bsonType` name of a live BSON value, matching the names a
/// `$jsonSchema` validator uses. Pure.
fn bson_value_type_name(value: &Bson) -> &'static str {
    match value {
        Bson::Double(_) => "double",
        Bson::String(_) => "string",
        Bson::Array(_) => "array",
        Bson::Document(_) => "object",
        Bson::Boolean(_) => "bool",
        Bson::Null => "null",
        Bson::Int32(_) => "int",
        Bson::Int64(_) => "long",
        Bson::ObjectId(_) => "objectId",
        Bson::DateTime(_) => "date",
        Bson::Decimal128(_) => "decimal",
        _ => "unknown",
    }
}

/// Derives columns from a `$jsonSchema` validator document — the collection's
/// *declared* contract, so `inferred: false`. Handles `bsonType` as a string
/// or an array of strings (a `"null"` entry means nullable), `required` for
/// nullability, and `enum` for allowed values. Pure (unit-tested without a DB).
fn jsonschema_to_columns(schema: &Document) -> Vec<ColumnSchema> {
    let required: std::collections::BTreeSet<&str> = schema
        .get_array("required")
        .map(|arr| arr.iter().filter_map(Bson::as_str).collect())
        .unwrap_or_default();
    let Ok(props) = schema.get_document("properties") else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(props.len());
    for (name, spec) in props {
        let spec_doc = spec.as_document();
        // bsonType: "string" | ["string", "null"] | absent.
        let mut nullable_by_type = false;
        let bson_type = match spec_doc.and_then(|d| d.get("bsonType")) {
            Some(Bson::String(s)) => s.clone(),
            Some(Bson::Array(items)) => {
                nullable_by_type = items.iter().any(|b| b.as_str() == Some("null"));
                items
                    .iter()
                    .filter_map(Bson::as_str)
                    .find(|s| *s != "null")
                    .unwrap_or("unknown")
                    .to_string()
            }
            _ => "unknown".to_string(),
        };
        let enum_values: Option<Vec<String>> = spec_doc
            .and_then(|d| d.get_array("enum").ok())
            .map(|arr| {
                arr.iter()
                    .map(|b| match b {
                        Bson::String(s) => s.clone(),
                        other => other.to_string(),
                    })
                    .collect()
            });
        let normalized_type = if enum_values.is_some() {
            NormalizedType::Enum
        } else {
            bson_type_to_normalized(&bson_type)
        };
        out.push(ColumnSchema {
            name: name.clone(),
            native_type: bson_type,
            normalized_type,
            nullable: !required.contains(name.as_str()) || nullable_by_type,
            default: None,
            enum_values,
            references: None,
            inferred: false,
        });
    }
    out
}

/// Infers columns from sampled documents: per-field majority (non-null) BSON
/// type; a field absent from some documents or carrying nulls is nullable.
/// Always `inferred: true` — a statistical guess, not a declared contract.
/// Pure (unit-tested without a DB).
fn infer_columns_from_samples(docs: &[Document]) -> Vec<ColumnSchema> {
    use std::collections::BTreeMap;
    let total = docs.len();
    // field → (present count, null count, type → count)
    let mut fields: BTreeMap<String, (usize, usize, BTreeMap<&'static str, usize>)> =
        BTreeMap::new();
    for doc in docs {
        for (key, value) in doc {
            let entry = fields.entry(key.clone()).or_default();
            entry.0 += 1;
            let type_name = bson_value_type_name(value);
            if type_name == "null" {
                entry.1 += 1;
            } else {
                *entry.2.entry(type_name).or_default() += 1;
            }
        }
    }
    fields
        .into_iter()
        .map(|(name, (present, nulls, counts))| {
            // Majority vote over non-null types; BTreeMap iteration makes the
            // tie-break deterministic (first alphabetically wins).
            let majority = counts
                .iter()
                .max_by_key(|(_, count)| *count)
                .map(|(ty, _)| *ty)
                .unwrap_or("unknown");
            ColumnSchema {
                nullable: present < total || nulls > 0,
                native_type: majority.to_string(),
                normalized_type: bson_type_to_normalized(majority),
                name,
                default: None,
                enum_values: None,
                references: None,
                inferred: true,
            }
        })
        .collect()
}

impl MongoPool {
    /// The collection's current `$jsonSchema` validator, or the empty
    /// baseline (`{bsonType:"object", properties:{}}`) when it has none.
    /// A missing collection is a clean client error — column DDL cannot
    /// target a collection that does not exist.
    async fn collection_jsonschema(
        &self,
        db: &Database,
        name: &str,
    ) -> DataPlaneResult<Document> {
        let mut specs: Vec<CollectionSpecification> = db
            .list_collections().filter(bson::doc! { "name": name })
            .await
            .map_err(mongo_err)?
            .try_collect()
            .await
            .map_err(mongo_err)?;
        let Some(spec) = specs.pop() else {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("collection '{name}' does not exist"),
            });
        };
        Ok(spec
            .options
            .validator
            .as_ref()
            .and_then(|v| v.get_document("$jsonSchema").ok())
            .cloned()
            .unwrap_or_else(|| bson::doc! { "bsonType": "object", "properties": {} }))
    }

    /// Single (non-batch) operation dispatch — resolves the collection from
    /// the operation's own `resource`, so batch items can span collections.
    /// Exhaustive by enumeration so the match can't drift from SUPPORTED_OPS.
    async fn dispatch_single(
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

    /// Ordered, non-atomic batch: items execute in order; the first failure
    /// stops execution. Items already executed STAY PERSISTED (mongo has no
    /// cross-document rollback here) — the summary reports ok / error /
    /// skipped per item so the caller can reconcile.
    async fn run_batch(
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
            batch: Some(BatchSummary { atomic: false, items: outcomes }),
        })
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

        let match_doc = build_tenant_filter(op.filter.as_ref(), identity, &identity.tenant_id)?;

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
        Ok(DataResult {
            rows,
            affected_rows: affected,
            next_cursor: None,
            batch: None,
        })
    }

    async fn run_list(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let filter = build_tenant_filter(op.filter.as_ref(), identity, &identity.tenant_id)?;
        let limit = op.limit.unwrap_or(100).min(1_000) as i64;
        let skip = op.offset.unwrap_or(0) as u64;
        let find_opts = FindOptions::builder()
            .limit(Some(limit))
            .skip(Some(skip))
            .sort(build_sort(op.sort.as_ref()))
            .build();

        let cursor = col.find(filter).with_options(find_opts).await.map_err(mongo_err)?;
        let docs: Vec<Document> = cursor.try_collect().await.map_err(mongo_err)?;
        let rows: Vec<Value> = docs.into_iter().map(normalize_doc).collect();
        let affected = rows.len() as u64;
        Ok(DataResult {
            rows,
            affected_rows: affected,
            next_cursor: None,
            batch: None,
        })
    }

    async fn run_get(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let filter = build_tenant_filter(op.filter.as_ref(), identity, &identity.tenant_id)?;
        let doc = col.find_one(filter).await.map_err(mongo_err)?;
        match doc {
            Some(d) => Ok(DataResult {
                rows: vec![normalize_doc(d)],
                affected_rows: 1,
                next_cursor: None,
                batch: None,
            }),
            None => Ok(DataResult {
                rows: vec![],
                affected_rows: 0,
                next_cursor: None,
                batch: None,
            }),
        }
    }

    async fn run_insert(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let data = op.data.as_ref().ok_or_else(|| DataPlaneError::InvalidRequest {
            message: "insert requires operation.data".to_string(),
        })?;
        let doc = build_owned_doc(data, identity, &identity.tenant_id)?;
        let result = col.insert_one(doc.clone()).await.map_err(mongo_err)?;
        let mut out = doc;
        out.insert("_id", result.inserted_id);
        Ok(DataResult {
            rows: vec![normalize_doc(out)],
            affected_rows: 1,
            next_cursor: None,
            batch: None,
        })
    }

    async fn run_update(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        require_row_filter(op.filter.as_ref(), "update")?;
        let filter = build_tenant_filter(op.filter.as_ref(), identity, &identity.tenant_id)?;
        let data = op.data.as_ref().ok_or_else(|| DataPlaneError::InvalidRequest {
            message: "update requires operation.data".to_string(),
        })?;
        reject_top_level_operators(data)?;
        let set_doc = json_to_doc(data)?;
        let update = bson::doc! { "$set": set_doc };
        let result = col.update_many(filter, update).await.map_err(mongo_err)?;
        Ok(DataResult {
            rows: vec![],
            affected_rows: result.modified_count,
            next_cursor: None,
            batch: None,
        })
    }

    async fn run_delete(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        require_row_filter(op.filter.as_ref(), "delete")?;
        let filter = build_tenant_filter(op.filter.as_ref(), identity, &identity.tenant_id)?;
        let result = col.delete_many(filter).await.map_err(mongo_err)?;
        Ok(DataResult {
            rows: vec![],
            affected_rows: result.deleted_count,
            next_cursor: None,
            batch: None,
        })
    }

    async fn run_upsert(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let data = op.data.as_ref().ok_or_else(|| DataPlaneError::InvalidRequest {
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
            .update_one(filter, update).with_options(update_opts)
            .await
            .map_err(mongo_err)?;
        Ok(DataResult {
            rows: vec![],
            affected_rows: result.modified_count + u64::from(result.upserted_id.is_some()),
            next_cursor: None,
            batch: None,
        })
    }
}

fn mongo_err(e: mongodb::error::Error) -> DataPlaneError {
    classify_mongo_message(format!("mongo backend: {e}"))
}

/// Pure classifier behind [`mongo_err`] (testable without a driver error).
/// `$jsonSchema` validator rejections (server code 121 DocumentValidation-
/// Failure, "Document failed validation") and duplicate `_id` inserts (E11000
/// duplicate key) are the CALLER's fault — their values don't fit the
/// declared contract — so they map to 409 Conflict, not an engine 5xx (which
/// would make outbox clients retry a write that can never succeed).
fn classify_mongo_message(message: String) -> DataPlaneError {
    let lower = message.to_lowercase();
    if lower.contains("document failed validation")
        || lower.contains("documentvalidationfailure")
        || lower.contains("duplicate key error")
    {
        return DataPlaneError::Conflict { message };
    }
    DataPlaneError::Backend { message }
}

/// DDL-path error classifier (additive — the query path keeps [`mongo_err`]):
/// `createCollection` on an existing namespace is the caller's conflict
/// (409), and dropping / modifying a namespace that doesn't exist is a client
/// error (400), not an engine failure.
fn mongo_ddl_err(e: mongodb::error::Error) -> DataPlaneError {
    classify_mongo_ddl_message(format!("mongo backend: {e}"))
}

/// Pure message classifier behind [`mongo_ddl_err`] (testable without a
/// driver error). The server's NamespaceExists / NamespaceNotFound errors
/// carry these tokens in their message.
fn classify_mongo_ddl_message(message: String) -> DataPlaneError {
    let lower = message.to_lowercase();
    if lower.contains("already exists") || lower.contains("namespaceexists") {
        return DataPlaneError::Conflict { message };
    }
    if lower.contains("ns not found") || lower.contains("namespacenotfound") {
        return DataPlaneError::InvalidRequest { message };
    }
    DataPlaneError::Backend { message }
}

// ── M22 step 2: engine-agnostic schema DDL ($jsonSchema transforms, pure) ────

/// Whether [`jsonschema_with_column_set`] adds a new column (must NOT exist)
/// or alters an existing one (must exist).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ColumnMode {
    Add,
    Alter,
}

/// The `bsonType` name for a creatable DDL column. The exact inverse of
/// [`bson_type_to_normalized`] over the creatable set; `objectid`/`unknown`
/// are describe-only and rejected (enums use `enum:` instead of `bsonType`).
fn ddl_bson_type(def: &DdlColumnDef) -> DataPlaneResult<&'static str> {
    Ok(match def.normalized_type {
        NormalizedType::Text | NormalizedType::Uuid => "string",
        NormalizedType::Integer => "long",
        NormalizedType::Float => "double",
        NormalizedType::Decimal => "decimal",
        NormalizedType::Boolean => "bool",
        NormalizedType::Date | NormalizedType::Datetime => "date",
        NormalizedType::Json => "object",
        NormalizedType::Array => "array",
        NormalizedType::Enum => "string",
        NormalizedType::Objectid | NormalizedType::Unknown => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!(
                    "column '{}': normalized_type '{:?}' cannot be created on mongodb",
                    def.name, def.normalized_type
                ),
            })
        }
    })
}

/// One `$jsonSchema` property document for a DDL column. Nullable columns
/// declare `bsonType: [ty, "null"]` (absent OR explicit null both validate);
/// enum columns declare `enum: [...]` — exactly the shapes
/// [`jsonschema_to_columns`] reads back.
fn ddl_column_to_property(def: &DdlColumnDef) -> DataPlaneResult<Document> {
    if def.normalized_type == NormalizedType::Enum {
        let values = def
            .enum_values
            .as_deref()
            .filter(|v| !v.is_empty())
            .ok_or_else(|| DataPlaneError::InvalidRequest {
                message: format!("enum column '{}' requires non-empty enum_values", def.name),
            })?;
        return Ok(bson::doc! { "enum": values });
    }
    let ty = ddl_bson_type(def)?;
    Ok(if def.nullable {
        bson::doc! { "bsonType": [ty, "null"] }
    } else {
        bson::doc! { "bsonType": ty }
    })
}

/// Builds the full `$jsonSchema` for `create_table` from its columns,
/// auto-appending a nullable `owner_id` string when the caller didn't declare
/// one — matching the platform's owner-scoped write path (every Mongo write
/// injects `owner_id`/`tenant_id`).
fn columns_to_jsonschema(columns: &[DdlColumnDef]) -> DataPlaneResult<Document> {
    let mut properties = Document::new();
    let mut required: Vec<String> = Vec::new();
    let mut has_owner = false;
    for def in columns {
        if def.name == "owner_id" {
            has_owner = true;
        }
        properties.insert(def.name.clone(), ddl_column_to_property(def)?);
        if !def.nullable {
            required.push(def.name.clone());
        }
    }
    if !has_owner {
        properties.insert("owner_id", bson::doc! { "bsonType": ["string", "null"] });
    }
    let mut schema = bson::doc! { "bsonType": "object", "properties": properties };
    if !required.is_empty() {
        schema.insert("required", required);
    }
    Ok(schema)
}

/// The `required` list of a `$jsonSchema`, as owned strings.
fn jsonschema_required(schema: &Document) -> Vec<String> {
    schema
        .get_array("required")
        .map(|arr| arr.iter().filter_map(Bson::as_str).map(str::to_string).collect())
        .unwrap_or_default()
}

/// Returns a new `$jsonSchema` with `def` set (added or altered). `Add`
/// refuses an existing column (409 — same conflict PG raises for a duplicate
/// column); `Alter` refuses a missing one (400).
fn jsonschema_with_column_set(
    schema: &Document,
    def: &DdlColumnDef,
    mode: ColumnMode,
) -> DataPlaneResult<Document> {
    let mut out = schema.clone();
    let mut properties = out.get_document("properties").cloned().unwrap_or_default();
    let exists = properties.contains_key(&def.name);
    match mode {
        ColumnMode::Add if exists => {
            return Err(DataPlaneError::Conflict {
                message: format!("column '{}' already exists", def.name),
            })
        }
        ColumnMode::Alter if !exists => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("column '{}' does not exist", def.name),
            })
        }
        _ => {}
    }
    properties.insert(def.name.clone(), ddl_column_to_property(def)?);
    out.insert("bsonType", "object");
    out.insert("properties", properties);
    let mut required = jsonschema_required(&out);
    required.retain(|r| r != &def.name);
    if !def.nullable {
        required.push(def.name.clone());
    }
    if required.is_empty() {
        out.remove("required");
    } else {
        out.insert("required", required);
    }
    Ok(out)
}

/// Returns a new `$jsonSchema` with `name` removed (property + required).
/// A missing column is a client error.
fn jsonschema_with_column_dropped(schema: &Document, name: &str) -> DataPlaneResult<Document> {
    let mut out = schema.clone();
    let mut properties = out.get_document("properties").cloned().unwrap_or_default();
    if properties.remove(name).is_none() {
        return Err(DataPlaneError::InvalidRequest {
            message: format!("column '{name}' does not exist"),
        });
    }
    out.insert("bsonType", "object");
    out.insert("properties", properties);
    let required: Vec<String> = jsonschema_required(&out)
        .into_iter()
        .filter(|r| r != name)
        .collect();
    if required.is_empty() {
        out.remove("required");
    } else {
        out.insert("required", required);
    }
    Ok(out)
}

/// The per-tenant database name for a `schema_per_tenant` mount, or `None`
/// for any other strategy (→ caller keeps the DSN-default db, parity). Built by
/// consuming the engine-neutral [`ScopeDirective`] so the isolation policy
/// stays defined in one place (`data-plane-core`). The namespace is derived
/// from the mount's `tenant_id`, which we feed in as the scoping identity since
/// Mongo's namespace selection is per-mount, not per-request.
fn resolve_namespace(mount: &DatabaseMount) -> Option<String> {
    let identity = RequestIdentity {
        tenant_id: mount.tenant_id.clone(),
        project_id: mount.project_id.clone(),
        app_id: None,
        user_id: None,
        roles: vec![],
        scopes: vec![],
        source: data_plane_core::IdentitySource::ServiceToken,
    };
    match mount.isolation().scope(mount, &identity) {
        ScopeDirective::UseNamespace { namespace } => Some(namespace),
        ScopeDirective::None | ScopeDirective::SetSearchPath { .. } => None,
    }
}

fn parse_db_name(dsn: &str) -> String {
    // Strict-enough URI parsing: split off the path component after the host.
    if let Some(after_scheme) = dsn.split("://").nth(1) {
        if let Some((_, after_host)) = after_scheme.split_once('/') {
            let name = after_host.split('?').next().unwrap_or("");
            if !name.is_empty() {
                return name.to_string();
            }
        }
    }
    "test".to_string()
}

fn json_to_doc(value: &Value) -> DataPlaneResult<Document> {
    match value {
        Value::Object(_) => bson::to_document(value).map_err(|e| DataPlaneError::Backend {
            message: format!("json→bson document: {e}"),
        }),
        _ => Err(DataPlaneError::InvalidRequest {
            message: "expected JSON object".to_string(),
        }),
    }
}

fn value_to_bson(value: &Value) -> DataPlaneResult<Bson> {
    bson::to_bson(value).map_err(|e| DataPlaneError::Backend {
        message: format!("json→bson: {e}"),
    })
}

/// Strip server-controlled fields from a client payload, then re-inject the
/// trusted values so the wire document is always tenant-scoped.
fn build_owned_doc(
    data: &Value,
    identity: &RequestIdentity,
    tenant_id: &str,
) -> DataPlaneResult<Document> {
    reject_top_level_operators(data)?;
    let mut doc = json_to_doc(data)?;
    for field in RESERVED_FIELDS {
        doc.remove(field);
    }
    doc.insert("owner_id", MongoPool::owner(identity));
    doc.insert("tenant_id", tenant_id.to_string());
    Ok(doc)
}

/// No-full-collection guard for update/delete — parity with the relational
/// pools' "refusing full-table update" rule. The injected owner/tenant scope
/// is NOT row selectivity: without it, `filter: {}` rewrites every owned
/// document in one call. The filter must constrain on at least one field the
/// CLIENT chose (trust fields are stripped before querying, so they don't
/// count).
fn require_row_filter(filter: Option<&Value>, op_name: &str) -> DataPlaneResult<()> {
    let selective = filter
        .and_then(Value::as_object)
        .is_some_and(|map| map.keys().any(|key| !FILTER_TRUST_FIELDS.contains(&key.as_str())));
    if selective {
        return Ok(());
    }
    Err(DataPlaneError::InvalidRequest {
        message: format!(
            "{op_name} requires a non-empty `filter` (refusing full-collection {op_name})"
        ),
    })
}

/// Take the client filter (if any) and intersect it with the server-side
/// tenant scope so an attacker cannot drop the predicate.
/// Validates a client-supplied aggregate key (group column, field, alias)
/// before it becomes a BSON document KEY or a `$`-path: no `$` prefix (would
/// be parsed as an operator), no dots (would address a nested path), no NUL.
fn safe_agg_key(name: &str) -> DataPlaneResult<()> {
    let ok = !name.is_empty()
        && !name.starts_with('$')
        && !name.contains('.')
        && !name.contains('\0');
    if ok {
        Ok(())
    } else {
        Err(DataPlaneError::InvalidRequest {
            message: format!("invalid aggregate column name '{name}'"),
        })
    }
}

/// One `$group` accumulator from the allowlisted [`AggFunc`] enum.
/// `count` with no field is `{$sum: 1}`; `count(field)` counts documents
/// where the field is present and non-null (SQL `COUNT(col)` semantics).
fn build_mongo_aggregate_expr(agg: &Aggregate) -> DataPlaneResult<Bson> {
    if let Some(field) = agg.field.as_deref() {
        safe_agg_key(field)?;
    }
    let field_ref = |f: &str| Bson::String(format!("${f}"));
    let expr = match (agg.func, agg.field.as_deref()) {
        (AggFunc::Count, None) => doc! { "$sum": 1 },
        (AggFunc::Count, Some(f)) => doc! {
            "$sum": { "$cond": [ { "$gt": [ { "$ifNull": [ field_ref(f), Bson::Null ] }, Bson::Null ] }, 1, 0 ] }
        },
        (AggFunc::Sum, Some(f)) => doc! { "$sum": field_ref(f) },
        (AggFunc::Avg, Some(f)) => doc! { "$avg": field_ref(f) },
        (AggFunc::Min, Some(f)) => doc! { "$min": field_ref(f) },
        (AggFunc::Max, Some(f)) => doc! { "$max": field_ref(f) },
        (func, None) => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("aggregate '{func:?}' requires a `field`"),
            })
        }
    };
    Ok(Bson::Document(expr))
}

fn build_tenant_filter(
    filter: Option<&Value>,
    identity: &RequestIdentity,
    tenant_id: &str,
) -> DataPlaneResult<Document> {
    let mut doc = match filter {
        Some(v @ Value::Object(_)) => {
            // Default-deny operator allowlist BEFORE conversion → no `$where`/
            // `$expr`/`$function` injection reaches the driver.
            reject_unsafe_operators(v)?;
            json_to_doc(v)?
        }
        Some(other) => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("filter must be a JSON object, got {other:?}"),
            });
        }
        None => Document::new(),
    };
    // Mongo only understands $and/$or/$nor at the TOP level; any other
    // $-operator there (e.g. `$not`) is a driver error that would surface as
    // an opaque 502 — fail it closed as the 400 it really is.
    for key in doc.keys() {
        if key.starts_with('$') && !matches!(key.as_str(), "$and" | "$or" | "$nor") {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("filter operator '{key}' is not valid at the top level (use $and/$or/$nor)"),
            });
        }
    }
    // Strip any client-provided override of the trust fields. `_id` passes
    // through — it is how get/update/delete target one row (still ANDed with
    // the server-trusted owner/tenant scope below).
    for field in FILTER_TRUST_FIELDS {
        doc.remove(field);
    }
    if let Some(id) = doc.remove("_id") {
        doc.insert("_id", coerce_id_filter(id));
    }
    doc.insert("owner_id", MongoPool::owner(identity));
    doc.insert("tenant_id", tenant_id.to_string());
    Ok(doc)
}

/// `_id` values round-trip as strings on the wire (`normalize_doc` hex-encodes
/// `ObjectId`s), so a client filtering on a 24-hex string may mean EITHER the
/// literal string `_id` (seeded data) or the ObjectId it encodes (driver-
/// assigned ids). Match both; everything else passes through unchanged.
fn coerce_id_filter(id: Bson) -> Bson {
    match id {
        Bson::String(s) => match bson::oid::ObjectId::parse_str(&s) {
            Ok(oid) => bson::bson!({ "$in": [oid, s] }),
            Err(_) => Bson::String(s),
        },
        other => other,
    }
}

fn build_sort(sort: Option<&std::collections::BTreeMap<String, String>>) -> Option<Document> {
    let map = sort?;
    if map.is_empty() {
        return None;
    }
    let mut out = Document::new();
    for (k, dir) in map {
        let value: i32 = if dir.eq_ignore_ascii_case("desc") { -1 } else { 1 };
        out.insert(k, value);
    }
    Some(out)
}

fn normalize_doc(mut doc: Document) -> Value {
    // Map Mongo's `_id` → `id` so downstream contracts (SDK, dashboard, the graph)
    // see a uniform `id`. But NEVER clobber a client-supplied logical `id`: the
    // graph addresses a node by its logical id (the NodeId pk) and edges reference
    // that same id — overwriting it with the auto-generated ObjectId would
    // disconnect the node from its edges in `/graph/overview`. Only synthesize
    // `id` from `_id` when the document has no logical `id` of its own.
    let had_logical_id = doc.contains_key("id");
    if let Some(id) = doc.remove("_id") {
        if !had_logical_id {
            let id_str = match id {
                Bson::ObjectId(o) => o.to_hex(),
                Bson::String(s) => s,
                other => other.to_string(),
            };
            doc.insert("id", id_str);
        }
    }
    Bson::Document(doc).into_relaxed_extjson()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn probe_identity() -> RequestIdentity {
        RequestIdentity {
            tenant_id: "t1".to_string(),
            project_id: None,
            app_id: None,
            user_id: Some("api-key:k1".to_string()),
            roles: vec![],
            scopes: vec![],
            source: data_plane_core::IdentitySource::ServiceToken,
        }
    }

    #[test]
    fn tenant_filter_preserves_id_and_enforces_trust_fields() {
        // `_id` is the row selector and MUST survive: stripping it widened a
        // by-pk update/delete to every owned document. Client attempts to spoof
        // owner_id/tenant_id are still overridden by the verified identity.
        let client = json!({ "_id": "evt-000001", "owner_id": "spoof", "tenant_id": "spoof" });
        let doc = build_tenant_filter(Some(&client), &probe_identity(), "t1").unwrap();
        assert_eq!(doc.get_str("_id").unwrap(), "evt-000001");
        assert_eq!(doc.get_str("owner_id").unwrap(), "api-key:k1");
        assert_eq!(doc.get_str("tenant_id").unwrap(), "t1");
    }

    #[test]
    fn shared_pool_stamps_and_filters_each_requests_own_tenant() {
        // SHARE_POOLS isolation proof: the adapter's call sites now pass
        // `&identity.tenant_id` (not the pool's `self.tenant_id`) into
        // build_owned_doc / build_tenant_filter, so ONE pool shared across
        // tenants stamps + filters each request by its OWN tenant + owner.
        // Two distinct identities must produce two distinct stamps — never the
        // pool-opener's. This is what makes skipping the single-owner guard safe.
        let id_a = RequestIdentity {
            tenant_id: "tenant-a".into(),
            user_id: Some("api-key:a".into()),
            ..probe_identity()
        };
        let id_b = RequestIdentity {
            tenant_id: "tenant-b".into(),
            user_id: Some("api-key:b".into()),
            ..probe_identity()
        };
        let data = json!({ "kind": "login" });

        // Writes: each request stamps its own owner + tenant.
        let doc_a = build_owned_doc(&data, &id_a, &id_a.tenant_id).unwrap();
        let doc_b = build_owned_doc(&data, &id_b, &id_b.tenant_id).unwrap();
        assert_eq!(doc_a.get_str("tenant_id").unwrap(), "tenant-a");
        assert_eq!(doc_a.get_str("owner_id").unwrap(), "api-key:a");
        assert_eq!(doc_b.get_str("tenant_id").unwrap(), "tenant-b");
        assert_eq!(doc_b.get_str("owner_id").unwrap(), "api-key:b");

        // Reads: each request filters by its own owner + tenant — so tenant-a
        // can never select tenant-b's documents through the shared pool.
        let filt_a = build_tenant_filter(Some(&json!({})), &id_a, &id_a.tenant_id).unwrap();
        assert_eq!(filt_a.get_str("tenant_id").unwrap(), "tenant-a");
        assert_eq!(filt_a.get_str("owner_id").unwrap(), "api-key:a");
        let filt_b = build_tenant_filter(Some(&json!({})), &id_b, &id_b.tenant_id).unwrap();
        assert_eq!(filt_b.get_str("tenant_id").unwrap(), "tenant-b");
        assert_eq!(filt_b.get_str("owner_id").unwrap(), "api-key:b");
    }

    #[test]
    fn validator_rejections_classify_as_conflict() {
        // `$jsonSchema` says no → the caller's values don't fit the declared
        // contract: 409, never an opaque 502 (verified live before the fix).
        let validation = classify_mongo_message(
            "mongo backend: WriteError { code: 121, message: \"Document failed validation\" }".into());
        assert!(matches!(validation, DataPlaneError::Conflict { .. }), "{validation:?}");
        let dup = classify_mongo_message(
            "mongo backend: E11000 duplicate key error collection: activity.notes".into());
        assert!(matches!(dup, DataPlaneError::Conflict { .. }), "{dup:?}");
        let other = classify_mongo_message("mongo backend: connection reset".into());
        assert!(matches!(other, DataPlaneError::Backend { .. }), "{other:?}");
    }

    #[test]
    fn update_delete_require_a_selective_filter() {
        // Parity with the relational no-full-table guard: `{}` (or trust-field
        //-only filters, which are stripped anyway) must not mass-write every
        // owned document. Verified live before the fix: filter {} modified 39
        // docs in one call.
        for bad in [None, Some(json!({})), Some(json!({ "owner_id": "spoof" }))] {
            let err = require_row_filter(bad.as_ref(), "update").unwrap_err();
            assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{bad:?} → {err:?}");
        }
        assert!(require_row_filter(Some(&json!({ "_id": "n-1" })), "update").is_ok());
        assert!(require_row_filter(Some(&json!({ "kind": "login" })), "delete").is_ok());
    }

    #[test]
    fn tenant_filter_rejects_unknown_top_level_operators() {
        // `$not` is operator-position-only in Mongo; at the top level the
        // driver errors out (opaque 502) — fail closed as a 400 instead.
        let bad = json!({ "$not": { "kind": { "$in": ["login"] } } });
        let err = build_tenant_filter(Some(&bad), &probe_identity(), "t1").unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{err:?}");
        // The real top-level combinators still pass.
        let ok = json!({ "$or": [{ "kind": "login" }, { "kind": "search" }] });
        assert!(build_tenant_filter(Some(&ok), &probe_identity(), "t1").is_ok());
    }

    #[test]
    fn tenant_filter_coerces_objectid_hex_to_dual_match() {
        // Wire `_id`s are strings (normalize_doc hex-encodes ObjectIds), so a
        // 24-hex value must match both the ObjectId and the literal string.
        let hex = "665f1e2a9b3c4d5e6f708192";
        let client = json!({ "_id": hex });
        let doc = build_tenant_filter(Some(&client), &probe_identity(), "t1").unwrap();
        let id = doc.get_document("_id").unwrap();
        let candidates = id.get_array("$in").unwrap();
        let oid = bson::oid::ObjectId::parse_str(hex).unwrap();
        assert!(candidates.contains(&Bson::ObjectId(oid)));
        assert!(candidates.contains(&Bson::String(hex.to_string())));
        // Non-hex pk strings stay literal (seeded ids like `evt-000001`).
        let plain = build_tenant_filter(Some(&json!({ "_id": "evt-1" })), &probe_identity(), "t1")
            .unwrap();
        assert_eq!(plain.get_str("_id").unwrap(), "evt-1");
    }

    #[test]
    fn rejects_javascript_and_expression_operators() {
        // The NoSQL-injection fix: code/expression operators are refused, at any
        // nesting depth, with a client error (400).
        for bad in [
            json!({ "$where": "this.x == 1" }),
            json!({ "$expr": { "$eq": ["$a", "$b"] } }),
            json!({ "name": { "$function": { "body": "f", "args": [], "lang": "js" } } }),
            json!({ "$or": [{ "x": 1 }, { "$where": "true" }] }), // nested under $or
            json!({ "a": { "b": { "$accumulator": {} } } }),       // deeply nested
        ] {
            let err = reject_unsafe_operators(&bad).unwrap_err();
            assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{bad}: {err:?}");
        }
    }

    #[test]
    fn allows_standard_query_operators() {
        for ok in [
            json!({ "age": { "$gte": 18 } }),
            json!({ "status": { "$in": ["a", "b"], "$nin": ["c"] } }),
            json!({ "$or": [{ "a": 1 }, { "b": { "$lt": 5 } }], "$nor": [{ "z": 9 }] }),
            json!({ "name": { "$regex": "^a", "$options": "i" } }),
            json!({ "tags": { "$elemMatch": { "$eq": "x" } } }),
            json!({ "plain": "equality", "n": 3 }),
        ] {
            assert!(reject_unsafe_operators(&ok).is_ok(), "{ok}");
        }
    }

    #[test]
    fn allowlist_is_exact_and_case_sensitive() {
        // `$jsonSchema` (eval) is denied; a case variant of a safe op is not a
        // real operator and is denied too (exact match) — both fail closed.
        assert!(reject_unsafe_operators(&json!({ "$jsonSchema": {} })).is_err());
        assert!(reject_unsafe_operators(&json!({ "a": { "$GTE": 1 } })).is_err());
        // a safe operator nested under an unsafe one is still rejected (key
        // checked before recursing).
        assert!(reject_unsafe_operators(&json!({ "$where": { "$eq": 1 } })).is_err());
    }

    #[test]
    fn write_data_rejects_top_level_operator_keys() {
        // The write-path symmetry fix: a `$`-prefixed top-level key in write data
        // is a clean 400, not a 502 from the driver.
        for bad in [json!({ "$rename": { "a": "b" } }), json!({ "$set": { "x": 1 } })] {
            assert!(
                matches!(
                    reject_top_level_operators(&bad).unwrap_err(),
                    DataPlaneError::InvalidRequest { .. }
                ),
                "{bad}"
            );
        }
        // ordinary and dotted (nested-path) keys are allowed.
        assert!(reject_top_level_operators(&json!({ "name": "x", "profile.age": 3 })).is_ok());
    }

    // --- M22 schema introspection: pure mappers ---

    #[test]
    fn jsonschema_maps_declared_columns_exactly() {
        let schema = bson::doc! {
            "bsonType": "object",
            "required": ["name", "qty"],
            "properties": {
                "name": { "bsonType": "string" },
                "qty": { "bsonType": "int" },
                "price": { "bsonType": "decimal" },
                "tags": { "bsonType": "array" },
                "meta": { "bsonType": "object" },
                "created_at": { "bsonType": "date" },
                "owner": { "bsonType": "objectId" },
                "active": { "bsonType": "bool" },
                "ratio": { "bsonType": "double" },
                "big": { "bsonType": "long" },
            }
        };
        let cols = jsonschema_to_columns(&schema);
        let by_name = |n: &str| cols.iter().find(|c| c.name == n).unwrap_or_else(|| panic!("{n}"));
        use NormalizedType as N;
        for (name, native, normalized, nullable) in [
            ("name", "string", N::Text, false),
            ("qty", "int", N::Integer, false),
            ("price", "decimal", N::Decimal, true),
            ("tags", "array", N::Array, true),
            ("meta", "object", N::Json, true),
            ("created_at", "date", N::Datetime, true),
            ("owner", "objectId", N::Objectid, true),
            ("active", "bool", N::Boolean, true),
            ("ratio", "double", N::Float, true),
            ("big", "long", N::Integer, true),
        ] {
            let col = by_name(name);
            assert_eq!(col.native_type, native, "{name}");
            assert_eq!(col.normalized_type, normalized, "{name}");
            assert_eq!(col.nullable, nullable, "{name}");
            assert!(!col.inferred, "{name}: jsonSchema columns are declared, not inferred");
            assert!(col.references.is_none() && col.default.is_none(), "{name}");
        }
    }

    #[test]
    fn jsonschema_enum_and_nullable_type_arrays() {
        let schema = bson::doc! {
            "bsonType": "object",
            "required": ["status", "note"],
            "properties": {
                "status": { "enum": ["pending", "paid"] },
                // ["string","null"] → string but nullable, even though required.
                "note": { "bsonType": ["string", "null"] },
            }
        };
        let cols = jsonschema_to_columns(&schema);
        let status = cols.iter().find(|c| c.name == "status").unwrap();
        assert_eq!(status.normalized_type, NormalizedType::Enum);
        assert_eq!(
            status.enum_values,
            Some(vec!["pending".to_string(), "paid".to_string()])
        );
        let note = cols.iter().find(|c| c.name == "note").unwrap();
        assert_eq!(note.normalized_type, NormalizedType::Text);
        assert!(note.nullable, "a 'null' bsonType entry means nullable");
        // No properties → no columns (never a panic).
        assert!(jsonschema_to_columns(&bson::doc! { "bsonType": "object" }).is_empty());
    }

    #[test]
    fn sample_inference_majority_type_and_nullability() {
        let docs = vec![
            bson::doc! { "n": 1_i32, "s": "a", "maybe": Bson::Null },
            bson::doc! { "n": 2_i32, "s": "b" },
            bson::doc! { "n": "three", "s": "c", "maybe": 5_i32 },
        ];
        let cols = infer_columns_from_samples(&docs);
        let by_name = |n: &str| cols.iter().find(|c| c.name == n).unwrap();
        // Majority of `n` values are int.
        let n = by_name("n");
        assert_eq!(n.normalized_type, NormalizedType::Integer);
        assert_eq!(n.native_type, "int");
        assert!(!n.nullable, "present in every doc, never null");
        assert!(n.inferred, "sample-based columns are inferred");
        // `maybe` is missing from one doc AND null in another → nullable.
        assert!(by_name("maybe").nullable);
        // Empty sample set → no columns.
        assert!(infer_columns_from_samples(&[]).is_empty());
    }

    // --- M22 step 2: schema DDL — pure $jsonSchema transforms ---

    use data_plane_core::DdlColumnDef;

    fn col(name: &str, ty: NormalizedType, nullable: bool) -> DdlColumnDef {
        DdlColumnDef {
            name: name.to_string(),
            normalized_type: ty,
            nullable,
            default: None,
            enum_values: None,
        }
    }

    #[test]
    fn ddl_property_mapping_golden_table() {
        use NormalizedType as N;
        for (ty, bson_ty) in [
            (N::Text, "string"),
            (N::Uuid, "string"),
            (N::Integer, "long"),
            (N::Float, "double"),
            (N::Decimal, "decimal"),
            (N::Boolean, "bool"),
            (N::Date, "date"),
            (N::Datetime, "date"),
            (N::Json, "object"),
            (N::Array, "array"),
        ] {
            assert_eq!(
                ddl_column_to_property(&col("c", ty, false)).unwrap(),
                bson::doc! { "bsonType": bson_ty },
                "{ty:?}"
            );
            // nullable columns accept null explicitly (bsonType array).
            assert_eq!(
                ddl_column_to_property(&col("c", ty, true)).unwrap(),
                bson::doc! { "bsonType": [bson_ty, "null"] },
                "nullable {ty:?}"
            );
        }
        // enum → `enum:` (no bsonType), and requires values.
        let mut status = col("status", NormalizedType::Enum, false);
        status.enum_values = Some(vec!["a".into(), "b".into()]);
        assert_eq!(
            ddl_column_to_property(&status).unwrap(),
            bson::doc! { "enum": ["a", "b"] }
        );
        assert!(ddl_column_to_property(&col("status", NormalizedType::Enum, false)).is_err());
        // describe-only types are rejected.
        for ty in [NormalizedType::Objectid, NormalizedType::Unknown] {
            assert!(matches!(
                ddl_column_to_property(&col("c", ty, false)).unwrap_err(),
                DataPlaneError::InvalidRequest { .. }
            ));
        }
    }

    #[test]
    fn create_table_jsonschema_appends_owner_and_round_trips_describe() {
        let columns = vec![
            col("name", NormalizedType::Text, false),
            col("qty", NormalizedType::Integer, true),
        ];
        let schema = columns_to_jsonschema(&columns).unwrap();
        assert_eq!(
            schema,
            bson::doc! {
                "bsonType": "object",
                "properties": {
                    "name": { "bsonType": "string" },
                    "qty": { "bsonType": ["long", "null"] },
                    "owner_id": { "bsonType": ["string", "null"] },
                },
                "required": ["name"],
            }
        );
        // Round trip through the M22 describe mapper: DDL writes exactly the
        // shapes describe_schema reads back.
        let described = jsonschema_to_columns(&schema);
        let by_name = |n: &str| described.iter().find(|c| c.name == n).unwrap();
        assert_eq!(by_name("name").normalized_type, NormalizedType::Text);
        assert!(!by_name("name").nullable);
        assert_eq!(by_name("qty").normalized_type, NormalizedType::Integer);
        assert!(by_name("qty").nullable);
        assert!(by_name("owner_id").nullable);
        // An explicit owner_id is respected, never duplicated.
        let explicit = columns_to_jsonschema(&[col("owner_id", NormalizedType::Text, false)]).unwrap();
        let props = explicit.get_document("properties").unwrap();
        assert_eq!(props.get_document("owner_id").unwrap(), &bson::doc! { "bsonType": "string" });
    }

    #[test]
    fn jsonschema_add_alter_drop_column_transforms() {
        let base = columns_to_jsonschema(&[col("name", NormalizedType::Text, false)]).unwrap();

        // add: new column lands in properties (+required when non-nullable).
        let added = jsonschema_with_column_set(
            &base,
            &col("qty", NormalizedType::Integer, false),
            ColumnMode::Add,
        )
        .unwrap();
        assert!(added.get_document("properties").unwrap().contains_key("qty"));
        assert_eq!(jsonschema_required(&added), vec!["name", "qty"]);
        // add of an existing column is a 409 conflict.
        assert!(matches!(
            jsonschema_with_column_set(&base, &col("name", NormalizedType::Text, true), ColumnMode::Add)
                .unwrap_err(),
            DataPlaneError::Conflict { .. }
        ));

        // alter: full target def replaces the property AND nullability.
        let altered = jsonschema_with_column_set(
            &added,
            &col("qty", NormalizedType::Text, true),
            ColumnMode::Alter,
        )
        .unwrap();
        assert_eq!(
            altered.get_document("properties").unwrap().get_document("qty").unwrap(),
            &bson::doc! { "bsonType": ["string", "null"] }
        );
        assert_eq!(jsonschema_required(&altered), vec!["name"], "now nullable → not required");
        // alter of a missing column is a 400.
        assert!(matches!(
            jsonschema_with_column_set(&base, &col("ghost", NormalizedType::Text, true), ColumnMode::Alter)
                .unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));

        // drop: property + required entry removed; missing column is a 400.
        let dropped = jsonschema_with_column_dropped(&added, "qty").unwrap();
        assert!(!dropped.get_document("properties").unwrap().contains_key("qty"));
        assert_eq!(jsonschema_required(&dropped), vec!["name"]);
        assert!(matches!(
            jsonschema_with_column_dropped(&added, "ghost").unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
        // dropping the LAST required column removes the (must-be-non-empty)
        // `required` key entirely instead of leaving an invalid empty array.
        let only = columns_to_jsonschema(&[col("name", NormalizedType::Text, false)]).unwrap();
        let none_required = jsonschema_with_column_dropped(&only, "name").unwrap();
        assert!(!none_required.contains_key("required"));
    }

    #[test]
    fn mongo_ddl_error_classifier_maps_namespace_errors() {
        // Pure classification by message (the live errors carry these tokens).
        assert!(matches!(
            classify_mongo_ddl_message("Collection already exists. NS: db.t".into()),
            DataPlaneError::Conflict { .. }
        ));
        assert!(matches!(
            classify_mongo_ddl_message("Command failed: ns not found".into()),
            DataPlaneError::InvalidRequest { .. }
        ));
        assert!(matches!(
            classify_mongo_ddl_message("socket closed".into()),
            DataPlaneError::Backend { .. }
        ));
    }
}
