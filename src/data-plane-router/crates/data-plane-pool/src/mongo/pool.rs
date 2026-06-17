//! The mount-scoped [`MongoPool`] and its [`EnginePool`] surface: per-request
//! tenant cross-check, operation dispatch (delegated to [`super::query`]), and
//! the M22 schema introspection / DDL endpoints over `$jsonSchema`.

use async_trait::async_trait;
use bson::Document;
use data_plane_core::{
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult, RequestIdentity,
    SchemaDdlOp, SchemaDdlRequest, SchemaDdlResult, SchemaDdlStatus, SchemaDescriptor, TableSchema,
    TxBeginRequest, TxHandle, EnginePool,
};
use futures::TryStreamExt;
use mongodb::{
    options::CreateCollectionOptions,
    results::{CollectionSpecification, CollectionType},
    Client, Collection, Database,
};

use crate::ident::quote_ident;

use super::convert::{infer_columns_from_samples, jsonschema_to_columns};
use super::error::{mongo_ddl_err, mongo_err};
use super::schema::{
    columns_to_jsonschema, jsonschema_with_column_dropped, jsonschema_with_column_set, ColumnMode,
};

/// How many documents `describe_schema` samples per collection when no
/// `$jsonSchema` validator declares the shape.
const SCHEMA_SAMPLE_SIZE: i32 = 200;

/// Single mount, single Mongo Client (which itself owns the connection pool).
pub struct MongoPool {
    pub(super) mount_id: String,
    pub(super) tenant_id: String,
    /// True for a SHARE_POOLS shared_rls pool serving many tenants: the
    /// single-owner `check_tenant` assertion is skipped AND the per-request
    /// `tenant_id`/`owner_id` stamp is sourced from the request identity (not
    /// this field) so isolation travels with the request. See
    /// `crate::pools_shared` and the postgres adapter.
    pub(super) shared_pool: bool,
    pub(super) client: Client,
    pub(super) db_name: String,
}

impl MongoPool {
    pub(super) fn collection(&self, name: &str) -> DataPlaneResult<Collection<Document>> {
        // `quote_ident` rejects names with `$`, `.`, control chars etc.
        let safe = quote_ident(name)?;
        // quote_ident wraps in `"..."` for SQL; strip them for Mongo.
        let trimmed = safe.trim_matches('"').to_string();
        Ok(self.client.database(&self.db_name).collection(&trimmed))
    }

    pub(super) fn owner(identity: &RequestIdentity) -> String {
        identity.owner_principal().to_string()
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

        if !super::SUPPORTED_OPS.contains(&operation.op) {
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
