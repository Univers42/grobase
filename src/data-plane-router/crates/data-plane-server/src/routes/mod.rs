//! HTTP surface of the data-plane router, split per resource.
//!
//! `routes::router` (re-exported below) is the single public entry point —
//! unchanged path + signature. Each submodule owns one resource; the shared
//! `AppState` (its fields `pub(super)`) and the cross-cutting `helpers` are
//! visible only within this module tree, so the crate-facing surface stays the
//! small facade re-exported at the bottom.

mod admin;
mod bypass;
mod bypass_auth;
mod health;
mod helpers;
mod metrics_text;
mod permissions;
mod query;
mod query_emit;
mod query_guards;
mod schema;
mod state;
mod state_build;
mod state_ops;
mod transactions;
mod txregistry;

// ── crate-facing facade ──────────────────────────────────────────────────────
// External callers reach these as `crate::routes::X` exactly as before the split
// (graph.rs, nano.rs, one*.rs, server.rs). Nothing wider than what was already
// `pub`/`pub(crate)` is re-exported.
pub use state::AppState;
// Always-present facade: used by the (ungated) graph module.
pub(crate) use bypass::{bypass_ratelimit, bypass_verify, require_scope, scope_denied};
pub(crate) use helpers::api_err;
// Nano-edition facade: `crate::routes::{…}` paths used only by the
// `#[cfg(feature = "nano")]` nano/one routers — gated to match, so they don't
// read as unused on the default (non-nano) build.
#[cfg(feature = "nano")]
pub(crate) use bypass::{bypass_envelope, data_apply_schema_ddl, data_describe_schema, data_query};
#[cfg(feature = "nano")]
pub(crate) use health::{capabilities, health};
#[cfg(feature = "nano")]
pub(crate) use helpers::map_data_plane_error;

use axum::{
    routing::{get, post},
    Router,
};
use tower_http::{cors::CorsLayer, trace::TraceLayer};

/// CORS for the data plane. It sits BEHIND Kong (server-to-server requests carry
/// no `Origin`), so browser cross-origin access is DENIED by default — replacing
/// the previous `permissive()` (any origin), audit item O3. Set
/// `DATA_PLANE_CORS_ALLOW_ORIGINS` (comma-separated) to allow specific origins
/// if the router is ever exposed to a browser directly.
fn cors_layer() -> CorsLayer {
    match std::env::var("DATA_PLANE_CORS_ALLOW_ORIGINS")
        .ok()
        .filter(|s| !s.trim().is_empty())
    {
        Some(spec) => {
            let origins: Vec<axum::http::HeaderValue> = spec
                .split(',')
                .filter_map(|o| o.trim().parse().ok())
                .collect();
            CorsLayer::new()
                .allow_origin(tower_http::cors::AllowOrigin::list(origins))
                .allow_methods(tower_http::cors::Any)
                .allow_headers(tower_http::cors::Any)
        }
        None => CorsLayer::new(),
    }
}

pub fn router(state: AppState) -> Router {
    let metrics_state = state.clone();
    // Phase 7: the direct front door is additive AND opt-in. It only exists when
    // DATA_PLANE_BYPASS_ENABLED=1; the internal /v1/query (query-router path) is
    // always present, so this is pure shadow until parity is proven + cut over.
    let bypass = if state.config.bypass_enabled {
        tracing::info!("Phase 7 bypass ENABLED: POST /data/v1/{{query,schema,schema/ddl}} (Rust-native API-key auth)");
        Router::new()
            .route("/data/v1/query", post(bypass::data_query))
            .route("/data/v1/schema", post(bypass::data_describe_schema))
            .route("/data/v1/schema/ddl", post(bypass::data_apply_schema_ddl))
            .route("/data/v1/graph", post(crate::graph::data_graph))
            .route("/data/v1/graph/overview", post(crate::graph::data_graph_overview))
    } else {
        Router::new()
    };
    Router::new()
        .route("/v1/health", get(health::health))
        .route("/metrics", get(health::metrics_handler))
        .route("/v1/capabilities", get(health::capabilities))
        .route("/v1/query", post(query::execute_query))
        .merge(bypass)
        .route("/v1/schema", post(schema::describe_schema))
        .route("/v1/schema/ddl", post(schema::apply_schema_ddl))
        .route("/v1/transactions", post(transactions::begin_transaction))
        .route("/v1/transactions/:tx_id/execute", post(transactions::execute_in_transaction))
        .route("/v1/transactions/:tx_id/commit", post(transactions::commit_transaction))
        .route("/v1/transactions/:tx_id/rollback", post(transactions::rollback_transaction))
        .route("/v1/admin/raw", post(admin::execute_raw_admin))
        .route("/v1/admin/migrate", post(admin::apply_migration_admin))
        .route("/v1/admin/rotate", post(admin::rotate_credential_admin))
        .route("/v1/admin/evict-verify", post(admin::evict_verify_admin))
        .route("/v1/permissions/decide", post(permissions::decide_permission))
        .fallback(helpers::not_found)
        .layer(axum::middleware::from_fn_with_state(metrics_state, health::track_metrics))
        .layer(TraceLayer::new_for_http())
        .layer(cors_layer())
        .with_state(state)
}

