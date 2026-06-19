//! The `EngineAdapter` front door: dialect selection, pool construction
//! (`open_pool`), and the `PostgresPool` handle with its tenant cross-check.

use super::conn;
use crate::resolver::MountResolver;
use async_trait::async_trait;
use data_plane_core::{
    DataOperationKind, DataPlaneError, DataPlaneResult, DatabaseMount, EngineAdapter,
    EngineCapabilities, EngineHealth, EnginePool, Isolation, RequestIdentity,
};
use deadpool_postgres::{
    Config as DeadpoolConfig, ManagerConfig, PoolConfig, RecyclingMethod, Runtime,
};
use std::sync::Arc;
use tokio_postgres::NoTls;

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

/// PostgreSQL engine adapter. Opens long-lived pools keyed by mount instead of
/// constructing a client per request (the legacy `new Client()` hot-path cost).
pub struct PostgresEngineAdapter {
    resolver: Arc<dyn MountResolver>,
    dialect: PgDialect,
}

impl PostgresEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self {
            resolver,
            dialect: PgDialect::Postgres,
        }
    }

    /// Build the adapter for a specific pgwire dialect (e.g. CockroachDB). The
    /// registry routes a mount to this adapter by matching `engine()`, so a
    /// `cockroachdb` mount lands on a Cockroach-dialect instance.
    #[must_use]
    pub fn with_dialect(resolver: Arc<dyn MountResolver>, dialect: PgDialect) -> Self {
        Self { resolver, dialect }
    }
}

/// Per-table isolation master flag (`DATA_PLANE_PER_TABLE_ISOLATION`, F1). OFF by
/// default → `shared_resources` is forced empty, so every WRITE owner-stamps
/// (byte-parity). ON → a NAMED catalog table skips owner-stamping (so it stays
/// editable without an `owner_id` column) while non-shared tables keep stamping.
fn per_table_isolation_enabled() -> bool {
    matches!(
        std::env::var("DATA_PLANE_PER_TABLE_ISOLATION").as_deref(),
        Ok("1" | "true" | "TRUE" | "on" | "ON" | "yes")
    )
}

/// Predicate-based READ owner-scoping master (`DATA_PLANE_PG_READ_PREDICATE`). OFF
/// by default → reads append NO `owner_id` predicate (byte-identical; Postgres
/// reads were RLS-GUC-scoped only). Kept SEPARATE from F1 so a deployment can
/// enable shared-catalog writes + admin-bypass (for an admin DB browser) WITHOUT
/// owner-scoping every public read — the PG read path never carried SQL
/// owner-scoping, so turning it on is a behavior change, not parity.
fn read_predicate_enabled() -> bool {
    matches!(
        std::env::var("DATA_PLANE_PG_READ_PREDICATE").as_deref(),
        Ok("1" | "true" | "TRUE" | "on" | "ON" | "yes")
    )
}

