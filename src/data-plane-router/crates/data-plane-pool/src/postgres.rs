use crate::ident::quote_ident;
use crate::resolver::MountResolver;
use async_trait::async_trait;
use data_plane_core::{
    validate_default_expr, AggFunc, Aggregate, BatchItemOutcome, BatchItemStatus, BatchSummary,
    CmpOp, ColumnSchema, DataOperation,
    DataOperationKind, DataPlaneError, DataPlaneResult, DataResult, DatabaseMount, DdlColumnDef,
    EngineAdapter, EngineCapabilities, EngineHealth, EnginePool, Filter, ForeignKeyRef, Isolation,
    MigrationRequest, MigrationResult, MigrationStatus, NormalizedType, RawStatement,
    RequestIdentity, ReturningMode, SchemaDdlOp, SchemaDdlRequest, SchemaDdlResult,
    SchemaDdlStatus, SchemaDescriptor, TableSchema, TxBeginRequest, TxHandle,
};
use bytes::BytesMut;
use deadpool_postgres::{
    Config as DeadpoolConfig, ManagerConfig, Object, PoolConfig, RecyclingMethod, Runtime,
};
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio_postgres::types::{to_sql_checked, IsNull, Kind, ToSql, Type};
use tokio_postgres::{GenericClient, NoTls};

type BoxedParam = Box<dyn ToSql + Sync + Send>;

/// The TLS verification posture a mount's DSN opts into.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum TlsMode {
    /// `sslmode=require` — encrypt, do NOT verify the chain (libpq semantics).
    Require,
    /// `sslmode=verify-ca`/`verify-full` — verify the chain against the trust
    /// store (Phase 6). We always also check the hostname (stricter than bare
    /// verify-ca, which is a safe over-enforcement).
    Verify,
}

/// Parse the strictest TLS verification a DSN asks for. Then apply the security
/// posture: under `SECURITY_MODE=max`, a bare `require` is UPGRADED to verify
/// (no more accept-any-cert — closes the MITM hole), unless the operator pins a
/// lower floor. Returns `None` for a non-TLS DSN (the local NoTls parity path).
pub(crate) fn effective_tls_mode(dsn: &str, max_security: bool) -> Option<TlsMode> {
    let asked = if dsn.contains("sslmode=verify-full") || dsn.contains("sslmode=verify-ca") {
        Some(TlsMode::Verify)
    } else if dsn.contains("sslmode=require") {
        Some(TlsMode::Require)
    } else {
        None
    };
    match (asked, max_security) {
        // Max mode: `require` is upgraded to real verification.
        (Some(TlsMode::Require), true) => Some(TlsMode::Verify),
        (other, _) => other,
    }
}

/// Track C / C1: the connection-pooler endpoint to dial, from
/// `DATA_PLANE_POOLER_URL`. `None` (unset/blank) is the default → the direct
/// path, byte-parity. A set value is a full DSN whose host:port is the pooler
/// (e.g. `postgres://…@supavisor:6543/…`); only its host:port is consumed (see
/// [`repoint_dsn_host`]). The env is fixed at process start, so reading it at
/// `open_pool` (per-pool, not per-request) is correct.
pub(crate) fn pooler_url() -> Option<String> {
    match std::env::var("DATA_PLANE_POOLER_URL") {
        Ok(v) if !v.trim().is_empty() => Some(v),
        _ => None,
    }
}

/// Track C / C1: whether client-side prepared-statement/session reuse across
/// pooled checkouts is DISABLED (`DATA_PLANE_STATEMENT_CACHE=off`). Required
/// under a transaction-mode pooler. Default (unset / any non-`off` value, e.g.
/// `on`) → `false`, the direct path with no connection recycle query.
pub(crate) fn statement_cache_off() -> bool {
    std::env::var("DATA_PLANE_STATEMENT_CACHE")
        .map(|v| v.trim().eq_ignore_ascii_case("off"))
        .unwrap_or(false)
}

/// Repoint a URL-form Postgres DSN's host:port to the pooler's, preserving the
/// original DSN's scheme, userinfo (user:password), database path and query
/// (`?sslmode=…&…`). The pooler authenticates the SAME role to the SAME upstream
/// database, so only the transport endpoint changes — the resolved credentials
/// and TLS posture are unchanged.
///
/// Conservative by construction:
/// * Only `postgres://` / `postgresql://` URL-form DSNs are rewritten. A keyword
///   DSN (`host=… port=… user=…`) or any unrecognized shape is returned
///   **unchanged** — never a silent half-rewrite that could point at the wrong
///   target. (The local stack + every gate use the URL form.)
/// * If the pooler URL has no parseable host:port, the original `dsn` is returned
///   unchanged (fail-safe: keep the proven direct target rather than dial a
///   malformed endpoint).
///
/// Pure (no env, no I/O) → unit-tested without a DB.
pub(crate) fn repoint_dsn_host(dsn: &str, pooler_url: &str) -> String {
    let Some(authority) = pooler_authority(pooler_url) else {
        return dsn.to_string();
    };
    // Split the URL-form DSN into scheme://, the authority (userinfo@host:port),
    // and the remainder (/db?query). Only the host:port portion is replaced.
    for scheme in ["postgresql://", "postgres://"] {
        if let Some(rest) = dsn.strip_prefix(scheme) {
            // rest = [userinfo@]host[:port][/db][?query]. The authority ends at
            // the first '/' or '?'; everything from there is the tail.
            let tail_at = rest.find(['/', '?']).unwrap_or(rest.len());
            let (auth, tail) = rest.split_at(tail_at);
            // Preserve userinfo (user:password@) if present; replace only host:port.
            let userinfo = match auth.rfind('@') {
                Some(at) => &auth[..=at], // includes the trailing '@'
                None => "",
            };
            return format!("{scheme}{userinfo}{authority}{tail}");
        }
    }
    // Not a URL-form DSN (keyword form / unknown) → leave it exactly as resolved.
    dsn.to_string()
}

/// Extract `host:port` (the authority) from the pooler URL. Handles the URL form
/// (`postgres://[user:pass@]host:port/db?…`); returns `None` for anything without
/// a parseable host so the caller can fall back to the direct DSN.
fn pooler_authority(pooler_url: &str) -> Option<String> {
    let rest = pooler_url
        .strip_prefix("postgresql://")
        .or_else(|| pooler_url.strip_prefix("postgres://"))?;
    let auth_end = rest.find(['/', '?']).unwrap_or(rest.len());
    let auth = &rest[..auth_end];
    // Drop any userinfo from the pooler URL — only its host:port is used.
    let host_port = match auth.rfind('@') {
        Some(at) => &auth[at + 1..],
        None => auth,
    };
    if host_port.is_empty() {
        return None;
    }
    Some(host_port.to_string())
}

/// Build the rustls connector for the given TLS mode.
///
/// * [`TlsMode::Require`] keeps libpq `require` SEMANTICS: encrypt the channel,
///   do not verify the chain (a Supabase project cert chains to its project CA,
///   not a public root; `require` is what their own connection strings specify).
/// * [`TlsMode::Verify`] (Phase 6) does REAL verification: chain + hostname
///   against the Mozilla webpki roots PLUS an optional custom CA bundle
///   (`ca_file`, from `DATA_PLANE_TLS_CA_FILE`) for private/self-signed CAs.
fn rustls_connector(
    mode: TlsMode,
    ca_file: &str,
) -> DataPlaneResult<tokio_postgres_rustls::MakeRustlsConnect> {
    let provider = rustls::crypto::ring::default_provider();
    let config = match mode {
        TlsMode::Verify => {
            let mut roots = rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            if !ca_file.is_empty() {
                let pem = std::fs::read(ca_file).map_err(|e| DataPlaneError::Backend {
                    message: format!("DATA_PLANE_TLS_CA_FILE read failed: {e}"),
                })?;
                let mut cursor = &pem[..];
                for cert in rustls_pemfile::certs(&mut cursor) {
                    let cert = cert.map_err(|e| DataPlaneError::Backend {
                        message: format!("custom CA parse failed: {e}"),
                    })?;
                    roots.add(cert).map_err(|e| DataPlaneError::Backend {
                        message: format!("custom CA add failed: {e}"),
                    })?;
                }
            }
            rustls::ClientConfig::builder_with_provider(provider.into())
                .with_safe_default_protocol_versions()
                .expect("ring provider supports the default TLS protocol versions")
                .with_root_certificates(roots)
                .with_no_client_auth()
        }
        TlsMode::Require => no_verify_config(provider),
    };
    Ok(tokio_postgres_rustls::MakeRustlsConnect::new(config))
}

/// The accept-any-cert config — encrypt only, no chain verification. ONLY used
/// for `sslmode=require` outside max mode (libpq parity).
fn no_verify_config(provider: rustls::crypto::CryptoProvider) -> rustls::ClientConfig {
    #[derive(Debug)]
    struct NoCertVerification(rustls::crypto::CryptoProvider);
    impl rustls::client::danger::ServerCertVerifier for NoCertVerification {
        fn verify_server_cert(
            &self,
            _end_entity: &rustls::pki_types::CertificateDer<'_>,
            _intermediates: &[rustls::pki_types::CertificateDer<'_>],
            _server_name: &rustls::pki_types::ServerName<'_>,
            _ocsp_response: &[u8],
            _now: rustls::pki_types::UnixTime,
        ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        }
        fn verify_tls12_signature(
            &self,
            message: &[u8],
            cert: &rustls::pki_types::CertificateDer<'_>,
            dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls12_signature(
                message,
                cert,
                dss,
                &self.0.signature_verification_algorithms,
            )
        }
        fn verify_tls13_signature(
            &self,
            message: &[u8],
            cert: &rustls::pki_types::CertificateDer<'_>,
            dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls13_signature(
                message,
                cert,
                dss,
                &self.0.signature_verification_algorithms,
            )
        }
        fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
            self.0.signature_verification_algorithms.supported_schemes()
        }
    }

    rustls::ClientConfig::builder_with_provider(provider.clone().into())
        .with_safe_default_protocol_versions()
        .expect("ring provider supports the default TLS protocol versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertVerification(provider)))
        .with_no_client_auth()
}

/// PostgreSQL engine adapter. Opens long-lived pools keyed by mount instead of
/// constructing a client per request (the legacy `new Client()` hot-path cost).
/// Which PostgreSQL-wire dialect this adapter speaks. CockroachDB serves the
/// pgwire protocol, so it rides this exact adapter (same `tokio-postgres`
/// machinery, SQL builders, RLS GUCs, introspection) parameterized by dialect —
/// the same "one adapter, many engine ids" pattern MariaDB uses for MySQL. The
/// only divergences are the advertised descriptor (CRDB is serializable-only,
/// `stream:false`) and transaction isolation handling (see `begin`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PgDialect {
    Postgres,
    Cockroach,
}

impl PgDialect {
    fn engine_id(self) -> &'static str {
        match self {
            PgDialect::Postgres => "postgresql",
            PgDialect::Cockroach => "cockroachdb",
        }
    }

    fn capabilities(self) -> EngineCapabilities {
        match self {
            PgDialect::Postgres => EngineCapabilities::postgresql(),
            PgDialect::Cockroach => EngineCapabilities::cockroachdb(),
        }
    }
}

pub struct PostgresEngineAdapter {
    resolver: Arc<dyn MountResolver>,
    dialect: PgDialect,
}

impl PostgresEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver, dialect: PgDialect::Postgres }
    }

    /// Build the adapter for a specific pgwire dialect (e.g. CockroachDB). The
    /// registry routes a mount to this adapter by matching `engine()`, so a
    /// `cockroachdb` mount lands on a Cockroach-dialect instance.
    #[must_use]
    pub fn with_dialect(resolver: Arc<dyn MountResolver>, dialect: PgDialect) -> Self {
        Self { resolver, dialect }
    }
}

#[async_trait]
impl EngineAdapter for PostgresEngineAdapter {
    fn engine(&self) -> &str {
        self.dialect.engine_id()
    }

