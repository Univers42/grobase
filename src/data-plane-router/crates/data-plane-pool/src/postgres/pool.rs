//! The `EnginePool` trait impl for `PostgresPool`.
//!
//! A trait impl must live in one block, so all eight methods are here. The two
//! heaviest bodies (`describe_schema`, `apply_migration`) and the DDL-apply
//! body are factored into `pub(super)` free functions in [`super::schema`] —
//! the method keeps only its `check_tenant` guard and delegates, byte-for-byte
//! the same statements.

use super::adapter::{PgDialect, PostgresPool};
use super::{convert, schema, tx, BoxedParam};
use async_trait::async_trait;
use data_plane_core::{
    DataOperation, DataPlaneError, DataPlaneResult, DataResult, EnginePool, MigrationRequest,
    MigrationResult, RawStatement, RequestIdentity, SchemaDdlRequest, SchemaDdlResult,
    SchemaDescriptor, TxBeginRequest, TxHandle,
};
use serde_json::Value;
use tokio::sync::Mutex;

#[async_trait]
impl EnginePool for PostgresPool {
    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        self.check_tenant(&identity)?;
        let mut client = self.pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("pool checkout failed: {e}"),
        })?;

        let tx = client
            .transaction()
            .await
            .map_err(|e| convert::backend(&e))?;
        // deadpool wraps tokio_postgres::Transaction in a newtype that does
        // not implement GenericClient, so one explicit deref gets us back
        // to the underlying tokio_postgres::Transaction.
        tx::apply_rls_context(&*tx, &identity).await?;
        tx::apply_search_path(&*tx, self.search_path_schema.as_deref()).await?;

        let ctx = tx::ScopeCtx {
            isolation_owner_scoped: self.isolation.owner_scoped(),
            shared: &self.shared_resources,
            admin_bypass: self.admin_bypass,
            read_predicate: self.read_predicate,
        };
        let result = tx::dispatch_op(&*tx, &operation, &identity, &ctx).await?;

        tx.commit().await.map_err(|e| convert::backend(&e))?;
        Ok(result)
    }

    async fn begin(&self, request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        // Multi-statement transaction: check out a conn, run `BEGIN`, set RLS
        // GUCs once, then return a `PgTxHandle` that pins the conn until the
        // caller commits or rolls back. The transaction registry in the
        // server crate holds the handle by `tx_id`.
        self.check_tenant(&request.identity)?;
        let client = self.pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("pool checkout failed: {e}"),
        })?;

        // Use raw `BEGIN` rather than `client.transaction()` so we can drop
        // the conn back to the pool at COMMIT/ROLLBACK time without juggling
        // self-referential lifetimes.
        // CockroachDB serves SERIALIZABLE only (its descriptor advertises just
        // that level), and its default tx isolation already IS serializable, so
        // a plain `BEGIN` is both correct and avoids requesting a weaker level
        // the engine would silently upgrade. Postgres keeps the full mapping.
        let isolation_sql = match self.dialect {
            PgDialect::Cockroach => "BEGIN",
            PgDialect::Postgres => match request.isolation {
                Some(data_plane_core::IsolationLevel::ReadCommitted) => {
                    "BEGIN ISOLATION LEVEL READ COMMITTED"
                }
                Some(data_plane_core::IsolationLevel::RepeatableRead) => {
                    "BEGIN ISOLATION LEVEL REPEATABLE READ"
                }
                Some(data_plane_core::IsolationLevel::Serializable) => {
                    "BEGIN ISOLATION LEVEL SERIALIZABLE"
                }
                // PG has no "Snapshot" isolation level; fall back to RR which is
                // the closest snapshot semantics in standard PG.
                Some(data_plane_core::IsolationLevel::Snapshot) | None => "BEGIN",
            },
        };
        client
            .execute(isolation_sql, &[])
            .await
            .map_err(|e| convert::backend(&e))?;
        // deadpool::Object derefs to ClientWrapper which derefs to
        // tokio_postgres::Client (the GenericClient impl). Two derefs gets
        // us to &Client.
        tx::apply_rls_context(&**client, &request.identity).await?;
        tx::apply_search_path(&**client, self.search_path_schema.as_deref()).await?;
        // (the two-star form lands on the type GenericClient is implemented
        // for; one-star would still be ClientWrapper.)

        let tx_id = uuid::Uuid::now_v7().to_string();
        Ok(Box::new(tx::PgTxHandle {
            tx_id,
            mount_id: self.mount_id.clone(),
            isolation_owner_scoped: self.isolation.owner_scoped(),
            shared_resources: self.shared_resources.clone(),
            admin_bypass: self.admin_bypass,
            read_predicate: self.read_predicate,
            client: Mutex::new(client),
        }))
    }

    async fn close(&self) -> DataPlaneResult<()> {
        self.pool.close();
        Ok(())
    }

    /// Raw SQL passthrough for admin-scoped callers (DDL, ALTER, indexes,
    /// aggregations — anything outside safe CRUD). Identity is NOT applied
    /// as an RLS context here because admin operations explicitly bypass
    /// tenant scoping; the caller has already been authorised at the route
    /// layer (`service_role` / `admin` scope).
    async fn apply_migration(
        &self,
        request: MigrationRequest,
        _identity: RequestIdentity,
    ) -> DataPlaneResult<MigrationResult> {
        schema::apply_migration(&self.pool, &self.mount, request).await
    }

    async fn execute_raw(
        &self,
        statement: RawStatement,
        _identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let mut client = self.pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("pool checkout failed: {e}"),
        })?;
        let params: Vec<BoxedParam> = statement.params.iter().map(convert::json_param).collect();
        if statement.expect_rows {
            let rows = client
                .query(
                    statement.statement.as_str(),
                    &convert::as_param_refs(&params),
                )
                .await
                .map_err(|e| convert::backend(&e))?;
            // Use `to_jsonb(row)` would require wrapping; instead serialise
            // each cell into a JSON object keyed by column name.
            let data: Vec<Value> = rows
                .iter()
                .map(|r| {
                    let mut obj = serde_json::Map::new();
                    for (idx, col) in r.columns().iter().enumerate() {
                        let value: Value = r.try_get::<_, Value>(idx).unwrap_or(Value::Null);
                        obj.insert(col.name().to_string(), value);
                    }
                    Value::Object(obj)
                })
                .collect();
            let affected = data.len() as u64;
            // Re-borrow as mutable just to satisfy the type checker — no
            // method-call needed here, but the Object is kept alive.
            let _ = &mut client;
            Ok(DataResult::new(data, affected))
        } else {
            let affected = client
                .execute(
                    statement.statement.as_str(),
                    &convert::as_param_refs(&params),
                )
                .await
                .map_err(|e| convert::backend(&e))?;
            Ok(DataResult::new(vec![], affected))
        }
    }

    /// Engine-agnostic schema introspection (M22). Reads
    /// `information_schema.columns` + `table_constraints`/`key_column_usage`
    /// (PK + FK) + `pg_enum`/`pg_type` (enum values), scoped to the SAME schema
    /// the request path executes in: a `schema_per_tenant` mount introspects
    /// its tenant schema (the one `apply_search_path` pins per transaction);
    /// shared_rls / db_per_tenant introspect `public` (the DSN-default search
    /// path) — so the descriptor never reveals another tenant's tables. The
    /// internal `_baas_migrations` marker table is excluded.
    async fn describe_schema(
        &self,
        identity: RequestIdentity,
    ) -> DataPlaneResult<SchemaDescriptor> {
        self.check_tenant(&identity)?;
        schema::describe_schema(&self.pool, self.search_path_schema.as_deref()).await
    }

    /// Engine-agnostic schema DDL (M22 step 2). The request is lowered to SQL
    /// by the pure [`super::ddl::build_pg_ddl`] builder (identifier-validated,
    /// golden-tested), then executed in ONE transaction — PostgreSQL DDL is
    /// transactional, so a multi-statement op (alter_column_type) is atomic.
    /// Enum types are ensured FIRST in auto-commit (`duplicate_object` =
    /// reuse existing, per contract). Statements are schema-qualified to the
    /// SAME schema `describe_schema` reads (tenant schema for
    /// schema_per_tenant, else `public`), so DDL and introspection can never
    /// disagree about which namespace they touch.
    async fn apply_schema_ddl(
        &self,
        ddl: SchemaDdlRequest,
        identity: RequestIdentity,
    ) -> DataPlaneResult<SchemaDdlResult> {
        self.check_tenant(&identity)?;
        schema::apply_schema_ddl(
            &self.pool,
            self.search_path_schema.as_deref(),
            self.isolation.owner_scoped(),
            ddl,
        )
        .await
    }
}