#[cfg(test)]
mod tests {
    use super::helpers::map_data_plane_error;
    use super::state::{AppState, TransactionRegistry};
    use crate::config::ServerConfig;
    use axum::http::StatusCode;
    use data_plane_core::{DataOperation, DataPlaneError, DataResult, TxHandle};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    fn status_of(err: DataPlaneError) -> StatusCode {
        map_data_plane_error(&err).status()
    }

    /// Minimal `TxHandle` that records how many times `rollback()` fired, so the
    /// reaper test can prove an expired tx is rolled back (not just dropped).
    struct CountingTxHandle {
        tx_id: String,
        mount_id: String,
        rolled_back: Arc<AtomicUsize>,
    }

    #[async_trait::async_trait]
    impl TxHandle for CountingTxHandle {
        fn tx_id(&self) -> &str {
            &self.tx_id
        }
        fn mount_id(&self) -> &str {
            &self.mount_id
        }
        async fn execute(
            &self,
            _op: DataOperation,
            _identity: data_plane_core::RequestIdentity,
        ) -> Result<DataResult, DataPlaneError> {
            Ok(DataResult { rows: vec![], affected_rows: 0, next_cursor: None, batch: None })
        }
        async fn commit(&self) -> Result<(), DataPlaneError> {
            Ok(())
        }
        async fn rollback(&self) -> Result<(), DataPlaneError> {
            self.rolled_back.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
        async fn prepare(&self) -> Result<(), DataPlaneError> {
            Ok(())
        }
    }

    fn counting_handle(tx_id: &str, rolled_back: Arc<AtomicUsize>) -> Arc<dyn TxHandle> {
        Arc::new(CountingTxHandle {
            tx_id: tx_id.to_string(),
            mount_id: "db1".to_string(),
            rolled_back,
        })
    }

    #[tokio::test]
    async fn reap_expired_rolls_back_and_yields_pool_key() {
        // An abandoned (begun-but-never-finalised) tx past its TTL must be reaped:
        // removed from the registry, rolled back, and its pool_key surfaced so the
        // caller can unpin the pool (otherwise the pin leaks forever).
        let reg = TransactionRegistry::default();
        let rolled_back = Arc::new(AtomicUsize::new(0));
        // Register with a zero TTL → already expired.
        let tx_id = reg
            .register(
                counting_handle("tx-expired", rolled_back.clone()),
                "t-1".into(),
                "db1".into(),
                "pool-key-1".into(),
                Duration::from_secs(0),
            )
            .await;

        // `get` must already refuse it (contract: stop handing out an expired tx).
        assert!(reg.get(&tx_id).await.is_none(), "expired tx is not handed out by get");

        let reaped = reg.reap_expired().await;
        assert_eq!(reaped.len(), 1, "the one expired tx is reaped");
        let (handle, pool_key) = &reaped[0];
        assert_eq!(pool_key, "pool-key-1", "pool_key surfaced for unpin");
        let _ = handle.rollback().await; // simulate AppState::reap_once
        assert_eq!(rolled_back.load(Ordering::SeqCst), 1, "expired tx rolled back");

        // Idempotent: a second pass finds nothing (entry already removed).
        assert!(reg.reap_expired().await.is_empty(), "reap is idempotent");
    }

