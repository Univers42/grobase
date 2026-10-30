/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   pool.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:27:52 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 23:10:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The mount-scoped [`MongoPool`] and its [`EnginePool`] surface: per-request
//! tenant cross-check, operation dispatch (delegated to [`super::query`]), and
//! the M22 schema introspection / DDL endpoints over `$jsonSchema`.

use async_trait::async_trait;
use bson::Document;
use data_plane_core::{
    normalise_version, DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult,
    DataResult, EnginePool, EngineProbe, RequestIdentity, SchemaDdlOp, SchemaDdlRequest,
    SchemaDdlResult, SchemaDdlStatus, SchemaDescriptor, TableSchema, TlsPosture, TxBeginRequest,
    TxHandle,
};
use futures::TryStreamExt;
use mongodb::{
    options::CreateCollectionOptions,
    results::{CollectionSpecification, CollectionType},
    Client, Collection, Database,
};

use crate::ident::quote_ident;

use super::convert::{infer_columns_from_samples, jsonschema_to_columns};
use super::error::{is_validation_failure, mongo_ddl_err, mongo_err};
use super::schema::{
    columns_to_jsonschema, jsonschema_with_column_dropped, jsonschema_with_column_set, ColumnMode,
};
use super::typed::coerce_to_validator;

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
    /// Collections on this mount whose READS skip owner-scoping (a shared
    /// catalog readable across owners) — the F1 `shared_resources` opt-in.
    /// Empty unless `DATA_PLANE_PER_TABLE_ISOLATION` is on AND the mount opted
    /// in → byte-parity (every read owner-scoped). Consulted by `is_shared`.
    pub(super) shared_resources: std::sync::Arc<[String]>,
    /// The TLS posture this pool was opened with (devil G4 P4): labelled
    /// from the parsed client options at open time, never from DSN text or
    /// what the server says. Read back by [`Self::probe`].
    pub(super) tls: TlsPosture,
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

    /// Reports whether `resource` is a shared collection whose reads skip
    /// owner-scoping (F1). Linear scan over the tiny opt-in list.
    pub(super) fn is_shared(&self, resource: &str) -> bool {
        self.shared_resources.iter().any(|t| t.as_str() == resource)
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
    async fn collection_jsonschema(&self, db: &Database, name: &str) -> DataPlaneResult<Document> {
        let mut specs: Vec<CollectionSpecification> = db
            .list_collections()
            .filter(bson::doc! { "name": name })
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

    /// After a write was rejected: converts `doc` to the collection's declared
    /// types so the caller can retry it once. The validator is read only on
    /// that path, so a write that already fits costs no extra round-trip.
    /// Hands the original error back when the rejection was not the validator's
    /// or when no value would change.
    pub(super) async fn coerce_after_rejection(
        &self,
        col: &Collection<Document>,
        doc: &mut Document,
        error: mongodb::error::Error,
    ) -> DataPlaneResult<()> {
        if !is_validation_failure(&error) {
            return Err(mongo_err(error));
        }
        let db = self.client.database(&self.db_name);
        let schema = self.collection_jsonschema(&db, col.name()).await?;
        if coerce_to_validator(doc, &schema) {
            Ok(())
        } else {
            Err(mongo_err(error))
        }
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
                        .aggregate(vec![
                            bson::doc! { "$sample": { "size": SCHEMA_SAMPLE_SIZE } },
                        ])
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
        Ok(SchemaDescriptor {
            engine: "mongodb".to_string(),
            tables,
        })
    }

    /// Read-only probe: the TLS label comes from the client options, not the server.
    async fn probe(&self) -> DataPlaneResult<EngineProbe> {
        let db = self.client.database("admin");
        let build_info = db.run_command(bson::doc! { "buildInfo": 1 }).await;
        let server_version = match build_info {
            Ok(doc) => match doc.get_str("version") {
                Ok(raw) => normalise_version(raw),
                Err(_) => "unknown".to_string(),
            },
            Err(_) => "unknown".to_string(),
        };
        Ok(EngineProbe {
            server_version,
            tls: self.tls,
            tls_version: None,
        })
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
                db.create_collection(&ddl.table)
                    .with_options(options)
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
                    SchemaDdlOp::AddColumn => jsonschema_with_column_set(
                        &current,
                        ddl.require_column()?,
                        ColumnMode::Add,
                    )?,
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