    fn capabilities(&self) -> EngineCapabilities {
        self.dialect.capabilities()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;

        // Track C / C1: when a connection pooler is wired (`DATA_PLANE_POOLER_URL`
        // set), dial the pooler endpoint instead of the resolved DSN's direct
        // host:port — keeping the resolved DSN's database/user/password/sslmode
        // (the pooler authenticates the same role to the same upstream DB). UNSET
        // (the default) → `dsn` is returned UNCHANGED, so the connection target is
        // byte-identical to the pre-C1 direct path. Isolation is unaffected: the
        // RLS GUCs + owner_id predicate are re-stamped per request INSIDE each
        // request's transaction (`apply_rls_context`), so a transaction-mode
        // pooler that hands a different backend to the next request never leaks
        // tenant state — the SAME invariant that lets shared_rls pools serve many
        // tenants. See scripts/scale/POOLER.md.
        let dsn = match pooler_url() {
            Some(pooler) => repoint_dsn_host(&dsn, &pooler),
            None => dsn,
        };

        // Phase 6: the effective TLS posture. `require` keeps libpq parity
        // (encrypt, don't verify); `verify-*` (or `require` under
        // SECURITY_MODE=max) verifies the chain + hostname. None → NoTls (local).
        let max_security = std::env::var("SECURITY_MODE")
            .map(|v| v.eq_ignore_ascii_case("max"))
            .unwrap_or(false);
        let tls_mode = effective_tls_mode(&dsn, max_security);
        let mut cfg = DeadpoolConfig::new();
        cfg.url = Some(dsn);
        cfg.pool = Some(PoolConfig::new(mount.pool_policy.max.max(1) as usize));
        // Track C / C1: under a transaction-mode pooler, client-side
        // prepared-statement/session reuse across pooled checkouts is unsafe (a
        // checkout can land on a different upstream backend), so
        // `DATA_PLANE_STATEMENT_CACHE=off` recycles each connection with
        // `RecyclingMethod::Clean` — `DISCARD TEMP/SEQUENCES/…` (deliberately NOT
        // `DEALLOCATE ALL`/`DISCARD PLAN`, which a txn-mode pooler rejects), wiping
        // any session state on return to the pool. UNSET/`on` (the default) keeps
        // `RecyclingMethod::Fast` — no recycle query — so the direct path is
        // byte-identical. (The CRUD path already binds via tokio-postgres' UNNAMED
        // prepared statement, never persisted across checkouts, so this is a
        // forward-safety guard, not a correctness fix for today's queries.)
        if statement_cache_off() {
            cfg.manager = Some(ManagerConfig {
                recycling_method: RecyclingMethod::Clean,
            });
        }

        // External mounts (a client's Supabase project) REQUIRE TLS; the DSN
        // opts in via sslmode=require/verify-*. Everything else keeps the
        // NoTls path byte-identical (the local stack's postgres).
        let pool = match tls_mode {
            Some(mode) => {
                let ca_file = std::env::var("DATA_PLANE_TLS_CA_FILE").unwrap_or_default();
                let connector = rustls_connector(mode, &ca_file)?;
                cfg.create_pool(Some(Runtime::Tokio1), connector)
            }
            None => cfg.create_pool(Some(Runtime::Tokio1), NoTls),
        }
        .map_err(|e| DataPlaneError::Backend {
            message: format!("pool create failed: {e}"),
        })?;

        // Resolve the isolation strategy ONCE here (parse-once contract). For a
        // `schema_per_tenant` mount we also derive the `search_path` schema once
        // now (identity-independent: the schema is per-mount, keyed on the
        // mount's tenant_id) and cache it — mirroring mysql/mongo/redis, which
        // resolve their namespace at open_pool. For shared_rls / db_per_tenant
        // (the default and hot path) this is `None`: the per-request path stays
        // allocation-free and byte-identical to before G5.
        let isolation = mount.isolation();
        let search_path_schema = mount.tenant_schema();
        // B4-pools: a shared_rls pool under DATA_PLANE_SHARE_POOLS serves EVERY
        // tenant on this physical DB from one connection set, so it must NOT
        // assert a single owner tenant — isolation is re-applied per request
        // (`app.current_tenant_id` GUC + the owner_id predicate, both from the
        // request identity). `crate::pools_shared` is the one place the env +
        // isolation predicate live, shared with every other engine adapter.
        let shared_pool = crate::pools_shared(&mount);
        Ok(Box::new(PostgresPool {
            mount_id: mount.id.clone(),
            tenant_id: mount.tenant_id.clone(),
            shared_pool,
            pool,
            isolation,
            search_path_schema,
            dialect: self.dialect,
            mount,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth {
            engine: self.dialect.engine_id().to_string(),
            mount_id: pool.mount_id().to_string(),
            status: "unknown".to_string(),
        })
    }
}

/// A pooled PostgreSQL connection set bound to a single mount.
pub struct PostgresPool {
    mount_id: String,
    /// The mount's tenant, captured at `open_pool`, for the defense-in-depth
    /// cross-check on every `execute`/`begin` (matching mysql/mongo/redis/http).
    tenant_id: String,
    /// True when this is a SHARE_POOLS shared_rls pool serving many tenants:
    /// the single-tenant `check_tenant` assertion is then bypassed (per-request
    /// RLS + owner_id predicate carry isolation). See `open_pool`.
    shared_pool: bool,
    pool: deadpool_postgres::Pool,
    /// The resolved isolation strategy for this mount, parsed once at
    /// `open_pool`. `SharedRls` (the default) means every request runs exactly
    /// as it did before G5. Retained for diagnostics / future strategy gates.
    #[allow(dead_code)]
    isolation: Isolation,
    /// The `search_path` schema to pin for this mount, resolved ONCE at
    /// `open_pool` (the schema is per-mount, not per-request). `Some` only for
    /// `schema_per_tenant`; `None` (shared_rls / db_per_tenant) is the parity
    /// path — no `SET LOCAL search_path`, byte-identical to before G5.
    search_path_schema: Option<String>,
    /// The pgwire dialect this pool speaks. `Postgres` is the parity path;
    /// `Cockroach` only changes transaction-isolation lowering in `begin`
    /// (CRDB is serializable-only). Captured once at `open_pool`.
    dialect: PgDialect,
    /// Retained mount for migration-time schema derivation
    /// ([`DatabaseMount::tenant_schema`] in `apply_migration`). Cheap: opened
    /// once per pool, not per request.
    mount: DatabaseMount,
}

impl PostgresPool {
    /// The RLS principal applied via `app.current_user_id`.
    fn principal(identity: &RequestIdentity) -> &str {
        identity.owner_principal()
    }

    /// Defense-in-depth tenant cross-check: the dispatcher (`routes::
    /// validate_identity_mount`) should already have rejected a tenant/mount
    /// mismatch, but the pool re-asserts it so a mis-keyed pool can never serve
    /// a request for the wrong tenant. Matches mysql/mongo/redis/http.
    fn check_tenant(&self, identity: &RequestIdentity) -> DataPlaneResult<()> {
        // A SHARE_POOLS shared_rls pool is multi-tenant BY DESIGN — it has no
        // single owner to assert. Isolation is still enforced per request, by
        // `apply_rls_context` (`app.current_tenant_id`/`current_user_id` GUCs)
        // and the owner_id predicate, both derived from THIS request's identity.
        // The single-tenant assertion below is the correct guard only for a
        // per-tenant pool; here it would reject every tenant but the one that
        // happened to open the pool. (Verified: cross-tenant read isolation
        // holds with SHARE_POOLS=1 — m39 isolation probe.)
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

        let tx = client.transaction().await.map_err(|e| backend(&e))?;
        // deadpool wraps tokio_postgres::Transaction in a newtype that does
        // not implement GenericClient, so one explicit deref gets us back
        // to the underlying tokio_postgres::Transaction.
        apply_rls_context(&*tx, &identity).await?;
        apply_search_path(&*tx, self.search_path_schema.as_deref()).await?;

        let result = dispatch_op(&*tx, &operation, &identity, self.isolation.owner_scoped()).await?;

        tx.commit().await.map_err(|e| backend(&e))?;
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
            .map_err(|e| backend(&e))?;
        // deadpool::Object derefs to ClientWrapper which derefs to
        // tokio_postgres::Client (the GenericClient impl). Two derefs gets
        // us to &Client.
        apply_rls_context(&**client, &request.identity).await?;
        apply_search_path(&**client, self.search_path_schema.as_deref()).await?;
        // (the two-star form lands on the type GenericClient is implemented
        // for; one-star would still be ClientWrapper.)

        let tx_id = uuid::Uuid::now_v7().to_string();
        Ok(Box::new(PgTxHandle {
            tx_id,
            mount_id: self.mount_id.clone(),
            owner_scoped: self.isolation.owner_scoped(),
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
        let mut client = self.pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("pool checkout failed: {e}"),
        })?;
        let tx = client.transaction().await.map_err(|e| backend(&e))?;

        // For schema_per_tenant, the migration (marker table + every DDL/DML
        // statement) targets the tenant schema: create it if absent and pin the
        // transaction's `search_path` so unqualified table names in the
        // migration body land there. For shared / db-per-tenant the schema is
        // `None` → behaviour is BYTE-IDENTICAL to before G5 (`public`).
        let schema = self.mount.tenant_schema();
        if let Some(schema) = schema.as_deref() {
            // `schema` is pre-sanitized to `[a-z0-9_]` by `safe_schema`, so
            // interpolating it (DDL/SET cannot bind parameters) is injection-safe.
            tx.batch_execute(&format!("CREATE SCHEMA IF NOT EXISTS {schema}"))
                .await
                .map_err(|e| backend(&e))?;
            tx.batch_execute(&format!("SET LOCAL search_path TO {schema}, public"))
                .await
                .map_err(|e| backend(&e))?;
        }
        // Marker table lives in the tenant schema for schema_per_tenant (so each
        // tenant tracks its own applied set), else in `public` as before.
        let marker = match schema.as_deref() {
            Some(schema) => format!("{schema}._baas_migrations"),
            None => "public._baas_migrations".to_string(),
        };
        // Ensure the marker table exists on the tenant DB. Name chosen to be
        // unlikely to collide with user tables.
        tx.batch_execute(&format!(
            "CREATE TABLE IF NOT EXISTS {marker} (
                name TEXT PRIMARY KEY,
                applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )"
        ))
        .await
        .map_err(|e| backend(&e))?;
        let already: Option<tokio_postgres::Row> = tx
            .query_opt(
                &format!("SELECT 1 FROM {marker} WHERE name = $1"),
                &[&request.name],
            )
            .await
            .map_err(|e| backend(&e))?;
        if already.is_some() {
            // No COMMIT needed (no mutating statements ran); ROLLBACK is fine.
            let _ = tx.rollback().await;
            return Ok(MigrationResult {
                name: request.name,
                status: MigrationStatus::Skipped,
                statements_run: 0,
            });
        }
        let mut run = 0u32;
        for stmt in &request.statements {
            tx.batch_execute(stmt).await.map_err(|e| backend(&e))?;
            run += 1;
        }
        tx.execute(
            &format!("INSERT INTO {marker} (name) VALUES ($1)"),
            &[&request.name],
        )
        .await
        .map_err(|e| backend(&e))?;
        tx.commit().await.map_err(|e| backend(&e))?;
        Ok(MigrationResult {
            name: request.name,
            status: MigrationStatus::Applied,
            statements_run: run,
        })
    }

    async fn execute_raw(
        &self,
        statement: RawStatement,
        _identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let mut client = self.pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("pool checkout failed: {e}"),
        })?;
        let params: Vec<BoxedParam> = statement.params.iter().map(json_param).collect();
        if statement.expect_rows {
            let rows = client
                .query(statement.statement.as_str(), &as_param_refs(&params))
                .await
                .map_err(|e| backend(&e))?;
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
                .execute(statement.statement.as_str(), &as_param_refs(&params))
                .await
                .map_err(|e| backend(&e))?;
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
        let client = self.pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("pool checkout failed: {e}"),
        })?;
        // Same scoping rule as the per-request `apply_search_path`: the tenant
        // schema when isolation is schema_per_tenant, else `public`.
        let schema = self
            .search_path_schema
            .clone()
            .unwrap_or_else(|| "public".to_string());

        // Enum types and their labels (sorted by declared order). Keyed by
        // udt_name so a USER-DEFINED column can be resolved to its values.
        let mut enums: std::collections::BTreeMap<String, Vec<String>> = Default::default();
        let enum_rows = client
            .query(
                "SELECT t.typname, e.enumlabel
                 FROM pg_type t
                 JOIN pg_enum e ON e.enumtypid = t.oid
                 ORDER BY t.typname, e.enumsortorder",
                &[],
            )
            .await
            .map_err(|e| backend(&e))?;
        for row in &enum_rows {
            enums
                .entry(row.get::<_, String>(0))
                .or_default()
                .push(row.get::<_, String>(1));
        }

        // Primary keys, per table, in key ordinal order.
        let mut pks: std::collections::BTreeMap<String, Vec<String>> = Default::default();
        let pk_rows = client
            .query(
                "SELECT tc.table_name, kcu.column_name
                 FROM information_schema.table_constraints tc
                 JOIN information_schema.key_column_usage kcu
                   ON kcu.constraint_name = tc.constraint_name
                  AND kcu.table_schema = tc.table_schema
                 WHERE tc.table_schema = $1 AND tc.constraint_type = 'PRIMARY KEY'
                 ORDER BY tc.table_name, kcu.ordinal_position",
                &[&schema],
            )
            .await
            .map_err(|e| backend(&e))?;
        for row in &pk_rows {
            pks.entry(row.get::<_, String>(0))
                .or_default()
                .push(row.get::<_, String>(1));
        }

        // Foreign keys: (table, column) → referenced (table, column).
        let mut fks: std::collections::BTreeMap<(String, String), ForeignKeyRef> =
            Default::default();
        let fk_rows = client
            .query(
                "SELECT tc.table_name, kcu.column_name, ccu.table_name, ccu.column_name
                 FROM information_schema.table_constraints tc
                 JOIN information_schema.key_column_usage kcu
                   ON kcu.constraint_name = tc.constraint_name
                  AND kcu.table_schema = tc.table_schema
                 JOIN information_schema.constraint_column_usage ccu
                   ON ccu.constraint_name = tc.constraint_name
                  AND ccu.table_schema = tc.table_schema
                 WHERE tc.table_schema = $1 AND tc.constraint_type = 'FOREIGN KEY'",
                &[&schema],
            )
            .await
            .map_err(|e| backend(&e))?;
        for row in &fk_rows {
            fks.insert(
                (row.get::<_, String>(0), row.get::<_, String>(1)),
                ForeignKeyRef { table: row.get::<_, String>(2), column: row.get::<_, String>(3) },
            );
        }

        // Columns of every BASE TABLE in the scoped schema, in ordinal order.
        let mut tables: std::collections::BTreeMap<String, Vec<ColumnSchema>> = Default::default();
        let col_rows = client
            .query(
                "SELECT c.table_name, c.column_name, c.udt_name, c.data_type,
                        c.is_nullable, c.column_default
                 FROM information_schema.columns c
                 JOIN information_schema.tables t
                   ON t.table_schema = c.table_schema AND t.table_name = c.table_name
                 WHERE c.table_schema = $1
                   AND t.table_type = 'BASE TABLE'
                   AND c.table_name <> '_baas_migrations'
                 ORDER BY c.table_name, c.ordinal_position",
                &[&schema],
            )
            .await
            .map_err(|e| backend(&e))?;
        for row in &col_rows {
            let table: String = row.get(0);
            let name: String = row.get(1);
            let udt: String = row.get(2);
            let data_type: String = row.get(3);
            let is_nullable: String = row.get(4);
            let default: Option<String> = row.get(5);

            let (normalized_type, enum_values) = match enums.get(&udt) {
                // USER-DEFINED type with pg_enum rows → enum + its labels.
                Some(values) if data_type == "USER-DEFINED" => {
                    (NormalizedType::Enum, Some(values.clone()))
                }
                _ => (normalize_pg_type(&udt), None),
            };
            let references = fks.get(&(table.clone(), name.clone())).cloned();
            tables.entry(table).or_default().push(ColumnSchema {
                name,
                native_type: udt,
                normalized_type,
                nullable: is_nullable.eq_ignore_ascii_case("yes"),
                default,
                enum_values,
                references,
                inferred: false,
            });
        }

        Ok(SchemaDescriptor {
            engine: "postgresql".to_string(),
            tables: tables
                .into_iter()
                .map(|(name, columns)| TableSchema {
                    primary_key: pks.remove(&name).unwrap_or_default(),
                    name,
                    columns,
                })
                .collect(),
        })
    }

    /// Engine-agnostic schema DDL (M22 step 2). The request is lowered to SQL
    /// by the pure [`build_pg_ddl`] builder (identifier-validated, golden-
    /// tested), then executed in ONE transaction — PostgreSQL DDL is
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
        let schema = self
            .search_path_schema
            .clone()
            .unwrap_or_else(|| "public".to_string());
        let plan = build_pg_ddl(&schema, &ddl, self.isolation.owner_scoped())?;

        let mut client = self.pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("pool checkout failed: {e}"),
        })?;
        // schema_per_tenant: the tenant schema may not exist yet (first DDL on
        // a fresh tenant). `schema` is pre-sanitized by `safe_schema`, so
        // interpolating it (DDL cannot bind parameters) is injection-safe.
        if self.search_path_schema.is_some() {
            client
                .batch_execute(&format!("CREATE SCHEMA IF NOT EXISTS {schema}"))
                .await
                .map_err(|e| backend(&e))?;
        }
        // Enum types auto-commit BEFORE the transactional DDL: an aborted
        // CREATE TYPE inside the tx would poison it, and `duplicate_object`
        // here means the named type already exists — reuse it.
        for stmt in &plan.ensure_enum_types {
            if let Err(e) = client.execute(stmt.as_str(), &[]).await {
                if !is_duplicate_object(&e) {
                    return Err(ddl_backend(&e));
                }
            }
        }

        let tx = client.transaction().await.map_err(|e| backend(&e))?;
        for stmt in &plan.statements {
            tx.execute(stmt.as_str(), &[]).await.map_err(|e| ddl_backend(&e))?;
        }
        tx.commit().await.map_err(|e| backend(&e))?;
        Ok(SchemaDdlResult {
            op: ddl.op,
            table: ddl.table,
            status: SchemaDdlStatus::Applied,
        })
    }
}

/// Maps a Postgres `udt_name` to the engine-neutral [`NormalizedType`]. Pure
/// (testable without a DB); enum resolution happens at the call site, which
/// holds the `pg_enum` rows. Array types surface as `_<element>` udt names (or
/// the literal `ARRAY` data_type, which callers pass through here unchanged).
pub(crate) fn normalize_pg_type(native: &str) -> NormalizedType {
    match native {
        "int2" | "int4" | "int8" => NormalizedType::Integer,
        "float4" | "float8" => NormalizedType::Float,
        "numeric" => NormalizedType::Decimal,
        "bool" => NormalizedType::Boolean,
        "date" => NormalizedType::Date,
        "json" | "jsonb" => NormalizedType::Json,
        "uuid" => NormalizedType::Uuid,
        "text" | "varchar" | "char" | "bpchar" => NormalizedType::Text,
        "ARRAY" => NormalizedType::Array,
        n if n.starts_with("timestamp") => NormalizedType::Datetime,
        n if n.starts_with('_') => NormalizedType::Array,
        _ => NormalizedType::Unknown,
    }
}

// ── M22 step 2: engine-agnostic schema DDL (pure SQL builders) ───────────────
//
// Everything below is pure (testable without a DB). Identifiers go through
// `quote_ident` (allowlist + quoting); enum VALUES are SQL string literals
// escaped by `pg_literal`; caller-supplied DEFAULT expressions pass the shared
// `validate_default_expr` guard (no `;`, comments, or control chars — defense
// in depth on top of the driver's single-statement extended protocol).

/// The statement plan for one schema-DDL operation.
#[derive(Debug)]
pub(crate) struct PgDdlPlan {
    /// `CREATE TYPE … AS ENUM (…)` statements run BEFORE the transactional
    /// DDL, auto-commit; a `duplicate_object` (42710) error means "reuse the
    /// existing type" (per contract).
    pub(crate) ensure_enum_types: Vec<String>,
    /// The DDL statements, executed in order inside ONE transaction.
    pub(crate) statements: Vec<String>,
}

/// `'…'`-quoted SQL string literal: single quotes double. Backslash is
/// literal under `standard_conforming_strings` (the PG default since 9.1).
fn pg_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

/// The schema-qualified, quoted name of the per-column enum type:
/// `"schema"."{table}_{column}_enum"`. Both parts go through `quote_ident`,
/// so an over-long or invalid combination fails closed (InvalidIdentifier)
/// instead of being silently truncated by the server.
fn pg_enum_type_name(schema: &str, table: &str, column: &str) -> DataPlaneResult<String> {
    quote_ident(&format!("{schema}.{table}_{column}_enum"))
}