/// Admin owner-scope bypass master flag (`DATA_PLANE_ADMIN_BYPASS`, F2). OFF by
/// default → an admin identity is owner-scoped exactly like any caller
/// (byte-parity). ON → an [`RequestIdentity::is_admin`] caller's reads and
/// filter-based mutations (update/delete) skip the `owner_id` predicate so an
/// admin sees/operates across owners; admin INSERT/UPSERT still stamp `owner_id`.
fn admin_bypass_enabled() -> bool {
    matches!(
        std::env::var("DATA_PLANE_ADMIN_BYPASS").as_deref(),
        Ok("1" | "true" | "TRUE" | "on" | "ON" | "yes")
    )
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
        super::tx::SUPPORTED_OPS
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
        let dsn = match conn::pooler_url() {
            Some(pooler) => conn::repoint_dsn_host(&dsn, &pooler),
            None => dsn,
        };

        // Phase 6: the effective TLS posture. `require` keeps libpq parity
        // (encrypt, don't verify); `verify-*` (or `require` under
        // SECURITY_MODE=max) verifies the chain + hostname. None → NoTls (local).
        let max_security = std::env::var("SECURITY_MODE")
            .map(|v| v.eq_ignore_ascii_case("max"))
            .unwrap_or(false);
        let tls_mode = conn::effective_tls_mode(&dsn, max_security);
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
        if conn::statement_cache_off() {
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
                let connector = conn::rustls_connector(mode, &ca_file)?;
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
        // F1/F2 (flag-gated OFF → byte-parity): cache the per-table-isolation
        // master + the NAMED shared set + the admin-bypass master ONCE at
        // open_pool (mysql re-reads admin_bypass per dispatch; caching here keeps
        // the env read off the hot path). OFF → shared set empty + read predicate
        // off → every request runs exactly as before.
        // perf: flags hoisted to open_pool; the hot path reads cached fields only.
        let per_table_isolation = per_table_isolation_enabled();
        let shared_resources: std::sync::Arc<[String]> = if per_table_isolation {
            mount.shared_resources().into()
        } else {
            Vec::new().into()
        };
        let admin_bypass = admin_bypass_enabled();
        let read_predicate = read_predicate_enabled();
        Ok(Box::new(PostgresPool {
            mount_id: mount.id.clone(),
            tenant_id: mount.tenant_id.clone(),
            shared_pool,
            pool,
            isolation,
            search_path_schema,
            dialect: self.dialect,
            shared_resources,
            admin_bypass,
            read_predicate,
            mount,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth::unknown(
            self.dialect.engine_id(),
            pool.mount_id(),
        ))
    }
}

/// A pooled PostgreSQL connection set bound to a single mount.
pub(super) struct PostgresPool {
    pub(super) mount_id: String,
    /// The mount's tenant, captured at `open_pool`, for the defense-in-depth
    /// cross-check on every `execute`/`begin` (matching mysql/mongo/redis/http).
    pub(super) tenant_id: String,
    /// True when this is a SHARE_POOLS shared_rls pool serving many tenants:
    /// the single-tenant `check_tenant` assertion is then bypassed (per-request
    /// RLS + owner_id predicate carry isolation). See `open_pool`.
    pub(super) shared_pool: bool,
    pub(super) pool: deadpool_postgres::Pool,
    /// The resolved isolation strategy for this mount, parsed once at
    /// `open_pool`. `SharedRls` (the default) means every request runs exactly
    /// as it did before G5. Retained for diagnostics / future strategy gates.
    pub(super) isolation: Isolation,
    /// The `search_path` schema to pin for this mount, resolved ONCE at
    /// `open_pool` (the schema is per-mount, not per-request). `Some` only for
    /// `schema_per_tenant`; `None` (shared_rls / db_per_tenant) is the parity
    /// path — no `SET LOCAL search_path`, byte-identical to before G5.
    pub(super) search_path_schema: Option<String>,
    /// The pgwire dialect this pool speaks. `Postgres` is the parity path;
    /// `Cockroach` only changes transaction-isolation lowering in `begin`
    /// (CRDB is serializable-only). Captured once at `open_pool`.
    pub(super) dialect: PgDialect,
    /// F1 per-table isolation: NAMED tables that skip owner-scoping (a shared
    /// catalog readable across owners). Empty unless `DATA_PLANE_PER_TABLE_ISOLATION`
    /// is ON and the mount opted in → byte-parity (every table owner-scoped).
    pub(super) shared_resources: std::sync::Arc<[String]>,
    /// F2 master (`DATA_PLANE_ADMIN_BYPASS`), cached once at `open_pool`. OFF →
    /// an admin is owner-scoped like any caller (byte-parity).
    pub(super) admin_bypass: bool,
    /// Read-predicate master (`DATA_PLANE_PG_READ_PREDICATE`), cached once. Gates
    /// predicate-based read owner-scoping on Postgres — OFF → reads carry no
    /// appended `owner_id` predicate (RLS-GUC-only, byte-identical SQL).
    pub(super) read_predicate: bool,
    /// Retained mount for migration-time schema derivation
    /// ([`DatabaseMount::tenant_schema`] in `apply_migration`). Cheap: opened
    /// once per pool, not per request.
    pub(super) mount: DatabaseMount,
}

impl PostgresPool {
    /// The RLS principal applied via `app.current_user_id`.
    pub(super) fn principal(identity: &RequestIdentity) -> &str {
        identity.owner_principal()
    }

    /// Defense-in-depth tenant cross-check: the dispatcher (`routes::
    /// validate_identity_mount`) should already have rejected a tenant/mount
    /// mismatch, but the pool re-asserts it so a mis-keyed pool can never serve
    /// a request for the wrong tenant. Matches mysql/mongo/redis/http.
    pub(super) fn check_tenant(&self, identity: &RequestIdentity) -> DataPlaneResult<()> {
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