    #[tokio::test]
    async fn reap_expired_keeps_live_transactions() {
        let reg = TransactionRegistry::default();
        let rolled_back = Arc::new(AtomicUsize::new(0));
        let tx_id = reg
            .register(
                counting_handle("tx-live", rolled_back.clone()),
                "t-1".into(),
                "db1".into(),
                "pool-key-1".into(),
                Duration::from_secs(3600), // far in the future
            )
            .await;
        assert!(reg.reap_expired().await.is_empty(), "live tx not reaped");
        assert!(reg.get(&tx_id).await.is_some(), "live tx still served by get");
        assert_eq!(rolled_back.load(Ordering::SeqCst), 0, "live tx not rolled back");
    }

    #[test]
    fn error_variants_map_to_expected_http_status() {
        // Request-shape mistakes are client errors (400), distinct from a
        // backend/transport failure (502). This is the contract the Postgres
        // and the other adapters now rely on.
        assert_eq!(
            status_of(DataPlaneError::InvalidRequest { message: "bad shape".into() }),
            StatusCode::BAD_REQUEST,
        );
        assert_eq!(
            status_of(DataPlaneError::InvalidIdentifier { value: "x;--".into() }),
            StatusCode::BAD_REQUEST,
        );
        // G6: an unavailable capability is a semantic (not syntactic) rejection
        // → 422, distinct from a malformed request (400) above.
        assert_eq!(
            status_of(DataPlaneError::UnsupportedCapability {
                engine: "redis".into(),
                capability: "stream".into(),
            }),
            StatusCode::UNPROCESSABLE_ENTITY,
        );
        assert_eq!(
            status_of(DataPlaneError::Backend { message: "engine down".into() }),
            StatusCode::BAD_GATEWAY,
        );
        assert_eq!(
            status_of(DataPlaneError::NotImplemented { feature: "agg".into() }),
            StatusCode::NOT_IMPLEMENTED,
        );
        // An integrity-constraint violation is the caller's fault (409), not a
        // backend failure (502).
        assert_eq!(
            status_of(DataPlaneError::Conflict { message: "duplicate key".into() }),
            StatusCode::CONFLICT,
        );
        // gap G8: an unresolvable credential and a failed provider are both
        // upstream/gateway failures (502), distinct from a 422 client error.
        assert_eq!(
            status_of(DataPlaneError::CredentialUnavailable { mount_id: "m1".into() }),
            StatusCode::BAD_GATEWAY,
        );
        assert_eq!(
            status_of(DataPlaneError::CredentialProviderFailed {
                provider: "vault".into(),
                mount_id: "m1".into(),
            }),
            StatusCode::BAD_GATEWAY,
        );
    }

    // S2 — the rotation entrypoint composes BOTH halves (resolver cache evict +
    // registry pool drain) and is safe on an empty state: an unknown key drains
    // zero pools and never panics. The deep behaviour of each half is proven in
    // the pool crate (resolver `s2_evict_cached_*` + registry `t9`/`t10`); this
    // test locks that `AppState::rotate` actually invokes both without error,
    // using a freshly-built state (no pools created → 0 drained).
    #[tokio::test]
    async fn s2_rotate_entrypoint_drains_and_evicts_safely() {
        // Build with the cache armed so the evict half exercises its real path
        // (ttl > 0) rather than the disabled no-op.
        std::env::set_var("DATA_PLANE_CREDENTIAL_CACHE_TTL_MS", "60000");
        let state = AppState::new(ServerConfig::from_env());
        std::env::remove_var("DATA_PLANE_CREDENTIAL_CACHE_TTL_MS");
        // No pool was ever created → rotating any key drains zero pools, and the
        // resolver-cache evict is a no-op-but-reached. Proves the composition is
        // wired and panic-free; concrete drain/evict behaviour is covered by the
        // pool-crate tests.
        let drained = state.rotate("t-1/default/db1/postgresql/1").await;
        assert_eq!(drained, 0, "no pool exists yet → zero drained");
        // Idempotent: a second rotate of the same key is still a clean no-op.
        assert_eq!(state.rotate("t-1/default/db1/postgresql/1").await, 0);
    }
}