/// Reverse type mapping (the inverse of [`normalize_pg_type`]): lowers a
/// [`DdlColumnDef`] to the PostgreSQL column type SQL. Enum columns map to a
/// named type `"{table}_{column}_enum"` (created/reused via the plan's
/// `ensure_enum_types`). `objectid`/`unknown` are describe-only and rejected.
pub(crate) fn pg_sql_type(
    schema: &str,
    table: &str,
    def: &DdlColumnDef,
) -> DataPlaneResult<String> {
    Ok(match def.normalized_type {
        NormalizedType::Text => "text".to_string(),
        NormalizedType::Integer => "bigint".to_string(),
        NormalizedType::Float => "double precision".to_string(),
        NormalizedType::Decimal => "numeric".to_string(),
        NormalizedType::Boolean => "boolean".to_string(),
        NormalizedType::Date => "date".to_string(),
        NormalizedType::Datetime => "timestamptz".to_string(),
        NormalizedType::Json => "jsonb".to_string(),
        NormalizedType::Uuid => "uuid".to_string(),
        // v1: arrays are text[] — element typing is a follow-up.
        NormalizedType::Array => "text[]".to_string(),
        NormalizedType::Enum => pg_enum_type_name(schema, table, &def.name)?,
        NormalizedType::Objectid | NormalizedType::Unknown => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!(
                    "column '{}': normalized_type '{:?}' cannot be created on postgresql",
                    def.name, def.normalized_type
                ),
            })
        }
    })
}

/// The `CREATE TYPE … AS ENUM (…)` statement for an enum column, or `None`
/// for any other type. Values are escaped literals; an enum without values
/// is a client error.
fn pg_create_enum_stmt(
    schema: &str,
    table: &str,
    def: &DdlColumnDef,
) -> DataPlaneResult<Option<String>> {
    if def.normalized_type != NormalizedType::Enum {
        return Ok(None);
    }
    let values = def
        .enum_values
        .as_deref()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| DataPlaneError::InvalidRequest {
            message: format!("enum column '{}' requires non-empty enum_values", def.name),
        })?;
    let name = pg_enum_type_name(schema, table, &def.name)?;
    let literals: Vec<String> = values.iter().map(|v| pg_literal(v)).collect();
    Ok(Some(format!(
        "CREATE TYPE {name} AS ENUM ({})",
        literals.join(", ")
    )))
}

/// One column clause (`"name" type [NOT NULL] [DEFAULT expr]`), collecting
/// any enum-type prerequisite into the plan.
fn pg_column_clause(
    schema: &str,
    table: &str,
    def: &DdlColumnDef,
    plan: &mut PgDdlPlan,
) -> DataPlaneResult<String> {
    let col = quote_ident(&def.name)?;
    let ty = pg_sql_type(schema, table, def)?;
    if let Some(stmt) = pg_create_enum_stmt(schema, table, def)? {
        plan.ensure_enum_types.push(stmt);
    }
    let mut clause = format!("{col} {ty}");
    if !def.nullable {
        clause.push_str(" NOT NULL");
    }
    if let Some(default) = def.default.as_deref() {
        validate_default_expr(default)?;
        clause.push_str(&format!(" DEFAULT {default}"));
    }
    Ok(clause)
}

/// Lowers a [`SchemaDdlRequest`] to its PostgreSQL statement plan, targeting
/// `schema` explicitly (`"schema"."table"` on every statement).
pub(crate) fn build_pg_ddl(
    schema: &str,
    ddl: &SchemaDdlRequest,
    owner_scoped: bool,
) -> DataPlaneResult<PgDdlPlan> {
    let table = quote_ident(&format!("{schema}.{}", ddl.table))?;
    let mut plan = PgDdlPlan {
        ensure_enum_types: Vec::new(),
        statements: Vec::new(),
    };
    match ddl.op {
        SchemaDdlOp::AddColumn => {
            let def = ddl.require_column()?;
            let clause = pg_column_clause(schema, &ddl.table, def, &mut plan)?;
            plan.statements
                .push(format!("ALTER TABLE {table} ADD COLUMN {clause}"));
        }
        SchemaDdlOp::DropColumn => {
            let col = quote_ident(ddl.require_column_name()?)?;
            plan.statements
                .push(format!("ALTER TABLE {table} DROP COLUMN {col}"));
        }
        SchemaDdlOp::AlterColumnType => {
            // The caller composed the FULL target definition; lower it as a
            // 4-step sequence (one tx → atomic):
            //   1. DROP DEFAULT — the old default may not be castable to the
            //      new type (PG would refuse the TYPE change otherwise);
            //   2. TYPE … USING — enums cast via ::text (every type reaches
            //      text; text reaches any enum);
            //   3. SET/DROP NOT NULL per the target def;
            //   4. SET DEFAULT per the target def (when one is declared).
            let def = ddl.require_column()?;
            let col = quote_ident(&def.name)?;
            let ty = pg_sql_type(schema, &ddl.table, def)?;
            if let Some(stmt) = pg_create_enum_stmt(schema, &ddl.table, def)? {
                plan.ensure_enum_types.push(stmt);
            }
            plan.statements
                .push(format!("ALTER TABLE {table} ALTER COLUMN {col} DROP DEFAULT"));
            let using = if def.normalized_type == NormalizedType::Enum {
                format!("{col}::text::{ty}")
            } else {
                format!("{col}::{ty}")
            };
            plan.statements.push(format!(
                "ALTER TABLE {table} ALTER COLUMN {col} TYPE {ty} USING {using}"
            ));
            plan.statements.push(format!(
                "ALTER TABLE {table} ALTER COLUMN {col} {} NOT NULL",
                if def.nullable { "DROP" } else { "SET" }
            ));
            if let Some(default) = def.default.as_deref() {
                validate_default_expr(default)?;
                plan.statements.push(format!(
                    "ALTER TABLE {table} ALTER COLUMN {col} SET DEFAULT {default}"
                ));
            }
        }
        SchemaDdlOp::CreateTable => {
            let (columns, primary_key) = ddl.require_create_spec()?;
            let mut clauses = Vec::with_capacity(columns.len() + 2);
            let mut has_owner = false;
            for def in columns {
                if def.name == "owner_id" {
                    has_owner = true;
                }
                clauses.push(pg_column_clause(schema, &ddl.table, def, &mut plan)?);
            }
            if owner_scoped && !has_owner {
                // The platform's write path owner-scopes every row (insert
                // injects owner_id; update/delete filter on it) — a table
                // without the column would 500 on its first write. The
                // principal is NOT always a uuid: API-key callers get the
                // synthetic `api-key:<uuid>` string and the insert path binds
                // it as text, so the column must be text. `tenant_owned`
                // mounts skip this: the schema is the tenant's own.
                clauses.push(format!("{} text", quote_ident("owner_id")?));
            }
            let pk: Vec<String> = primary_key
                .iter()
                .map(|c| quote_ident(c))
                .collect::<DataPlaneResult<_>>()?;
            clauses.push(format!("PRIMARY KEY ({})", pk.join(", ")));
            plan.statements
                .push(format!("CREATE TABLE {table} ({})", clauses.join(", ")));
        }
        SchemaDdlOp::DropTable => {
            plan.statements.push(format!("DROP TABLE {table}"));
        }
    }
    Ok(plan)
}

/// DDL-path error classifier. Class 22 data exceptions (invalid text
/// representation, numeric out of range, …) and 42804 datatype_mismatch
/// during `ALTER … USING` mean the EXISTING DATA is incompatible with the
/// requested type — the caller's conflict (409), not an engine failure (502).
/// Schema-shape mistakes are deterministic client errors too: a 5xx here
/// makes outbox-style clients retry a request that can never succeed —
/// 42701/42P07 (already exists) → 409, 42703/42P01 (no such column/table) →
/// 400. Scoped to the DDL path only (additive): `/v1/query` keeps the
/// existing [`backend`] mapping, which this falls back to (23xxx →
/// Conflict, rest → Backend).
fn ddl_backend(e: &tokio_postgres::Error) -> DataPlaneError {
    if let Some(db) = e.as_db_error() {
        let code = db.code().code();
        if code.starts_with("22") || code == "42804" || code == "42701" || code == "42P07" {
            return DataPlaneError::Conflict {
                message: db.message().to_string(),
            };
        }
        if code == "42703" || code == "42P01" {
            return DataPlaneError::InvalidRequest {
                message: db.message().to_string(),
            };
        }
    }
    backend(e)
}

/// SQLSTATE 42710 duplicate_object — the enum type already exists.
fn is_duplicate_object(e: &tokio_postgres::Error) -> bool {
    e.as_db_error().is_some_and(|db| db.code().code() == "42710")
}

/// Pinned PostgreSQL transaction. Owns the checked-out connection for the
/// full life of the tx; releases it to the pool when dropped.
///
/// Concurrency: `tokio::sync::Mutex` serializes the calls so that two
/// concurrent `execute()` / `commit()` requests against the same `tx_id`
/// don't interleave on the wire (which would be a SQL-level corruption).
pub struct PgTxHandle {
    tx_id: String,
    mount_id: String,
    /// Snapshot of the mount's `Isolation::owner_scoped()` at begin time —
    /// txn writes must scope exactly like single-op writes on this mount.
    owner_scoped: bool,
    client: Mutex<Object>,
}

#[async_trait]
impl TxHandle for PgTxHandle {
    fn tx_id(&self) -> &str {
        &self.tx_id
    }

    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let client = self.client.lock().await;
        // MutexGuard → Object → ClientWrapper → Client. Three derefs.
        dispatch_op(&***client, &operation, &identity, self.owner_scoped).await
    }

    async fn commit(&self) -> DataPlaneResult<()> {
        let client = self.client.lock().await;
        client
            .execute("COMMIT", &[])
            .await
            .map_err(|e| backend(&e))?;
        Ok(())
    }

    async fn rollback(&self) -> DataPlaneResult<()> {
        let client = self.client.lock().await;
        // Best-effort: if the tx is already aborted, ROLLBACK is a no-op.
        let _ = client.execute("ROLLBACK", &[]).await;
        Ok(())
    }

    async fn prepare(&self) -> DataPlaneResult<()> {
        // 2PC (`PREPARE TRANSACTION`) is intentionally not exposed; the
        // capability descriptor declares `two_phase_commit: false`.
        Err(DataPlaneError::NotImplemented {
            feature: "postgres PREPARE TRANSACTION (2PC)".to_string(),
        })
    }
}

/// Set the RLS GUCs that the tenant identity needs. Used by both auto-commit
/// and multi-statement paths. `set_config(..., true)` scopes them to the
/// current transaction, which is exactly what we want.
async fn apply_rls_context<C: GenericClient + Sync>(
    client: &C,
    identity: &RequestIdentity,
) -> DataPlaneResult<()> {
    let principal = PostgresPool::principal(identity).to_string();
    let tenant = identity.tenant_id.clone();
    // Build the claims object with serde_json so a `"` or `}` in the identity
    // cannot inject a chosen `sub` — which is the RLS principal that
    // `auth.current_user_id()` reads first. Never hand-format the security
    // principal. (Defense in depth; identity should also be validated upstream.)
    let claims = serde_json::json!({ "sub": &principal, "tenant_id": &tenant }).to_string();
    client
        .execute(
            "SELECT set_config('app.current_user_id', $1, true), \
                    set_config('app.current_tenant_id', $2, true), \
                    set_config('request.jwt.claims', $3, true)",
            &[&principal, &tenant, &claims],
        )
        .await
        .map_err(|e| backend(&e))?;
    Ok(())
}

/// For `schema_per_tenant` mounts, pin the connection's `search_path` to the
/// tenant schema for the current transaction (`SET LOCAL`). No-op for shared /
/// db-per-tenant mounts. `public` is kept on the path so shared extensions and
/// types still resolve. The schema name is pre-sanitized to `[a-z0-9_]` by
/// [`DatabaseMount::tenant_schema`], so interpolating it here (SET cannot bind
/// parameters) carries no injection risk.
async fn apply_search_path<C: GenericClient + Sync>(
    client: &C,
    schema: Option<&str>,
) -> DataPlaneResult<()> {
    let Some(schema) = schema else {
        return Ok(());
    };
    let sql = format!("SET LOCAL search_path TO {schema}, public");
    client
        .execute(sql.as_str(), &[])
        .await
        .map_err(|e| backend(&e))?;
    Ok(())
}

/// Operation dispatch shared by auto-commit and tx paths.
/// The operation kinds the Postgres adapter dispatches. `dispatch_op` rejects
/// anything else; the capability descriptor (`EngineCapabilities::postgresql`)
/// and the honesty test both derive from this — the single source of truth.
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

async fn dispatch_op<C: GenericClient + Sync>(
    client: &C,
    operation: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    if !SUPPORTED_OPS.contains(&operation.op) {
        return Err(DataPlaneError::NotImplemented {
            feature: format!("postgres operation {:?}", operation.op),
        });
    }
    match &operation.op {
        DataOperationKind::Batch => run_batch(client, operation, identity, owner_scoped).await,
        _ => dispatch_single(client, operation, identity, owner_scoped).await,
    }
}

/// Single (non-batch) operation dispatch — the arms `run_batch` loops over.
/// Exhaustive by enumeration (no wildcard): deleting a CRUD arm is a compile
/// error, so the match can't silently drift from SUPPORTED_OPS.
async fn dispatch_single<C: GenericClient + Sync>(
    client: &C,
    operation: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    match &operation.op {
        DataOperationKind::List => run_list(client, operation).await,
        DataOperationKind::Get => run_get(client, operation).await,
        DataOperationKind::Insert => run_insert(client, operation, identity, owner_scoped).await,
        DataOperationKind::Update => run_update(client, operation, identity, owner_scoped).await,
        DataOperationKind::Delete => run_delete(client, operation, identity, owner_scoped).await,
        DataOperationKind::Upsert => run_upsert(client, operation, identity, owner_scoped).await,
        DataOperationKind::Aggregate => run_aggregate(client, operation).await,
        DataOperationKind::Batch => Err(DataPlaneError::InvalidRequest {
            message: "nested batches are not allowed".to_string(),
        }),
    }
}

/// Atomic batch: the caller already wraps every `execute()` in a transaction
/// (and the tx path runs inside the caller's interactive transaction), so a
/// failed item simply propagates its error — the surrounding transaction is
/// never committed and nothing persists. Item errors carry the item index so
/// the 4xx envelope tells the caller exactly which sub-operation failed.
async fn run_batch<C: GenericClient + Sync>(
    client: &C,
    operation: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    let items = operation
        .batch_items()
        .map_err(|message| DataPlaneError::InvalidRequest { message })?;
    let mut outcomes = Vec::with_capacity(items.len());
    let mut total: u64 = 0;
    for (idx, item) in items.iter().enumerate() {
        let result = dispatch_single(client, item, identity, owner_scoped)
            .await
            .map_err(|e| DataPlaneError::prefix_message(&format!("batch item {idx}: "), e))?;
        total += result.affected_rows;
        outcomes.push(BatchItemOutcome {
            index: idx as u32,
            status: BatchItemStatus::Ok,
            affected_rows: result.affected_rows,
            error: None,
        });
    }
    Ok(DataResult {
        rows: vec![],
        affected_rows: total,
        next_cursor: None,
        batch: Some(BatchSummary { atomic: true, items: outcomes }),
    })
}


/// Grouped aggregation:
/// `SELECT to_jsonb(g) FROM (SELECT <group cols>, <agg exprs> FROM t WHERE <filter>
/// [GROUP BY <group cols>]) g`. Group columns and the filter are scoped by the
/// per-tenant RLS context (this is a read, like `run_list`). **Safety:** every
/// identifier (group column, aggregate field, alias) goes through `quote_ident`;
/// the aggregate function comes from the allowlisted [`AggFunc`] enum, never
/// client text; filter values are bound parameters.
async fn run_aggregate<C: GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
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
    // Output column names (group columns + aggregate aliases) must be unique:
    // a collision would make `to_jsonb` silently drop one value.
    let mut seen: std::collections::BTreeSet<&str> = std::collections::BTreeSet::new();
    for name in spec
        .group_by
        .iter()
        .map(String::as_str)
        .chain(spec.aggregates.iter().map(|a| a.alias.as_str()))
    {
        if !seen.insert(name) {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("duplicate aggregate output column '{name}'"),
            });
        }
    }

    let mut select_cols: Vec<String> =
        Vec::with_capacity(spec.group_by.len() + spec.aggregates.len());
    let mut group_cols: Vec<String> = Vec::with_capacity(spec.group_by.len());
    for col in &spec.group_by {
        let ident = quote_ident(col)?;
        select_cols.push(ident.clone());
        group_cols.push(ident);
    }
    for agg in &spec.aggregates {
        select_cols.push(build_aggregate_expr(agg)?);
    }

    let mut params: Vec<BoxedParam> = Vec::new();
    let where_sql = build_where(op.filter.as_ref(), &mut params)?;
    let group_sql = if group_cols.is_empty() {
        String::new()
    } else {
        format!(" GROUP BY {}", group_cols.join(", "))
    };
    // `op.sort` orders the output (a group column or an aggregate alias); `LIMIT`
    // bounds the result so a high-cardinality `group_by` can't return unbounded
    // rows.
    let order_sql = build_order_by(op.sort.as_ref())?;
    let limit = op.limit.unwrap_or(1000).min(10_000) as i64;
    params.push(Box::new(limit));
    let limit_idx = params.len();
    let sql = format!(
        "SELECT to_jsonb(g) AS row FROM (SELECT {} FROM {table} t{where_sql}{group_sql}) g{order_sql} LIMIT ${limit_idx}",
        select_cols.join(", ")
    );
    let rows = client
        .query(sql.as_str(), &as_param_refs(&params))
        .await
        .map_err(|e| backend(&e))?;
    let data: Vec<Value> = rows.iter().map(|r| r.get::<_, Value>("row")).collect();
    let affected = data.len() as u64;
    Ok(DataResult::new(data, affected))
}

/// Builds one `func(arg) AS alias` aggregate expression. `func` is the
/// allowlisted enum; `arg` is `*` for `count` with no field, else the quoted
/// `field`; `sum`/`avg`/`min`/`max` require a field.
fn build_aggregate_expr(agg: &Aggregate) -> DataPlaneResult<String> {
    let alias = quote_ident(&agg.alias)?;
    let func = match agg.func {
        AggFunc::Count => "count",
        AggFunc::Sum => "sum",
        AggFunc::Avg => "avg",
        AggFunc::Min => "min",
        AggFunc::Max => "max",
    };
    let arg = match (&agg.field, agg.func) {
        (Some(field), _) => quote_ident(field)?,
        // `count(*)` only without DISTINCT; everything else needs a field.
        (None, AggFunc::Count) if !agg.distinct => "*".to_string(),
        (None, _) => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("aggregate '{func}' requires a `field`"),
            })
        }
    };
    let distinct = if agg.distinct { "DISTINCT " } else { "" };
    Ok(format!("{func}({distinct}{arg}) AS {alias}"))
}

fn backend(e: &tokio_postgres::Error) -> DataPlaneError {
    // SQLSTATE class 23 = integrity constraint violation (unique/PK, foreign key,
    // not-null, check) and class 22 = data exception (invalid enum/date text,
    // numeric overflow, …). Both are the caller's fault — their VALUES don't
    // fit the schema — so they map to 409 Conflict, not an engine 5xx (a 5xx
    // makes outbox clients retry a write that can never succeed). Use the DB
    // error's own message (the top-level Display is just "db error") so the
    // client learns *what* conflicted.
    if let Some(db) = e.as_db_error() {
        let code = db.code().code();
        if code.starts_with("23") || code.starts_with("22") {
            return DataPlaneError::Conflict {
                message: db.message().to_string(),
            };
        }
        // 42P10 "no unique or exclusion constraint matching the ON CONFLICT
        // specification": the table's schema can't arbitrate this upsert
        // (shared_rls upserts key on (owner_id, <filter cols>) — the table
        // needs that composite UNIQUE). The caller's request/schema mismatch,
        // not an engine failure — 400 with the platform contract spelled out,
        // never a 502.
        if code == "42P10" {
            return DataPlaneError::InvalidRequest {
                message: format!(
                    "{} — upserts on owner-scoped (shared_rls) mounts arbitrate on \
                     (owner_id, <filter key columns>); the table needs a matching \
                     composite UNIQUE constraint",
                    db.message()
                ),
            };
        }
        // SQLSTATE class 42 = "syntax error or access rule violation": undefined
        // function (e.g. sum()/avg() on a TEXT column → 42883), undefined column
        // (42703), undefined table (42P01), datatype mismatch (42804), grouping
        // error (42803). Every one is the caller's request not fitting the schema
        // — a clean 400, NEVER an engine 5xx/502. (42P10 above is the more
        // specific upsert case; this generalises the rest of the class.)
        if code.starts_with("42") {
            return DataPlaneError::InvalidRequest {
                message: db.message().to_string(),
            };
        }
    }
    // CLIENT-side bind failures (JsonParam: "not a date" into timestamptz,
    // a malformed uuid, a string into int4) never reach the server, so there
    // is no SQLSTATE — but they are exactly as much the caller's fault as
    // their server-side 22xxx twins. Same envelope: 409, with the cause.
    let text = e.to_string();
    if text.contains("error serializing parameter") {
        let detail = std::error::Error::source(e)
            .map(|source| format!(": {source}"))
            .unwrap_or_default();
        return DataPlaneError::Conflict {
            message: format!("{text}{detail} (value does not fit the column type)"),
        };
    }
    DataPlaneError::Backend { message: text }
}

/// Boxes a JSON value as a Postgres parameter whose wire encoding adapts to the
/// target column type (see [`JsonParam`]). One boxed param per value; the
/// adaptation happens later, at serialize time, when the column type is known.
fn json_param(value: &Value) -> BoxedParam {
    Box::new(JsonParam(value.clone()))
}

/// A JSON value bound as a Postgres parameter whose binary encoding is chosen
/// from the *target column type*, not from the JSON shape.
///
/// Postgres infers each `$n` placeholder's type from its use site (the column it
/// is assigned to or compared against) during `PREPARE`, so by the time
/// `to_sql` runs we know `ty` and can pick `i16`/`i32`/`i64`, `f32`/`f64`, a
/// parsed `uuid`/timestamp, text, bool, or a jsonb document. The previous
/// "every JSON integer is an `i64`" binding could not serialize into `int2`/
/// `int4` columns (`error serializing parameter`); this adapts instead.
///
/// `accepts` returns `true` for every type: we adapt inside `to_sql`. A genuine
/// mismatch (a JSON string for an `int4`/`bytea` column, a number for `numeric`)
/// is rejected by the inner `to_sql_checked` delegation as a `WrongType`
/// serialization error — never written as garbage bytes. That error currently
/// surfaces as a `Backend` (502); reclassifying serialization failures as
/// `InvalidRequest` (400), and adding real `numeric`/array support, is the
/// shared value-coercion follow-up tracked in product-plan doc 02.
#[derive(Debug)]
struct JsonParam(Value);

impl ToSql for JsonParam {
    fn to_sql(
        &self,
        ty: &Type,
        out: &mut BytesMut,
    ) -> Result<IsNull, Box<dyn std::error::Error + Sync + Send>> {
        // For the fall-through arms we delegate through `to_sql_checked` (not the
        // raw `to_sql`) so the inner type's own `accepts` runs: a genuine
        // mismatch (a JSON string for an `int4`/`bytea` column, a number for
        // `numeric`) becomes a clean `WrongType` serialization error instead of
        // garbage bytes written under that column's binary OID. Without this,
        // `bytea` (which accepts any bytes) and length-coincident cases would be
        // silently corrupted. The explicit arms already match `ty`, so they use
        // the cheaper `to_sql`.
        match &self.0 {
            Value::Null => Ok(IsNull::Yes),
            Value::Bool(b) => b.to_sql_checked(ty, out),
            Value::Number(n) => match *ty {
                Type::INT2 => i16::try_from(json_i64(n)?)?.to_sql(ty, out),
                Type::INT4 => i32::try_from(json_i64(n)?)?.to_sql(ty, out),
                Type::INT8 => json_i64(n)?.to_sql(ty, out),
                Type::FLOAT4 => {
                    (n.as_f64().ok_or("number is not representable as f64")? as f32).to_sql(ty, out)
                }
                Type::FLOAT8 => n.as_f64().ok_or("number is not representable as f64")?.to_sql(ty, out),
                // numeric/decimal columns (money-like: totals, prices,
                // salaries) — serde's Value only serializes into json/jsonb,
                // so without this arm EVERY filter or update touching a
                // numeric column was a 502. serde prints JSON numbers as
                // plain decimal strings, which encode directly.
                Type::NUMERIC => {
                    write_pg_numeric(&n.to_string(), out)?;
                    Ok(IsNull::No)
                }
                // json/jsonb → number document; anything else → checked
                // delegate, which rejects a true mismatch rather than corrupt it.
                _ => self.0.to_sql_checked(ty, out),
            },
            Value::String(s) => match *ty {
                Type::UUID => s.parse::<uuid::Uuid>()?.to_sql(ty, out),
                Type::TIMESTAMPTZ => s.parse::<chrono::DateTime<chrono::Utc>>()?.to_sql(ty, out),
                Type::TIMESTAMP => s.parse::<chrono::NaiveDateTime>()?.to_sql(ty, out),
                Type::DATE => s.parse::<chrono::NaiveDate>()?.to_sql(ty, out),
                Type::JSON | Type::JSONB => self.0.to_sql(ty, out),
                // Enum slots (filters/updates against enum columns — the live
                // UI's board groupings depend on them): the binary wire format
                // of an enum value IS its label text, but this postgres-types
                // version's `&str` does not `accepts` enum kinds, which made
                // every enum-column filter a 502. Write the label and let the
                // SERVER validate it — an invalid label raises 22P02, which
                // classifies as a clean 409 Conflict.
                _ if matches!(ty.kind(), Kind::Enum(_)) => {
                    out.extend_from_slice(s.as_bytes());
                    Ok(IsNull::No)
                }
                // text/varchar/bpchar/name accept the string; a non-text column
                // (int4, bytea, …) is rejected by the inner `accepts`.
                _ => s.to_sql_checked(ty, out),
            },
            // arrays and objects are sent as a jsonb document (rejected if the
            // column is not json/jsonb).
            other => other.to_sql_checked(ty, out),
        }
    }

    fn accepts(_ty: &Type) -> bool {
        true
    }

    to_sql_checked!();
}

/// PostgreSQL `numeric` binary wire encoding for a plain decimal string
/// (`[-]digits[.digits]` — exactly what serde_json prints for ordinary
/// numbers; exponent forms are rejected with a clear error). Layout: i16
/// ndigits, i16 weight (position of the most significant base-10000 group
/// relative to the decimal point), u16 sign (0x0000 +, 0x4000 −), u16 dscale
/// (decimal digits after the point), then ndigits × i16 base-10000 groups.
fn write_pg_numeric(
    text: &str,
    out: &mut BytesMut,
) -> Result<(), Box<dyn std::error::Error + Sync + Send>> {
    let (negative, unsigned) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text),
    };
    let (int_part, frac_part) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    if int_part.is_empty() && frac_part.is_empty()
        || !int_part.bytes().all(|byte| byte.is_ascii_digit())
        || !frac_part.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(format!("`{text}` is not a plain decimal numeric literal").into());
    }
    let dscale = u16::try_from(frac_part.len())?;
    // Base-10000 groups: int digits left-padded, frac digits right-padded.
    let int_trimmed = int_part.trim_start_matches('0');
    let mut padded = "0".repeat((4 - int_trimmed.len() % 4) % 4) + int_trimmed;
    let int_groups = padded.len() / 4;
    padded += frac_part;
    padded += &"0".repeat((4 - padded.len() % 4) % 4);
    let mut digits: Vec<i16> = padded
        .as_bytes()
        .chunks(4)
        .map(|chunk| std::str::from_utf8(chunk).unwrap().parse::<i16>().unwrap())
        .collect();
    // weight counts from the first group; leading zero groups (a fraction
    // like 0.00001) shift it further down, trailing zero groups just shrink.
    let mut weight = int_groups as i16 - 1;
    while digits.first() == Some(&0) {
        digits.remove(0);
        weight -= 1;
    }
    while digits.last() == Some(&0) {
        digits.pop();
    }
    if digits.is_empty() {
        weight = 0;
    }
    out.extend_from_slice(&(i16::try_from(digits.len())?).to_be_bytes());
    out.extend_from_slice(&weight.to_be_bytes());
    out.extend_from_slice(&(if negative && !digits.is_empty() { 0x4000u16 } else { 0 }).to_be_bytes());
    out.extend_from_slice(&dscale.to_be_bytes());
    for digit in digits {
        out.extend_from_slice(&digit.to_be_bytes());
    }
    Ok(())
}

/// Coerces a JSON number to `i64` for integer columns, accepting an
/// integral-valued float (`3.0`) as well as a JSON integer (`3`).
fn json_i64(n: &serde_json::Number) -> Result<i64, Box<dyn std::error::Error + Sync + Send>> {
    if let Some(i) = n.as_i64() {
        return Ok(i);
    }
    if let Some(f) = n.as_f64() {
        if f.fract() == 0.0 && f >= i64::MIN as f64 && f <= i64::MAX as f64 {
            return Ok(f as i64);
        }
    }
    Err(format!("number {n} is not an integer").into())
}

fn as_param_refs(params: &[BoxedParam]) -> Vec<&(dyn ToSql + Sync)> {
    params
        .iter()
        .map(|p| p.as_ref() as &(dyn ToSql + Sync))
        .collect()
}

/// A compiled predicate, with **constant folding** so a filter that reduces to a
/// tautology (`NOT (FALSE)`, `a OR TRUE`) is recognised as [`Pred::Unconstrained`]
/// and refused by the mutation guards — never silently turned into `WHERE TRUE`.
/// Constants never carry bound params (the params of a discarded branch are
/// rolled back), so placeholder numbering stays correct.
#[derive(Debug)]
enum Pred {
    /// Constrains nothing (logical TRUE) → rendered as no `WHERE` clause, so
    /// update/delete's empty-filter guard fires.
    Unconstrained,
    /// Matches no rows (logical FALSE) → rendered as `FALSE`. A real predicate.
    AlwaysFalse,
    /// A concrete SQL boolean expression referencing bound params.
    Sql(String),
}

/// Wraps [`compile_filter`] into a ` WHERE …` clause. A tautology folds to
/// `Unconstrained` → `""`, so the no-full-table guard on update/delete fires;
/// an explicit match-nothing (`$or:[]`, `$in:[]`) renders ` WHERE FALSE`.
fn build_where(filter: Option<&Value>, params: &mut Vec<BoxedParam>) -> DataPlaneResult<String> {
    Ok(match compile_filter(filter, params)? {
        Pred::Unconstrained => String::new(),
        Pred::AlwaysFalse => " WHERE FALSE".to_string(),
        // Parenthesize the whole client predicate so a caller that appends an
        // owner predicate (`{where_sql} AND owner_id = $n` in update/delete) ANDs
        // it as one unit — a top-level `$or` must not leave a branch unscoped.
        Pred::Sql(clause) => format!(" WHERE ({clause})"),
    })
}

/// Parses the JSON filter into the shared engine-neutral [`Filter`] tree (the
/// single grammar + validation, in `data-plane-core`) and lowers it to a
/// Postgres boolean [`Pred`]. `None` constrains nothing. A thin wrapper so
/// `build_where` and the unit tests share one entry point.
fn compile_filter(filter: Option<&Value>, params: &mut Vec<BoxedParam>) -> DataPlaneResult<Pred> {
    match filter {
        Some(value) => lower_pg(&Filter::parse(value)?, params),
        None => Ok(Pred::Unconstrained),
    }
}

/// Joins AND-parts into a [`Pred`]; an empty set constrains nothing.
fn and_join(parts: Vec<String>) -> Pred {
    if parts.is_empty() {
        Pred::Unconstrained
    } else {
        Pred::Sql(parts.join(" AND "))
    }
}

/// `NOT` with constant folding: `NOT TRUE = FALSE`, `NOT FALSE = TRUE`.
fn negate(p: Pred) -> Pred {
    match p {
        Pred::Unconstrained => Pred::AlwaysFalse,
        Pred::AlwaysFalse => Pred::Unconstrained,
        Pred::Sql(s) => Pred::Sql(format!("NOT ({s})")),
    }
}

/// Lowers an engine-neutral [`Filter`] (already parsed + validated by
/// `data-plane-core`) to a Postgres boolean [`Pred`], pushing every value as a
/// bound `$n` parameter. Identifiers via `quote_ident`; comparison symbols are
/// fixed — values are never interpolated. The [`Pred`] folding gives the mutation
/// guard (a tautology → `Unconstrained` → empty `WHERE` → refused).
fn lower_pg(filter: &Filter, params: &mut Vec<BoxedParam>) -> DataPlaneResult<Pred> {
    Ok(match filter {
        Filter::And(parts) => lower_and(parts, params)?,
        Filter::Or(parts) => lower_or(parts, params)?,
        Filter::Not(inner) => negate(lower_pg(inner, params)?),
        Filter::Cmp { field, op, value } => {
            let ident = quote_ident(field)?;
            params.push(json_param(value));
            Pred::Sql(format!("{ident} {} ${}", cmp_sql(*op), params.len()))
        }
        Filter::In { field, values } => {
            let ident = quote_ident(field)?;
            if values.is_empty() {
                Pred::AlwaysFalse // `x IN ()` matches nothing
            } else {
                let mut ph = Vec::with_capacity(values.len());
                for v in values {
                    params.push(json_param(v));
                    ph.push(format!("${}", params.len()));
                }
                Pred::Sql(format!("{ident} IN ({})", ph.join(", ")))
            }
        }
        Filter::Like { field, pattern, ci } => {
            let ident = quote_ident(field)?;
            params.push(json_param(pattern));
            Pred::Sql(format!(
                "{ident} {} ${}",
                if *ci { "ILIKE" } else { "LIKE" },
                params.len()
            ))
        }
        Filter::Between { field, low, high } => {
            let ident = quote_ident(field)?;
            params.push(json_param(low));
            let lo = params.len();
            params.push(json_param(high));
            let hi = params.len();
            Pred::Sql(format!("{ident} BETWEEN ${lo} AND ${hi}"))
        }
        Filter::IsNull { field, negate } => {
            let ident = quote_ident(field)?;
            Pred::Sql(format!("{ident} IS {}NULL", if *negate { "NOT " } else { "" }))
        }
    })
}

/// AND-combine: fold `AlwaysFalse` (rolling back its params) and drop
/// `Unconstrained`; an empty/all-true set constrains nothing.
fn lower_and(parts: &[Filter], params: &mut Vec<BoxedParam>) -> DataPlaneResult<Pred> {
    let start = params.len();
    let mut sql_parts: Vec<String> = Vec::with_capacity(parts.len());
    for part in parts {
        match lower_pg(part, params)? {
            Pred::AlwaysFalse => {
                params.truncate(start);
                return Ok(Pred::AlwaysFalse);
            }
            Pred::Unconstrained => {}
            Pred::Sql(s) => sql_parts.push(s),
        }
    }
    Ok(and_join(sql_parts))
}

/// OR-combine: fold `Unconstrained` to TRUE (rolling back params) and drop
/// `AlwaysFalse`; an empty/all-false `$or` matches nothing.
fn lower_or(parts: &[Filter], params: &mut Vec<BoxedParam>) -> DataPlaneResult<Pred> {
    let start = params.len();
    let mut sql_parts: Vec<String> = Vec::with_capacity(parts.len());
    for part in parts {
        match lower_pg(part, params)? {
            Pred::Sql(s) => sql_parts.push(s),
            Pred::AlwaysFalse => {} // OR FALSE = identity
            Pred::Unconstrained => {
                params.truncate(start);
                return Ok(Pred::Unconstrained); // OR TRUE = TRUE
            }
        }
    }
    if sql_parts.is_empty() {
        return Ok(Pred::AlwaysFalse);
    }
    let ored: Vec<String> = sql_parts.into_iter().map(|p| format!("({p})")).collect();
    Ok(Pred::Sql(ored.join(" OR ")))
}

fn cmp_sql(op: CmpOp) -> &'static str {
    match op {
        CmpOp::Eq => "=",
        CmpOp::Ne => "<>",
        CmpOp::Lt => "<",
        CmpOp::Lte => "<=",
        CmpOp::Gt => ">",
        CmpOp::Gte => ">=",
    }
}

/// Compiles the `sort` map (`{column: "asc"|"desc"}`) into ` ORDER BY …`, or
/// `""` when absent. Columns via `quote_ident`; direction is an allowlist. The
/// `BTreeMap` iterates in key order, so the clause is deterministic.
fn build_order_by(
    sort: Option<&std::collections::BTreeMap<String, String>>,
) -> DataPlaneResult<String> {
    let Some(sort) = sort.filter(|s| !s.is_empty()) else {
        return Ok(String::new());
    };
    let mut parts = Vec::with_capacity(sort.len());
    for (col, dir) in sort {
        let ident = quote_ident(col)?;
        let dir_sql = match dir.to_ascii_lowercase().as_str() {
            "asc" => "ASC",
            "desc" => "DESC",
            other => {
                return Err(DataPlaneError::InvalidRequest {
                    message: format!("invalid sort direction '{other}' (use 'asc' or 'desc')"),
                })
            }
        };
        parts.push(format!("{ident} {dir_sql}"));
    }
    Ok(format!(" ORDER BY {}", parts.join(", ")))
}

async fn run_list<C: GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    let mut params: Vec<BoxedParam> = Vec::new();

    // Client filter (a Pred), optionally AND'd with a full-text predicate.
    // Param push order is the source of $n truth: filter params, then the FTS
    // query param, then the vector embedding param, then limit/offset.
    let client_pred = compile_filter(op.filter.as_ref(), &mut params)?;
    let fts = op
        .search
        .as_ref()
        .map(|s| build_search(s, &mut params))
        .transpose()?; // Option<(predicate, rank_expr)>
    let where_sql = combine_where(client_pred, fts.as_ref().map(|(p, _)| p.as_str()));

    // ORDER BY precedence: vector k-NN distance > explicit sort > FTS rank > none.
    let vec_order = op
        .vector
        .as_ref()
        .map(|v| build_vector_order(v, &mut params))
        .transpose()?; // Option<distance_expr>
    let order_sql = if let Some(ord) = &vec_order {
        // nearest first: <=>/<->/<#> are "smaller = closer".
        format!(" ORDER BY {ord} ASC")
    } else if op.sort.as_ref().is_some_and(|s| !s.is_empty()) {
        build_order_by(op.sort.as_ref())?
    } else if let Some((_, rank)) = &fts {
        format!(" ORDER BY {rank} DESC")
    } else {
        String::new()
    };

    // Vector search uses its own `k` as LIMIT; otherwise the usual list paging.
    let limit = op
        .vector
        .as_ref()
        .and_then(|v| v.k)
        .map(|k| k.min(1000))
        .unwrap_or_else(|| op.limit.unwrap_or(100).min(1000)) as i64;
    let offset = op.offset.unwrap_or(0) as i64;
    params.push(Box::new(limit));
    let limit_idx = params.len();
    params.push(Box::new(offset));
    let offset_idx = params.len();

    let sql = format!(
        "SELECT to_jsonb(t) AS row FROM {table} t{where_sql}{order_sql} LIMIT ${limit_idx} OFFSET ${offset_idx}"
    );
    let rows = client
        .query(sql.as_str(), &as_param_refs(&params))
        .await
        .map_err(|e| backend(&e))?;

    let data: Vec<Value> = rows.iter().map(|r| r.get::<_, Value>("row")).collect();
    let affected = data.len() as u64;
    Ok(DataResult::new(data, affected))
}

/// Combine the client filter [`Pred`] with an optional full-text predicate into a
/// single ` WHERE …` clause (owner-scoping on reads is enforced by RLS GUCs, so
/// it is not appended here).
fn combine_where(client: Pred, fts: Option<&str>) -> String {
    match (client, fts) {
        (Pred::AlwaysFalse, _) => " WHERE FALSE".to_string(),
        (Pred::Sql(c), Some(f)) => format!(" WHERE ({c}) AND ({f})"),
        (Pred::Sql(c), None) => format!(" WHERE ({c})"),
        (Pred::Unconstrained, Some(f)) => format!(" WHERE ({f})"),
        (Pred::Unconstrained, None) => String::new(),
    }
}

/// Allowlisted Postgres text-search configuration (`regconfig`) — inlined as a
/// literal (never from raw client text), default `english`.
fn ts_language(lang: Option<&str>) -> DataPlaneResult<&'static str> {
    Ok(match lang.unwrap_or("english").to_ascii_lowercase().as_str() {
        "english" => "english",
        "simple" => "simple",
        "spanish" => "spanish",
        "french" => "french",
        "german" => "german",
        "portuguese" => "portuguese",
        "italian" => "italian",
        "dutch" => "dutch",
        "russian" => "russian",
        other => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("unsupported search language '{other}'"),
            })
        }
    })
}

/// Lowers a [`SearchSpec`] to `(predicate, rank_expr)`: a ranked Postgres
/// full-text match over `concat_ws`-joined columns. The query string is BOUND
/// (`$n`), the language is an allowlisted literal, columns are `quote_ident`'d.
/// Both the predicate and the rank reference the same `$n` (parameter reuse).
fn build_search(
    spec: &data_plane_core::SearchSpec,
    params: &mut Vec<BoxedParam>,
) -> DataPlaneResult<(String, String)> {
    if spec.columns.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "search requires at least one column".to_string(),
        });
    }
    if spec.query.trim().is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "search requires a non-empty query".to_string(),
        });
    }
    let lang = ts_language(spec.language.as_deref())?;
    let cols = spec
        .columns
        .iter()
        .map(|c| quote_ident(c))
        .collect::<DataPlaneResult<Vec<_>>>()?;
    let doc = format!("concat_ws(' ', {})", cols.join(", "));
    params.push(Box::new(spec.query.clone()));
    let q = params.len();
    let tsv = format!("to_tsvector('{lang}', {doc})");
    let tsq = format!("websearch_to_tsquery('{lang}', ${q})");
    Ok((format!("{tsv} @@ {tsq}"), format!("ts_rank({tsv}, {tsq})")))
}

/// Lowers a [`VectorSpec`] to a pgvector distance expression `"col" <op> $n::vector`.
/// The embedding is bound as a `'[…]'` text literal cast to `vector`; the metric
/// operator is an allowlist (`cosine`→`<=>`, `l2`→`<->`, `ip`→`<#>`).
fn build_vector_order(
    spec: &data_plane_core::VectorSpec,
    params: &mut Vec<BoxedParam>,
) -> DataPlaneResult<String> {
    if spec.query.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "vector search requires a non-empty query embedding".to_string(),
        });
    }
    let col = quote_ident(&spec.column)?;
    let opsym = match spec
        .metric
        .as_deref()
        .unwrap_or("cosine")
        .to_ascii_lowercase()
        .as_str()
    {
        "cosine" => "<=>",
        "l2" | "euclidean" => "<->",
        "ip" | "inner" | "dot" => "<#>",
        other => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("unsupported vector metric '{other}'"),
            })
        }
    };
    let lit = format!(
        "[{}]",
        spec.query
            .iter()
            .map(|f| if f.is_finite() { format!("{f}") } else { "0".to_string() })
            .collect::<Vec<_>>()
            .join(",")
    );
    params.push(Box::new(lit));
    let p = params.len();
    // `$n::text::vector`, not `$n::vector`: the inner `::text` makes Postgres infer
    // the bind param as TEXT (so the bound Rust String matches), then pgvector
    // parses the text literal into a vector. A bare `$n::vector` makes the driver
    // expect a native vector param and fails to serialize the String.
    Ok(format!("{col} {opsym} ${p}::text::vector"))
}

async fn run_get<C: GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    let mut params: Vec<BoxedParam> = Vec::new();
    let where_sql = build_where(op.filter.as_ref(), &mut params)?;

    let sql = format!("SELECT to_jsonb(t) AS row FROM {table} t{where_sql} LIMIT 1");
    let row = client
        .query_opt(sql.as_str(), &as_param_refs(&params))
        .await
        .map_err(|e| backend(&e))?;

    let data: Vec<Value> = row
        .map(|r| vec![r.get::<_, Value>("row")])
        .unwrap_or_default();
    let affected = data.len() as u64;
    Ok(DataResult::new(data, affected))
}

async fn run_insert<C: GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    let Some(Value::Object(map)) = op.data.as_ref() else {
        return Err(DataPlaneError::InvalidRequest {
            message: "insert requires a JSON object in `data`".to_string(),
        });
    };
    if map.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "insert `data` must not be empty".to_string(),
        });
    }

    // Strip any client-supplied owner_id (server controls tenant scope) and
    // re-inject the trusted value from the verified identity. Matches the
    // defensive posture of the Mongo + MySQL adapters. Required because
    // tenant tables typically declare `owner_id NOT NULL` and the per-row
    // RLS policy compares it against `auth.current_user_id()`.
    // On a `tenant_owned` mount the data passes through untouched: the
    // tables are the tenant's own pre-existing schema (no owner_id column)
    // and tenant gating already happened at key→mount resolution.
    let mut columns = Vec::with_capacity(map.len() + 1);
    let mut placeholders = Vec::with_capacity(map.len() + 1);
    let mut params: Vec<BoxedParam> = Vec::with_capacity(map.len() + 1);
    let mut saw_owner_id = false;
    for (col, val) in map {
        if owner_scoped && col == "owner_id" {
            // drop client override; trusted value injected below
            saw_owner_id = true;
            continue;
        }
        columns.push(quote_ident(col)?);
        params.push(json_param(val));
        placeholders.push(format!("${}", params.len()));
    }
    let _ = saw_owner_id; // reserved for future audit logging
    if owner_scoped {
        let owner = PostgresPool::principal(identity).to_string();
        columns.push(quote_ident("owner_id")?);
        params.push(Box::new(owner));
        placeholders.push(format!("${}", params.len()));
    }

    let sql = format!(
        "INSERT INTO {table} AS t ({}) VALUES ({}) RETURNING to_jsonb(t) AS row",
        columns.join(", "),
        placeholders.join(", ")
    );
    let row = client
        .query_one(sql.as_str(), &as_param_refs(&params))
        .await
        .map_err(|e| backend(&e))?;

    Ok(DataResult::new(vec![row.get::<_, Value>("row")], 1))
}

// ── Mutating-op statement builders (pure; unit-tested below) ────────────────
//
// Each assembles the SQL + bound params for a mutating op. Invariants enforced
// here (so they're testable without a live DB):
//   * identifiers via `quote_ident` (allowlist), values via bound `$n` params;
//   * column order canonicalised (sorted) → one cached prepared statement per
//     shape regardless of JSON key order (serde_json preserves wire order here);
//   * `owner_id` server-controlled — stripped from client `data`, injected as
//     the trusted value, kept out of any SET, and added as a WHERE / conflict
//     predicate (defense in depth alongside RLS, matching the Mongo/MySQL
//     adapters);
//   * target table aliased `t` so `to_jsonb(t)` is correct even for a
//     schema-qualified resource;
//   * `returning=false` omits RETURNING (count-only, no row materialisation) —
//     honoring `ReturningMode::None`.

/// Sorted, owner_id-stripped (column, value) pairs from a JSON object.
fn writable_columns(data: &serde_json::Map<String, Value>) -> Vec<(&str, &Value)> {
    let mut cols: Vec<(&str, &Value)> = data
        .iter()
        .filter(|(k, _)| k.as_str() != "owner_id")
        .map(|(k, v)| (k.as_str(), v))
        .collect();
    cols.sort_by(|a, b| a.0.cmp(b.0));
    cols
}

/// ` AND owner_id = $n` for owner-scoped mounts; empty for `tenant_owned`
/// (`owner: None`) — the tables are the tenant's own schema, no such column.
fn owner_predicate(
    owner: Option<&str>,
    params: &mut Vec<BoxedParam>,
) -> DataPlaneResult<String> {
    match owner {
        Some(principal) => {
            params.push(Box::new(principal.to_string()));
            Ok(format!(" AND {} = ${}", quote_ident("owner_id")?, params.len()))
        }
        None => Ok(String::new()),
    }
}

fn build_update_sql(
    table: &str,
    data: &serde_json::Map<String, Value>,
    filter: Option<&Value>,
    owner: Option<&str>,
    returning: bool,
) -> DataPlaneResult<(String, Vec<BoxedParam>)> {
    let mut params: Vec<BoxedParam> = Vec::with_capacity(data.len() + 2);
    let mut assignments: Vec<String> = Vec::with_capacity(data.len());
    for (col, val) in writable_columns(data) {
        let ident = quote_ident(col)?;
        params.push(json_param(val));
        assignments.push(format!("{ident} = ${}", params.len()));
    }
    if assignments.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "update `data` has no updatable columns".to_string(),
        });
    }
    let where_sql = build_where(filter, &mut params)?;
    if where_sql.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "update requires a non-empty `filter` (refusing full-table update)".to_string(),
        });
    }
    let owner_pred = owner_predicate(owner, &mut params)?;
    let ret = if returning { " RETURNING to_jsonb(t) AS row" } else { "" };
    let sql = format!(
        "UPDATE {table} AS t SET {}{where_sql}{owner_pred}{ret}",
        assignments.join(", ")
    );
    Ok((sql, params))
}

fn build_delete_sql(
    table: &str,
    filter: Option<&Value>,
    owner: Option<&str>,
    returning: bool,
) -> DataPlaneResult<(String, Vec<BoxedParam>)> {
    let mut params: Vec<BoxedParam> = Vec::with_capacity(4);
    let where_sql = build_where(filter, &mut params)?;
    if where_sql.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "delete requires a non-empty `filter` (refusing full-table delete)".to_string(),
        });
    }
    let owner_pred = owner_predicate(owner, &mut params)?;
    let ret = if returning { " RETURNING to_jsonb(t) AS row" } else { "" };
    let sql = format!("DELETE FROM {table} AS t{where_sql}{owner_pred}{ret}");
    Ok((sql, params))
}

fn build_upsert_sql(
    table: &str,
    data: &serde_json::Map<String, Value>,
    filter: &serde_json::Map<String, Value>,
    owner: Option<&str>,
    returning: bool,
) -> DataPlaneResult<(String, Vec<BoxedParam>)> {
    let cap = data.len() + filter.len() + 1;
    let mut columns: Vec<String> = Vec::with_capacity(cap);
    let mut placeholders: Vec<String> = Vec::with_capacity(cap);
    let mut params: Vec<BoxedParam> = Vec::with_capacity(cap);
    // owner_id is part of the conflict target so ON CONFLICT arbitration (done
    // at the unique index, below RLS) is tenant-local — a tenant cannot collide
    // with another tenant's row. Requires a UNIQUE index on (owner_id, key…).
    // `tenant_owned` mounts (owner: None) arbitrate on the caller's keys only:
    // the whole database is one tenant's, so there is no cross-tenant index.
    let mut conflict_cols: Vec<String> = match owner {
        Some(_) => vec![quote_ident("owner_id")?],
        None => Vec::new(),
    };
    let mut seen: std::collections::BTreeSet<&str> = std::collections::BTreeSet::new();
    seen.insert("owner_id");

    let mut keys: Vec<(&str, &Value)> = filter
        .iter()
        .filter(|(k, _)| k.as_str() != "owner_id")
        .map(|(k, v)| (k.as_str(), v))
        .collect();
    keys.sort_by(|a, b| a.0.cmp(b.0));
    let first_key_ident = keys.first().map(|(col, _)| quote_ident(col)).transpose()?;
    for (col, val) in keys {
        let ident = quote_ident(col)?;
        conflict_cols.push(ident.clone());
        columns.push(ident);
        params.push(json_param(val));
        placeholders.push(format!("${}", params.len()));
        seen.insert(col);
    }
    let Some(first_key_ident) = first_key_ident else {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert `filter` (conflict key) must not be empty".to_string(),
        });
    };

    let mut assignments: Vec<String> = Vec::new();
    for (col, val) in writable_columns(data) {
        if seen.contains(col) {
            continue;
        }
        let ident = quote_ident(col)?;
        columns.push(ident.clone());
        params.push(json_param(val));
        placeholders.push(format!("${}", params.len()));
        assignments.push(format!("{ident} = EXCLUDED.{ident}"));
        seen.insert(col);
    }

    // owner_id value, server-injected (immutable on conflict → not in SET).
    if let Some(principal) = owner {
        columns.push(quote_ident("owner_id")?);
        params.push(Box::new(principal.to_string()));
        placeholders.push(format!("${}", params.len()));
    }

    if assignments.is_empty() {
        // Only key columns supplied → re-assert a conflict key (no-op SET) so
        // DO UPDATE fires and RETURNING still yields the row.
        assignments.push(format!("{first_key_ident} = EXCLUDED.{first_key_ident}"));
    }

    let ret = if returning { " RETURNING to_jsonb(t) AS row" } else { "" };
    let sql = format!(
        "INSERT INTO {table} AS t ({}) VALUES ({}) ON CONFLICT ({}) DO UPDATE SET {}{ret}",
        columns.join(", "),
        placeholders.join(", "),
        conflict_cols.join(", "),
        assignments.join(", ")
    );
    Ok((sql, params))
}

/// Run a mutating statement. With `want_rows`, RETURNING rows are collected and
/// counted; otherwise `execute` returns the affected count with no row
/// materialisation. Used by update/delete/upsert alike — so an RLS-suppressed
/// upsert `DO UPDATE` is an honest 0-row result, not a `query_one` 500.
async fn execute_mutation<C: GenericClient + Sync>(
    client: &C,
    sql: &str,
    params: &[BoxedParam],
    want_rows: bool,
) -> DataPlaneResult<DataResult> {
    if want_rows {
        let rows = client
            .query(sql, &as_param_refs(params))
            .await
            .map_err(|e| backend(&e))?;
        let data: Vec<Value> = rows.iter().map(|r| r.get::<_, Value>("row")).collect();
        let affected = data.len() as u64;
        Ok(DataResult::new(data, affected))
    } else {
        let affected = client
            .execute(sql, &as_param_refs(params))
            .await
            .map_err(|e| backend(&e))?;
        Ok(DataResult::new(vec![], affected))
    }
}

/// `UPDATE … SET … WHERE … AND owner_id = $ RETURNING` — single round-trip,
/// required filter, owner-scoped, owner_id immutable. Honors `ReturningMode`.
async fn run_update<C: GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    let Some(Value::Object(data)) = op.data.as_ref() else {
        return Err(DataPlaneError::InvalidRequest {
            message: "update requires a JSON object in `data`".to_string(),
        });
    };
    // `tenant_owned` mounts pass None → no owner predicate/injection.
    let principal = PostgresPool::principal(identity).to_string();
    let owner = owner_scoped.then_some(principal.as_str());
    let want_rows = !matches!(op.returning, Some(ReturningMode::None));
    let (sql, params) = build_update_sql(&table, data, op.filter.as_ref(), owner, want_rows)?;
    execute_mutation(client, &sql, &params, want_rows).await
}

/// `DELETE … WHERE … AND owner_id = $ RETURNING` — owner-scoped, required
/// filter. Honors `ReturningMode`.
async fn run_delete<C: GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    // `tenant_owned` mounts pass None → no owner predicate/injection.
    let principal = PostgresPool::principal(identity).to_string();
    let owner = owner_scoped.then_some(principal.as_str());
    let want_rows = !matches!(op.returning, Some(ReturningMode::None));
    let (sql, params) = build_delete_sql(&table, op.filter.as_ref(), owner, want_rows)?;
    execute_mutation(client, &sql, &params, want_rows).await
}

/// `INSERT … AS t ON CONFLICT (owner_id, key…) DO UPDATE …`. Conflict key(s)
/// from `filter`; written columns from `data`; `owner_id` server-injected, part
/// of the conflict target (tenant-local arbitration) and immutable on conflict.
/// Uses `execute_mutation` (not `query_one`) so an RLS-suppressed `DO UPDATE` is
/// an honest 0-row result. Target table must have a UNIQUE index on
/// (owner_id, <conflict key(s)>). Honors `ReturningMode`.
async fn run_upsert<C: GenericClient + Sync>(
    client: &C,
    op: &DataOperation,
    identity: &RequestIdentity,
    owner_scoped: bool,
) -> DataPlaneResult<DataResult> {
    let table = quote_ident(&op.resource)?;
    let Some(Value::Object(data)) = op.data.as_ref() else {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert requires a JSON object in `data`".to_string(),
        });
    };
    let Some(Value::Object(filter)) = op.filter.as_ref() else {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert requires `filter` naming the conflict key column(s)".to_string(),
        });
    };
    // `tenant_owned` mounts pass None → no owner predicate/injection.
    let principal = PostgresPool::principal(identity).to_string();
    let owner = owner_scoped.then_some(principal.as_str());
    let want_rows = !matches!(op.returning, Some(ReturningMode::None));
    let (sql, params) = build_upsert_sql(&table, data, filter, owner, want_rows)?;
    execute_mutation(client, &sql, &params, want_rows).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn obj(v: Value) -> serde_json::Map<String, Value> {
        match v {
            Value::Object(m) => m,
            _ => panic!("expected a JSON object"),
        }
    }

    #[test]
    fn update_strips_owner_id_and_scopes_to_owner() {
        let data = obj(json!({ "owner_id": "attacker", "name": "ok" }));
        let filter = json!({ "id": 1 });
        let (sql, params) =
            build_update_sql("\"t\"", &data, Some(&filter), Some("u-trusted"), true).unwrap();
        assert!(sql.starts_with("UPDATE \"t\" AS t SET "), "{sql}");
        assert!(sql.contains("\"name\" = $1"), "{sql}");
        assert!(!sql.contains("SET \"owner_id\""), "owner_id must not be settable: {sql}");
        assert!(sql.contains(" AND \"owner_id\" = $3"), "owner predicate missing: {sql}");
        assert!(sql.contains("RETURNING to_jsonb(t)"), "{sql}");
        assert_eq!(params.len(), 3); // name, filter id, owner
    }

    // ── Track C / C1: pooler DSN repoint (pure) ──────────────────────────────
    #[test]
    fn repoint_dsn_host_replaces_only_host_port() {
        use super::repoint_dsn_host;
        // Direct DSN's db/user/password/sslmode are preserved; only host:port moves.
        assert_eq!(
            repoint_dsn_host(
                "postgres://postgres:pw@postgres:5432/commerce?sslmode=require",
                "postgres://ignored:ignored@supavisor:6543/postgres"
            ),
            "postgres://postgres:pw@supavisor:6543/commerce?sslmode=require"
        );
        // postgresql:// scheme + no userinfo on the source DSN.
        assert_eq!(
            repoint_dsn_host("postgresql://db:5432/app", "postgres://pooler:6543/x"),
            "postgresql://pooler:6543/app"
        );
        // No path/query on the source DSN.
        assert_eq!(
            repoint_dsn_host("postgres://u:p@h:5432", "postgres://pgbouncer:6432/db"),
            "postgres://u:p@pgbouncer:6432"
        );
    }

    #[test]
    fn repoint_dsn_host_leaves_keyword_and_malformed_unchanged() {
        use super::repoint_dsn_host;
        // Keyword-form DSN is NOT URL-form → returned unchanged (never a half-rewrite).
        let kw = "host=db.x.supabase.co port=5432 user=u password=p sslmode=verify-full";
        assert_eq!(repoint_dsn_host(kw, "postgres://supavisor:6543/db"), kw);
        // A pooler URL with no parseable host → fall back to the direct DSN.
        let direct = "postgres://u:p@h:5432/db";
        assert_eq!(repoint_dsn_host(direct, "postgres:///onlydb"), direct);
        assert_eq!(repoint_dsn_host(direct, "not-a-url"), direct);
    }

    #[test]
    fn pooler_authority_extracts_host_port() {
        use super::pooler_authority;
        assert_eq!(
            pooler_authority("postgres://u:p@supavisor:6543/db?x=1").as_deref(),
            Some("supavisor:6543")
        );
        assert_eq!(
            pooler_authority("postgresql://pgbouncer:6432").as_deref(),
            Some("pgbouncer:6432")
        );
        assert_eq!(pooler_authority("postgres:///db").as_deref(), None);
        assert_eq!(pooler_authority("redis://x:6379").as_deref(), None);
    }

    #[test]
    fn tls_mode_matches_sslmode_and_max_upgrade() {
        use super::{effective_tls_mode, TlsMode};
        // Baseline: require encrypts but doesn't verify; verify-* verifies;
        // prefer/unset stays NoTls (local parity).
        assert_eq!(
            effective_tls_mode("postgres://u:p@db.x.supabase.co:5432/db?sslmode=require", false),
            Some(TlsMode::Require)
        );
        assert_eq!(
            effective_tls_mode("host=db.x.supabase.co sslmode=verify-full user=u", false),
            Some(TlsMode::Verify)
        );
        assert_eq!(effective_tls_mode("postgres://postgres:pw@postgres:5432/commerce", false), None);
        assert_eq!(effective_tls_mode("postgres://u:p@h:5432/db?sslmode=prefer", false), None);
        // Phase 6: SECURITY_MODE=max UPGRADES `require` to real verification
        // (closes the accept-any-cert MITM hole) — but never weakens a NoTls DSN.
        assert_eq!(
            effective_tls_mode("postgres://u:p@h:5432/db?sslmode=require", true),
            Some(TlsMode::Verify)
        );
        assert_eq!(effective_tls_mode("postgres://postgres:pw@postgres:5432/commerce", true), None);
    }

    #[test]
    fn tenant_owned_writes_have_no_owner_sql() {
        // `owner: None` (Isolation::TenantOwned): the tenant's own pre-existing
        // tables have no owner_id column — any owner SQL would 42703.
        let data = obj(json!({ "name": "ok" }));
        let filter = json!({ "id": 1 });
        let (sql, params) =
            build_update_sql("\"t\"", &data, Some(&filter), None, true).unwrap();
        assert!(!sql.contains("owner_id"), "{sql}");
        assert_eq!(params.len(), 2); // name + filter id only
        // The full-table refusals are isolation-independent.
        assert!(build_update_sql("\"t\"", &data, None, None, true).is_err());

        let (sql, params) = build_delete_sql("\"t\"", Some(&filter), None, true).unwrap();
        assert!(!sql.contains("owner_id"), "{sql}");
        assert_eq!(params.len(), 1);
        assert!(build_delete_sql("\"t\"", None, None, true).is_err());

        let (sql, _) = build_upsert_sql(
            "\"t\"",
            &obj(json!({ "name": "ok" })),
            &obj(json!({ "email": "a@b.c" })),
            None,
            true,
        )
        .unwrap();
        assert!(sql.contains("ON CONFLICT (\"email\")"), "caller keys only: {sql}");
        assert!(!sql.contains("owner_id"), "{sql}");

        // CreateTable DDL: no owner_id synthesis on tenant_owned mounts.
        let mut req = ddl(SchemaDdlOp::CreateTable, "t");
        req.columns = Some(vec![DdlColumnDef {
            name: "id".into(),
            normalized_type: NormalizedType::Integer,
            nullable: false,
            default: None,
            enum_values: None,
        }]);
        req.primary_key = Some(vec!["id".into()]);
        let plan = build_pg_ddl("public", &req, false).unwrap();
        assert!(!plan.statements[0].contains("owner_id"), "{}", plan.statements[0]);
        let scoped = build_pg_ddl("public", &req, true).unwrap();
        assert!(scoped.statements[0].contains("owner_id"), "{}", scoped.statements[0]);
    }

    #[test]
    fn update_refuses_empty_filter() {
        let data = obj(json!({ "name": "x" }));
        // A refused mutation is a client error (400), never a 5xx backend error.
        let err = build_update_sql("\"t\"", &data, None, Some("u"), true).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{err:?}");
        assert!(build_update_sql("\"t\"", &data, Some(&json!({})), Some("u"), true).is_err());
    }

    #[test]
    fn update_rejects_injection_in_column_name() {
        let data = obj(json!({ "evil;--": 1 }));
        let err =
            build_update_sql("\"t\"", &data, Some(&json!({ "id": 1 })), Some("u"), true).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidIdentifier { .. }), "{err:?}");
    }

    #[test]
    fn columns_sorted_for_statement_cache() {
        let data = obj(json!({ "b": 1, "a": 2 }));
        let (sql, _) =
            build_update_sql("\"t\"", &data, Some(&json!({ "id": 1 })), Some("u"), true).unwrap();
        assert!(sql.find("\"a\"").unwrap() < sql.find("\"b\"").unwrap(), "{sql}");
    }

    #[test]
    fn returning_false_omits_returning_clause() {
        let data = obj(json!({ "name": "x" }));
        let (sql, _) =
            build_update_sql("\"t\"", &data, Some(&json!({ "id": 1 })), Some("u"), false).unwrap();
        assert!(!sql.contains("RETURNING"), "{sql}");
    }

    #[test]
    fn delete_scopes_owner_and_refuses_empty_filter() {
        let err = build_delete_sql("\"t\"", None, Some("u"), true).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{err:?}");
        let (sql, params) = build_delete_sql("\"t\"", Some(&json!({ "id": 1 })), Some("u-t"), true).unwrap();
        assert!(sql.starts_with("DELETE FROM \"t\" AS t"), "{sql}");
        assert!(sql.contains(" AND \"owner_id\" = $2"), "{sql}");
        assert_eq!(params.len(), 2);
    }

    #[test]
    fn upsert_forces_owner_into_conflict_target() {
        let data = obj(json!({ "name": "x" }));
        let filter = obj(json!({ "email": "a@b.c" }));
        let (sql, _) = build_upsert_sql("\"t\"", &data, &filter, Some("u"), true).unwrap();
        assert!(sql.contains("ON CONFLICT (\"owner_id\", \"email\")"), "{sql}");
        assert!(sql.contains("\"name\" = EXCLUDED.\"name\""), "{sql}");
        assert!(!sql.contains("\"owner_id\" = EXCLUDED"), "owner must be immutable on conflict: {sql}");
        assert!(sql.starts_with("INSERT INTO \"t\" AS t ("), "{sql}");
    }

    #[test]
    fn upsert_requires_a_real_conflict_key() {
        let data = obj(json!({ "name": "x" }));
        assert!(build_upsert_sql("\"t\"", &data, &obj(json!({})), Some("u"), true).is_err());
        assert!(build_upsert_sql("\"t\"", &data, &obj(json!({ "owner_id": "x" })), Some("u"), true).is_err());
    }

    #[test]
    fn upsert_key_only_data_uses_noop_set() {
        let data = obj(json!({}));
        let filter = obj(json!({ "id": 1 }));
        let (sql, _) = build_upsert_sql("\"t\"", &data, &filter, Some("u"), true).unwrap();
        assert!(sql.contains("DO UPDATE SET \"id\" = EXCLUDED.\"id\""), "{sql}");
    }

    // --- JsonParam: the binary encoding adapts to the target column type ---

    /// Encode `value` as if bound to a column of `ty`; returns the wire bytes or
    /// the serialization error.
    fn encode(value: Value, ty: &Type) -> Result<(IsNull, BytesMut), String> {
        let mut buf = BytesMut::new();
        match JsonParam(value).to_sql(ty, &mut buf) {
            Ok(is_null) => Ok((is_null, buf)),
            Err(e) => Err(e.to_string()),
        }
    }

    #[test]
    fn json_int_adapts_to_int2_int4_int8_widths() {
        // The bug this fixes: a JSON integer used to bind only as i64 (8 bytes),
        // failing on int2/int4 columns. Now the width follows the column type.
        assert_eq!(encode(json!(5), &Type::INT2).unwrap().1.len(), 2);
        assert_eq!(encode(json!(5), &Type::INT4).unwrap().1.len(), 4);
        assert_eq!(encode(json!(5), &Type::INT8).unwrap().1.len(), 8);
    }

    #[test]
    fn json_integral_float_binds_to_int() {
        // 3.0 (a JSON float) is a valid integer value for an int column.
        assert_eq!(encode(json!(3.0), &Type::INT4).unwrap().1.len(), 4);
    }

    #[test]
    fn json_int_overflow_for_narrow_column_errors() {
        // 5e9 does not fit in int4 → a real client error, not silent truncation.
        assert!(encode(json!(5_000_000_000_i64), &Type::INT4).is_err());
        // A fractional value cannot be an integer.
        assert!(encode(json!(2.5), &Type::INT4).is_err());
    }

    #[test]
    fn json_float_adapts_to_float4_float8() {
        assert_eq!(encode(json!(2.5), &Type::FLOAT4).unwrap().1.len(), 4);
        assert_eq!(encode(json!(2.5), &Type::FLOAT8).unwrap().1.len(), 8);
    }

    #[test]
    fn json_string_parses_into_uuid() {
        let (is_null, buf) =
            encode(json!("550e8400-e29b-41d4-a716-446655440000"), &Type::UUID).unwrap();
        assert!(matches!(is_null, IsNull::No));
        assert_eq!(buf.len(), 16, "uuid is 16 binary bytes");
        assert!(encode(json!("not-a-uuid"), &Type::UUID).is_err());
    }

    #[test]
    fn json_string_parses_into_timestamptz() {
        assert!(encode(json!("2026-06-02T12:00:00Z"), &Type::TIMESTAMPTZ).is_ok());
        assert!(encode(json!("nonsense"), &Type::TIMESTAMPTZ).is_err());
    }

    #[test]
    fn json_string_parses_into_naive_timestamp_and_date() {
        assert!(encode(json!("2026-06-02T12:00:00"), &Type::TIMESTAMP).is_ok());
        assert!(encode(json!("2026-06-02"), &Type::DATE).is_ok());
        assert!(encode(json!("not-a-date"), &Type::DATE).is_err());
    }

    #[test]
    fn json_string_into_jsonb_is_a_json_string_document() {
        // A JSON string bound to a jsonb column is stored as a jsonb string.
        let (_, buf) = encode(json!("hello"), &Type::JSONB).unwrap();
        assert_eq!(buf[0], 1, "jsonb version byte");
    }

    // --- filter compiler (rich reads): operators, boolean, injection-safety ---

    /// Compile a filter and return (sql_without_where, n_params). `Unconstrained`
    /// renders `""`, `AlwaysFalse` renders `FALSE`.
    fn wsql(filter: Value) -> (String, usize) {
        let mut params: Vec<BoxedParam> = Vec::new();
        let sql = match compile_filter(Some(&filter), &mut params).unwrap() {
            Pred::Unconstrained => String::new(),
            Pred::AlwaysFalse => "FALSE".to_string(),
            Pred::Sql(s) => s,
        };
        (sql, params.len())
    }

    #[test]
    fn filter_equality_is_backward_compatible_and_sorted() {
        // Legacy `{col: scalar}` map still compiles to sorted equality predicates.
        let (sql, n) = wsql(json!({ "b": 2, "a": 1 }));
        assert_eq!(sql, "\"a\" = $1 AND \"b\" = $2", "{sql}");
        assert_eq!(n, 2);
    }

    #[test]
    fn filter_empty_contributes_no_predicate() {
        // `{}`, absent, and empty `$and` constrain nothing → render to "" so the
        // update/delete empty-filter guard fires.
        assert_eq!(wsql(json!({})).0, "");
        assert_eq!(wsql(json!({ "$and": [] })).0, "");
        let mut p: Vec<BoxedParam> = Vec::new();
        assert!(matches!(
            compile_filter(None, &mut p).unwrap(),
            Pred::Unconstrained
        ));
    }

    #[test]
    fn filter_tautology_folds_to_unconstrained_and_mutation_guard_refuses() {
        // THE data-loss fix: a filter that constant-folds to TRUE must be treated
        // as "no predicate" so update/delete refuse it, not run WHERE TRUE.
        assert_eq!(wsql(json!({ "$not": { "$or": [] } })).0, "", "NOT(FALSE) → unconstrained");
        assert_eq!(wsql(json!({ "$not": { "a": { "$in": [] } } })).0, "", "NOT(col IN ()) → unconstrained");
        assert_eq!(wsql(json!({ "$or": [{ "a": 1 }, { "$not": { "$or": [] } }] })).0, "", "x OR TRUE → unconstrained");
        // the discarded branch's param is rolled back (no orphan placeholders).
        assert_eq!(wsql(json!({ "$or": [{ "a": 1 }, { "$not": { "$or": [] } }] })).1, 0);
        // and the guard actually refuses it on a real mutation:
        let data = obj(json!({ "name": "x" }));
        for taut in [json!({ "$not": { "$or": [] } }), json!({ "$or": [{ "a": 1 }, { "$not": { "$or": [] } }] })] {
            let e = build_update_sql("\"t\"", &data, Some(&taut), Some("u"), true).unwrap_err();
            assert!(matches!(e, DataPlaneError::InvalidRequest { .. }), "update {taut}: {e:?}");
            let e = build_delete_sql("\"t\"", Some(&taut), Some("u"), true).unwrap_err();
            assert!(matches!(e, DataPlaneError::InvalidRequest { .. }), "delete {taut}: {e:?}");
        }
        // an explicit match-nothing is NOT a tautology — it's a safe predicate.
        assert_eq!(wsql(json!({ "$or": [] })).0, "FALSE");
        assert_eq!(wsql(json!({ "$not": {} })).0, "FALSE", "NOT(everything) = nothing");
    }

    #[test]
    fn filter_comparison_operators() {
        assert_eq!(wsql(json!({ "age": { "$gte": 18 } })).0, "\"age\" >= $1");
        assert_eq!(wsql(json!({ "age": { "$ne": 0 } })).0, "\"age\" <> $1");
        // multiple operators on one column AND together, operator keys sorted.
        let (sql, n) = wsql(json!({ "age": { "$lt": 65, "$gte": 18 } }));
        assert_eq!(sql, "\"age\" >= $1 AND \"age\" < $2", "{sql}");
        assert_eq!(n, 2);
    }

    #[test]
    fn filter_in_between_null_like() {
        assert_eq!(wsql(json!({ "s": { "$in": ["a", "b"] } })).0, "\"s\" IN ($1, $2)");
        assert_eq!(wsql(json!({ "s": { "$in": [] } })).0, "FALSE"); // matches nothing
        assert_eq!(wsql(json!({ "age": { "$between": [18, 65] } })).0, "\"age\" BETWEEN $1 AND $2");
        assert_eq!(wsql(json!({ "x": { "$null": true } })).0, "\"x\" IS NULL");
        assert_eq!(wsql(json!({ "x": { "$null": false } })).0, "\"x\" IS NOT NULL");
        assert_eq!(wsql(json!({ "n": { "$ilike": "%a%" } })).0, "\"n\" ILIKE $1");
    }

    #[test]
    fn filter_all_binary_operators_map_to_correct_sql() {
        for (op, sym) in [
            ("$eq", "="), ("$ne", "<>"), ("$lt", "<"), ("$lte", "<="),
            ("$gt", ">"), ("$gte", ">="), ("$like", "LIKE"), ("$ilike", "ILIKE"),
        ] {
            let (sql, n) = wsql(json!({ "c": { op: 1 } }));
            assert_eq!(sql, format!("\"c\" {sym} $1"), "operator {op}");
            assert_eq!(n, 1, "operator {op} binds one param");
        }
    }

    #[test]
    fn filter_nested_boolean_recursion() {
        // $or containing a nested $and, and $not of a compound filter.
        let (sql, n) = wsql(json!({ "$or": [{ "$and": [{ "a": 1 }, { "b": 2 }] }, { "c": 3 }] }));
        assert_eq!(sql, "(\"a\" = $1 AND \"b\" = $2) OR (\"c\" = $3)", "{sql}");
        assert_eq!(n, 3);
        assert_eq!(
            wsql(json!({ "$not": { "$or": [{ "a": 1 }, { "b": 2 }] } })).0,
            "NOT ((\"a\" = $1) OR (\"b\" = $2))"
        );
    }

    #[test]
    fn filter_in_list_length_is_capped() {
        let big: Vec<i64> = (0..=(data_plane_core::filter::MAX_IN_LEN as i64)).collect();
        let mut p: Vec<BoxedParam> = Vec::new();
        let e = compile_filter(Some(&json!({ "a": { "$in": big } })), &mut p).unwrap_err();
        assert!(matches!(e, DataPlaneError::InvalidRequest { .. }), "{e:?}");
    }

    #[test]
    fn filter_boolean_composition() {
        let (sql, n) = wsql(json!({ "$or": [{ "a": 1 }, { "b": 2 }] }));
        assert_eq!(sql, "(\"a\" = $1) OR (\"b\" = $2)", "{sql}");
        assert_eq!(n, 2);
        assert_eq!(wsql(json!({ "$not": { "a": 1 } })).0, "NOT (\"a\" = $1)");
        // empty `$or` matches nothing.
        assert_eq!(wsql(json!({ "$or": [] })).0, "FALSE");
        // mixed: column predicate AND a nested $or ('$or' sorts before 'age').
        let (sql, _) = wsql(json!({ "age": { "$gte": 18 }, "$or": [{ "a": 1 }, { "b": 2 }] }));
        assert_eq!(sql, "(\"a\" = $1) OR (\"b\" = $2) AND \"age\" >= $3", "{sql}");
    }

    #[test]
    fn filter_rejects_injection_and_unknown_operators() {
        let mut p: Vec<BoxedParam> = Vec::new();
        // column name injection → InvalidIdentifier (via quote_ident)
        let e = compile_filter(Some(&json!({ "a;DROP TABLE x;--": 1 })), &mut p).unwrap_err();
        assert!(matches!(e, DataPlaneError::InvalidIdentifier { .. }), "{e:?}");
        // injection inside an operator column
        let e = compile_filter(Some(&json!({ "x\"--": { "$gt": 1 } })), &mut p).unwrap_err();
        assert!(matches!(e, DataPlaneError::InvalidIdentifier { .. }), "{e:?}");
        // unknown operator → InvalidRequest (never interpolated)
        let e = compile_filter(Some(&json!({ "a": { "$drop": 1 } })), &mut p).unwrap_err();
        assert!(matches!(e, DataPlaneError::InvalidRequest { .. }), "{e:?}");
        // malformed $between / $in / $null
        assert!(compile_filter(Some(&json!({ "a": { "$between": [1] } })), &mut p).is_err());
        assert!(compile_filter(Some(&json!({ "a": { "$in": 5 } })), &mut p).is_err());
        assert!(compile_filter(Some(&json!({ "a": { "$null": 1 } })), &mut p).is_err());
    }

    #[test]
    fn order_by_is_quoted_directioned_and_injection_safe() {
        use std::collections::BTreeMap;
        let mut s = BTreeMap::new();
        s.insert("name".to_string(), "asc".to_string());
        s.insert("age".to_string(), "DESC".to_string()); // case-insensitive
        // BTreeMap key order → age before name.
        assert_eq!(build_order_by(Some(&s)).unwrap(), " ORDER BY \"age\" DESC, \"name\" ASC");
        assert_eq!(build_order_by(None).unwrap(), "");

        let mut bad_dir = BTreeMap::new();
        bad_dir.insert("a".to_string(), "sideways".to_string());
        assert!(matches!(
            build_order_by(Some(&bad_dir)).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));

        let mut bad_col = BTreeMap::new();
        bad_col.insert("a; DROP".to_string(), "asc".to_string());
        assert!(matches!(
            build_order_by(Some(&bad_col)).unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
    }

    #[test]
    fn aggregate_expr_builds_safe_sql() {
        let agg = |func, field: Option<&str>, alias: &str| Aggregate {
            func,
            field: field.map(str::to_string),
            distinct: false,
            alias: alias.to_string(),
        };
        assert_eq!(build_aggregate_expr(&agg(AggFunc::Count, None, "cnt")).unwrap(), "count(*) AS \"cnt\"");
        assert_eq!(build_aggregate_expr(&agg(AggFunc::Sum, Some("amount"), "total")).unwrap(), "sum(\"amount\") AS \"total\"");
        assert_eq!(build_aggregate_expr(&agg(AggFunc::Avg, Some("age"), "avg_age")).unwrap(), "avg(\"age\") AS \"avg_age\"");
        assert_eq!(build_aggregate_expr(&agg(AggFunc::Count, Some("id"), "n")).unwrap(), "count(\"id\") AS \"n\"");
        // DISTINCT
        let cd = Aggregate { func: AggFunc::Count, field: Some("email".into()), distinct: true, alias: "uniq".into() };
        assert_eq!(build_aggregate_expr(&cd).unwrap(), "count(DISTINCT \"email\") AS \"uniq\"");
        // count(DISTINCT *) is invalid → distinct requires a field
        let cd_nofield = Aggregate { func: AggFunc::Count, field: None, distinct: true, alias: "x".into() };
        assert!(matches!(build_aggregate_expr(&cd_nofield).unwrap_err(), DataPlaneError::InvalidRequest { .. }));
        // sum/avg/min/max require a field
        assert!(matches!(
            build_aggregate_expr(&agg(AggFunc::Sum, None, "x")).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
        // injection in field or alias → InvalidIdentifier (allowlist), never SQL
        assert!(matches!(
            build_aggregate_expr(&agg(AggFunc::Count, Some("a); DROP TABLE t;--"), "x")).unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
        assert!(matches!(
            build_aggregate_expr(&agg(AggFunc::Count, None, "a\" FROM secrets;--")).unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
    }

    #[test]
    fn type_mismatch_is_rejected_not_corrupted() {
        // The corruption fix: a value whose JSON kind cannot encode into the
        // target column type must error (WrongType), not write garbage bytes.
        // bytea is the dangerous one — it accepts ANY bytes, so a string would
        // otherwise be stored verbatim.
        assert!(encode(json!("deadbeef"), &Type::BYTEA).is_err(), "string→bytea must reject");
        assert!(encode(json!("42"), &Type::INT4).is_err(), "string→int4 must reject");
        assert!(encode(json!(true), &Type::INT4).is_err(), "bool→int4 must reject");
        assert!(encode(json!({ "a": 1 }), &Type::INT4).is_err(), "object→int4 must reject");
        // numeric is now a real arm (write_pg_numeric): 5 → ndigits 1,
        // weight 0, sign +, dscale 0, one base-10000 group [5].
        let (_, buf) = encode(json!(5), &Type::NUMERIC).expect("number→numeric binds");
        assert_eq!(&buf[..], &[0, 1, 0, 0, 0, 0, 0, 0, 0, 5]);
    }

    #[test]
    fn json_string_and_bool_and_null_bind_directly() {
        assert_eq!(encode(json!("hello"), &Type::TEXT).unwrap().1.len(), 5);
        assert_eq!(encode(json!(true), &Type::BOOL).unwrap().1.len(), 1);
        assert!(matches!(encode(json!(null), &Type::INT4).unwrap().0, IsNull::Yes));
    }

    #[test]
    fn json_object_binds_as_jsonb() {
        // Non-scalars go to the jsonb codec (version byte 0x01 prefix).
        let (_, buf) = encode(json!({ "a": 1 }), &Type::JSONB).unwrap();
        assert_eq!(buf[0], 1, "jsonb binary format starts with a version byte");
    }

    // --- M22 schema introspection: pure type normalizer (golden table) ---

    #[test]
    fn normalize_pg_type_golden_table() {
        use NormalizedType as N;
        for (native, expected) in [
            ("int2", N::Integer),
            ("int4", N::Integer),
            ("int8", N::Integer),
            ("float4", N::Float),
            ("float8", N::Float),
            ("numeric", N::Decimal),
            ("bool", N::Boolean),
            ("date", N::Date),
            ("timestamp", N::Datetime),
            ("timestamptz", N::Datetime),
            ("json", N::Json),
            ("jsonb", N::Json),
            ("uuid", N::Uuid),
            ("text", N::Text),
            ("varchar", N::Text),
            ("char", N::Text),
            ("bpchar", N::Text),
            ("ARRAY", N::Array),
            ("_int4", N::Array),
            ("_text", N::Array),
            // USER-DEFINED enums are resolved at the call site (needs pg_enum
            // rows); the bare normalizer honestly says Unknown.
            ("order_status", N::Unknown),
            ("bytea", N::Unknown),
            ("tsvector", N::Unknown),
        ] {
            assert_eq!(normalize_pg_type(native), expected, "udt_name {native}");
        }
    }

    // --- M22 step 2: schema DDL — pure SQL builders (golden tables) ---

    use data_plane_core::{DdlColumnDef, SchemaDdlOp, SchemaDdlRequest};

    fn col(name: &str, ty: NormalizedType) -> DdlColumnDef {
        DdlColumnDef {
            name: name.to_string(),
            normalized_type: ty,
            nullable: true,
            default: None,
            enum_values: None,
        }
    }

    fn ddl(op: SchemaDdlOp, table: &str) -> SchemaDdlRequest {
        SchemaDdlRequest {
            op,
            table: table.to_string(),
            column: None,
            column_name: None,
            columns: None,
            primary_key: None,
        }
    }

    #[test]
    fn pg_sql_type_golden_table() {
        use NormalizedType as N;
        for (ty, expected) in [
            (N::Text, "text"),
            (N::Integer, "bigint"),
            (N::Float, "double precision"),
            (N::Decimal, "numeric"),
            (N::Boolean, "boolean"),
            (N::Date, "date"),
            (N::Datetime, "timestamptz"),
            (N::Json, "jsonb"),
            (N::Uuid, "uuid"),
            (N::Array, "text[]"),
        ] {
            assert_eq!(
                pg_sql_type("public", "orders", &col("c", ty)).unwrap(),
                expected,
                "{ty:?}"
            );
        }
        // enum → the per-column named type, schema-qualified + quoted.
        assert_eq!(
            pg_sql_type("public", "orders", &col("status", NormalizedType::Enum)).unwrap(),
            "\"public\".\"orders_status_enum\""
        );
        // describe-only types are rejected, not guessed.
        for ty in [NormalizedType::Objectid, NormalizedType::Unknown] {
            assert!(matches!(
                pg_sql_type("public", "orders", &col("c", ty)).unwrap_err(),
                DataPlaneError::InvalidRequest { .. }
            ));
        }
    }

    #[test]
    fn pg_ddl_add_column_with_default_and_not_null() {
        let mut req = ddl(SchemaDdlOp::AddColumn, "orders");
        req.column = Some(DdlColumnDef {
            name: "qty".into(),
            normalized_type: NormalizedType::Integer,
            nullable: false,
            default: Some("0".into()),
            enum_values: None,
        });
        let plan = build_pg_ddl("public", &req, true).unwrap();
        assert!(plan.ensure_enum_types.is_empty());
        assert_eq!(
            plan.statements,
            vec![
                "ALTER TABLE \"public\".\"orders\" ADD COLUMN \"qty\" bigint NOT NULL DEFAULT 0"
                    .to_string()
            ]
        );
    }

    #[test]
    fn pg_ddl_add_enum_column_ensures_named_type_with_escaped_literals() {
        let mut req = ddl(SchemaDdlOp::AddColumn, "orders");
        req.column = Some(DdlColumnDef {
            name: "status".into(),
            normalized_type: NormalizedType::Enum,
            nullable: true,
            default: None,
            enum_values: Some(vec!["pending".into(), "it's".into()]),
        });
        let plan = build_pg_ddl("public", &req, true).unwrap();
        // `''` escaping locks the literal quoting (injection cannot escape).
        assert_eq!(
            plan.ensure_enum_types,
            vec![
                "CREATE TYPE \"public\".\"orders_status_enum\" AS ENUM ('pending', 'it''s')"
                    .to_string()
            ]
        );
        assert_eq!(
            plan.statements,
            vec![
                "ALTER TABLE \"public\".\"orders\" ADD COLUMN \"status\" \"public\".\"orders_status_enum\""
                    .to_string()
            ]
        );
        // enum without values is a client error.
        let mut bad = ddl(SchemaDdlOp::AddColumn, "orders");
        bad.column = Some(col("status", NormalizedType::Enum));
        assert!(matches!(
            build_pg_ddl("public", &bad, true).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
    }

    #[test]
    fn pg_ddl_alter_column_type_emits_full_target_sequence() {
        // The contract: caller sends the FULL target def; the builder lowers
        // it to DROP DEFAULT → TYPE…USING → NOT NULL → SET DEFAULT, in one tx.
        let mut req = ddl(SchemaDdlOp::AlterColumnType, "orders");
        req.column = Some(DdlColumnDef {
            name: "qty".into(),
            normalized_type: NormalizedType::Integer,
            nullable: false,
            default: Some("0".into()),
            enum_values: None,
        });
        let plan = build_pg_ddl("public", &req, true).unwrap();
        assert_eq!(
            plan.statements,
            vec![
                "ALTER TABLE \"public\".\"orders\" ALTER COLUMN \"qty\" DROP DEFAULT".to_string(),
                "ALTER TABLE \"public\".\"orders\" ALTER COLUMN \"qty\" TYPE bigint USING \"qty\"::bigint"
                    .to_string(),
                "ALTER TABLE \"public\".\"orders\" ALTER COLUMN \"qty\" SET NOT NULL".to_string(),
                "ALTER TABLE \"public\".\"orders\" ALTER COLUMN \"qty\" SET DEFAULT 0".to_string(),
            ]
        );
        // nullable + no default → DROP NOT NULL, and no SET DEFAULT step.
        let mut relaxed = ddl(SchemaDdlOp::AlterColumnType, "orders");
        relaxed.column = Some(col("qty", NormalizedType::Text));
        let plan = build_pg_ddl("public", &relaxed, true).unwrap();
        assert!(plan.statements[2].ends_with("DROP NOT NULL"), "{:?}", plan.statements);
        assert_eq!(plan.statements.len(), 3, "no default → no SET DEFAULT");
    }

    #[test]
    fn json_param_binds_strings_into_enum_slots() {
        // Enum binary wire format = the label text. postgres-types' `&str`
        // does not accept enum kinds, which made every enum-column filter
        // (the live UI's board groupings) a 502 — the adaptive binder must
        // write the label itself. Invalid labels stay the SERVER's call
        // (22P02 → 409), so any label serializes here.
        let enum_type = Type::new(
            "order_status_t".to_string(),
            999_999,
            Kind::Enum(vec!["pending".to_string(), "delivered".to_string()]),
            "public".to_string(),
        );
        let mut buf = bytes::BytesMut::new();
        let result = JsonParam(serde_json::json!("delivered")).to_sql(&enum_type, &mut buf);
        assert!(matches!(result, Ok(IsNull::No)));
        assert_eq!(&buf[..], b"delivered");
    }

    #[test]
    fn pg_numeric_binary_encoding_golden_vectors() {
        // (input, ndigits, weight, sign, dscale, base-10000 groups) — the
        // explicit tuple IS the golden-vector contract, kept verbatim.
        #[allow(clippy::type_complexity)]
        let cases: [(&str, i16, i16, u16, u16, &[i16]); 7] = [
            ("0", 0, 0, 0, 0, &[]),
            ("1", 1, 0, 0, 0, &[1]),
            ("12.34", 2, 0, 0, 2, &[12, 3400]),
            ("10000", 1, 1, 0, 0, &[1]),
            ("0.0001", 1, -1, 0, 4, &[1]),
            ("0.00001", 1, -2, 0, 5, &[1000]),
            ("-987654321.12", 4, 2, 0x4000, 2, &[9, 8765, 4321, 1200]),
        ];
        for (input, ndigits, weight, sign, dscale, groups) in cases {
            let mut buf = BytesMut::new();
            write_pg_numeric(input, &mut buf).unwrap_or_else(|e| panic!("{input}: {e}"));
            let mut expected = Vec::new();
            expected.extend_from_slice(&ndigits.to_be_bytes());
            expected.extend_from_slice(&weight.to_be_bytes());
            expected.extend_from_slice(&sign.to_be_bytes());
            expected.extend_from_slice(&dscale.to_be_bytes());
            for group in groups {
                expected.extend_from_slice(&group.to_be_bytes());
            }
            assert_eq!(&buf[..], &expected[..], "{input}");
        }
        // Exponent forms (serde only prints them for extreme f64s) fail closed.
        let mut buf = BytesMut::new();
        assert!(write_pg_numeric("1e21", &mut buf).is_err());
    }

    #[test]
    fn pg_ddl_alter_to_enum_casts_via_text() {
        let mut req = ddl(SchemaDdlOp::AlterColumnType, "orders");
        req.column = Some(DdlColumnDef {
            name: "status".into(),
            normalized_type: NormalizedType::Enum,
            nullable: true,
            default: None,
            enum_values: Some(vec!["a".into(), "b".into()]),
        });
        let plan = build_pg_ddl("public", &req, true).unwrap();
        assert_eq!(plan.ensure_enum_types.len(), 1, "enum type ensured first");
        assert!(
            plan.statements[1].contains(
                "USING \"status\"::text::\"public\".\"orders_status_enum\""
            ),
            "{:?}",
            plan.statements
        );
    }

    #[test]
    fn pg_ddl_create_table_appends_owner_id_and_primary_key() {
        let mut req = ddl(SchemaDdlOp::CreateTable, "orders");
        req.columns = Some(vec![
            DdlColumnDef {
                name: "id".into(),
                normalized_type: NormalizedType::Integer,
                nullable: false,
                default: None,
                enum_values: None,
            },
            col("note", NormalizedType::Text),
        ]);
        req.primary_key = Some(vec!["id".into()]);
        let plan = build_pg_ddl("public", &req, true).unwrap();
        assert_eq!(
            plan.statements,
            vec![
                "CREATE TABLE \"public\".\"orders\" (\"id\" bigint NOT NULL, \"note\" text, \
                 \"owner_id\" text, PRIMARY KEY (\"id\"))"
                    .to_string()
            ]
        );
        // An explicit owner_id column is respected, never duplicated.
        let mut explicit = ddl(SchemaDdlOp::CreateTable, "orders");
        explicit.columns = Some(vec![
            DdlColumnDef {
                name: "id".into(),
                normalized_type: NormalizedType::Integer,
                nullable: false,
                default: None,
                enum_values: None,
            },
            col("owner_id", NormalizedType::Uuid),
        ]);
        explicit.primary_key = Some(vec!["id".into()]);
        let plan = build_pg_ddl("public", &explicit, true).unwrap();
        assert_eq!(plan.statements[0].matches("owner_id").count(), 1, "{:?}", plan.statements);
    }

    #[test]
    fn pg_ddl_drop_ops_and_schema_scoping() {
        let mut drop_col = ddl(SchemaDdlOp::DropColumn, "orders");
        drop_col.column_name = Some("note".into());
        // schema_per_tenant: every statement targets the tenant schema.
        let plan = build_pg_ddl("tenant_acme_12345678", &drop_col, true).unwrap();
        assert_eq!(
            plan.statements,
            vec!["ALTER TABLE \"tenant_acme_12345678\".\"orders\" DROP COLUMN \"note\"".to_string()]
        );
        let plan = build_pg_ddl("public", &ddl(SchemaDdlOp::DropTable, "orders"), true).unwrap();
        assert_eq!(plan.statements, vec!["DROP TABLE \"public\".\"orders\"".to_string()]);
    }

    #[test]
    fn pg_ddl_rejects_injection_and_unsafe_defaults() {
        // table name injection
        assert!(matches!(
            build_pg_ddl("public", &ddl(SchemaDdlOp::DropTable, "orders; DROP TABLE x"), true).unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
        // column name injection
        let mut bad_col = ddl(SchemaDdlOp::AddColumn, "orders");
        bad_col.column = Some(col("evil\"; --", NormalizedType::Text));
        assert!(matches!(
            build_pg_ddl("public", &bad_col, true).unwrap_err(),
            DataPlaneError::InvalidIdentifier { .. }
        ));
        // unsafe default expression
        let mut bad_default = ddl(SchemaDdlOp::AddColumn, "orders");
        bad_default.column = Some(DdlColumnDef {
            name: "c".into(),
            normalized_type: NormalizedType::Text,
            nullable: true,
            default: Some("'x'; DROP TABLE orders".into()),
            enum_values: None,
        });
        assert!(matches!(
            build_pg_ddl("public", &bad_default, true).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
        // missing op-specific field surfaces the shared require_* error.
        assert!(matches!(
            build_pg_ddl("public", &ddl(SchemaDdlOp::AddColumn, "orders"), true).unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
    }

    #[test]
    fn fts_lowers_to_ranked_multicolumn_tsvector_match() {
        let mut p: Vec<BoxedParam> = Vec::new();
        let (pred, rank) = build_search(
            &data_plane_core::SearchSpec {
                query: "hello world".into(),
                columns: vec!["title".into(), "body".into()],
                language: Some("english".into()),
            },
            &mut p,
        )
        .unwrap();
        assert_eq!(
            pred,
            "to_tsvector('english', concat_ws(' ', \"title\", \"body\")) @@ websearch_to_tsquery('english', $1)"
        );
        assert_eq!(
            rank,
            "ts_rank(to_tsvector('english', concat_ws(' ', \"title\", \"body\")), websearch_to_tsquery('english', $1))"
        );
        assert_eq!(p.len(), 1, "query bound ONCE, reused by predicate + rank");
    }

    #[test]
    fn fts_defaults_english_and_rejects_bad_language_or_no_columns() {
        let mut p: Vec<BoxedParam> = Vec::new();
        let (pred, _) = build_search(
            &data_plane_core::SearchSpec { query: "x".into(), columns: vec!["c".into()], language: None },
            &mut p,
        )
        .unwrap();
        assert!(pred.starts_with("to_tsvector('english',"), "default lang: {pred}");
        // a hostile regconfig string is rejected, never inlined into the SQL.
        let mut p2: Vec<BoxedParam> = Vec::new();
        assert!(matches!(
            build_search(
                &data_plane_core::SearchSpec {
                    query: "x".into(),
                    columns: vec!["c".into()],
                    language: Some("english'); DROP TABLE x;--".into()),
                },
                &mut p2,
            )
            .unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
        // empty columns / empty query are rejected.
        let mut p3: Vec<BoxedParam> = Vec::new();
        assert!(build_search(
            &data_plane_core::SearchSpec { query: "x".into(), columns: vec![], language: None },
            &mut p3
        )
        .is_err());
    }

    #[test]
    fn vector_lowers_to_pgvector_distance_per_metric() {
        let mut p: Vec<BoxedParam> = Vec::new();
        let ord = build_vector_order(
            &data_plane_core::VectorSpec {
                column: "embedding".into(),
                query: vec![0.1, 0.2, 0.3],
                k: Some(5),
                metric: Some("cosine".into()),
            },
            &mut p,
        )
        .unwrap();
        assert_eq!(ord, "\"embedding\" <=> $1::text::vector");
        assert_eq!(p.len(), 1, "embedding bound as one text param, cast to vector");
        for (m, sym) in [("l2", "<->"), ("ip", "<#>"), ("cosine", "<=>")] {
            let mut pp: Vec<BoxedParam> = Vec::new();
            let o = build_vector_order(
                &data_plane_core::VectorSpec { column: "e".into(), query: vec![1.0], k: None, metric: Some(m.into()) },
                &mut pp,
            )
            .unwrap();
            assert!(o.contains(sym), "metric {m} should use {sym}: {o}");
        }
        // bad metric + empty embedding are rejected.
        let mut pe: Vec<BoxedParam> = Vec::new();
        assert!(build_vector_order(
            &data_plane_core::VectorSpec { column: "e".into(), query: vec![1.0], k: None, metric: Some("nope".into()) },
            &mut pe
        )
        .is_err());
        let mut pq: Vec<BoxedParam> = Vec::new();
        assert!(build_vector_order(
            &data_plane_core::VectorSpec { column: "e".into(), query: vec![], k: None, metric: None },
            &mut pq
        )
        .is_err());
    }
}
