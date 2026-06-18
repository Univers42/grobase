//! `AppState` construction helpers, split out of `state.rs` so the constructor
//! reads as a short orchestration of named builders rather than one 150-line
//! function. Each builder owns one concern (resolver, adapter registry, ABAC
//! evaluator, honor-set refreshers); the behaviour is identical to the inlined
//! body — same env reads, same cfg-gated adapter set, same flag-gated `Some`/
//! `None` refreshers.
use crate::abac::{Evaluator, PermissionMode, PolicyBundle};
use crate::config::ServerConfig;
use data_plane_core::EngineAdapter;
#[cfg(feature = "dynamodb")]
use data_plane_pool::DynamoEngineAdapter;
#[cfg(feature = "http")]
use data_plane_pool::HttpEngineAdapter;
#[cfg(feature = "mongodb")]
use data_plane_pool::MongoEngineAdapter;
#[cfg(feature = "mssql")]
use data_plane_pool::MssqlEngineAdapter;
#[cfg(feature = "mysql")]
use data_plane_pool::MysqlEngineAdapter;
#[cfg(feature = "redis")]
use data_plane_pool::RedisEngineAdapter;
#[cfg(feature = "sqlite")]
use data_plane_pool::SqliteEngineAdapter;
use data_plane_pool::{EnvMountResolver, ProviderConfig};
#[cfg(feature = "postgres")]
use data_plane_pool::{PgDialect, PostgresEngineAdapter};
use std::sync::Arc;

/// The three Track-B honor-set Redis refreshers, each `Some` only when its own
/// flag is ON (OFF → `None` → no Redis traffic = byte-parity). Returned as a
/// bundle so the constructor binds them in one move.
pub(super) struct HonorRefreshers {
    pub(super) quota: Option<Arc<crate::quota::QuotaRefresher>>,
    pub(super) spend: Option<Arc<crate::quota::QuotaRefresher>>,
    pub(super) suspend: Option<Arc<crate::quota::QuotaRefresher>>,
}

/// gap G8: build the DSN resolver from `ServerConfig` (the single env-reader), so
/// credential providers + the DSN cache are configured from ONE source. All
/// provider knobs default empty → providers DISABLED, so this is parity-
/// equivalent to the old `from_env()` until a token/addr is set.
pub(super) fn build_resolver(config: &ServerConfig) -> Arc<EnvMountResolver> {
    let mounts_json = std::env::var("DATA_PLANE_MOUNTS").unwrap_or_default();
    let provider_cfg = ProviderConfig {
        adapter_registry_url: config.adapter_registry_url.clone(),
        adapter_registry_token: config.adapter_registry_token.clone(),
        vault_addr: config.vault_addr.clone(),
        vault_token: config.vault_token.clone(),
        vault_dsn_prefix: config.vault_dsn_prefix.clone(),
        vault_dsn_field: config.vault_dsn_field.clone(),
    };
    Arc::new(EnvMountResolver::from_config(
        &mounts_json,
        &provider_cfg,
        config.credential_cache_ttl_ms,
    ))
}

/// Strategy pattern: one `Arc<dyn EngineAdapter>` per engine, all behind the same
/// `PoolRegistry` trait. Feature-gated registration — a lean build (nano)
/// compiles + registers only the engines it mounts; the default build registers
/// all nine. Runs the boot-time honesty self-check before returning.
// ponytail: irreducible adapter registry — one cfg-gated push per engine adapter
pub(super) fn build_adapters(resolver: &Arc<EnvMountResolver>) -> Vec<Arc<dyn EngineAdapter>> {
    #[allow(unused_mut)]
    let mut adapters: Vec<Arc<dyn EngineAdapter>> = Vec::new();
    #[cfg(feature = "postgres")]
    {
        adapters.push(Arc::new(PostgresEngineAdapter::new(resolver.clone())));
        // CockroachDB rides the Postgres adapter (pgwire) under its own
        // engine id with a serializable-only descriptor.
        adapters.push(Arc::new(PostgresEngineAdapter::with_dialect(
            resolver.clone(),
            PgDialect::Cockroach,
        )));
    }
    #[cfg(feature = "mongodb")]
    adapters.push(Arc::new(MongoEngineAdapter::new(resolver.clone())));
    #[cfg(feature = "mysql")]
    {
        adapters.push(Arc::new(MysqlEngineAdapter::new(resolver.clone())));
        // MariaDB rides the MySQL adapter (same wire protocol + dispatch)
        // under its own engine id.
        adapters.push(Arc::new(MysqlEngineAdapter::with_engine_name(
            resolver.clone(),
            "mariadb",
        )));
    }
    #[cfg(feature = "redis")]
    adapters.push(Arc::new(RedisEngineAdapter::new(resolver.clone())));
    // 8th adapter (OFF by default): DynamoDB-compatible engine (AWS DynamoDB
    // / DynamoDB-Local / ScyllaDB Alternator). cfg-gated so the default
    // adapter set is byte-identical to today.
    #[cfg(feature = "dynamodb")]
    adapters.push(Arc::new(DynamoEngineAdapter::new(resolver.clone())));
    #[cfg(feature = "sqlite")]
    adapters.push(Arc::new(SqliteEngineAdapter::new(resolver.clone())));
    #[cfg(feature = "mssql")]
    adapters.push(Arc::new(MssqlEngineAdapter::new(resolver.clone())));
    #[cfg(feature = "http")]
    adapters.push(Arc::new(HttpEngineAdapter::new(resolver.clone())));
    // Boot-time honesty self-check (04/S1b): fail fast if any descriptor
    // advertises an op the adapter doesn't dispatch.
    assert_capability_honesty(&adapters);
    adapters
}

/// Track-B honor sets (B2 quota + spend-cap + suspend): build each Redis
/// refresher ONLY when its own flag is ON (reusing the shared quota Redis URL —
/// all three sets live in one control-plane Redis). OFF → `None` → no snapshot
/// work, no Redis traffic (byte-parity).
pub(super) fn build_honor_refreshers(config: &ServerConfig) -> HonorRefreshers {
    let quota = if config.quota_enforcement {
        Some(Arc::new(crate::quota::QuotaRefresher::new(
            config.quota_redis_url.clone(),
        )))
    } else {
        None
    };
    let spend = if config.spend_caps {
        Some(Arc::new(crate::quota::QuotaRefresher::new_for(
            config.quota_redis_url.clone(),
            crate::quota::SPEND_OVER_SET,
        )))
    } else {
        None
    };
    let suspend = if config.suspend_reader {
        Some(Arc::new(crate::quota::QuotaRefresher::new_for(
            config.quota_redis_url.clone(),
            crate::quota::SUSPENDED_SET,
        )))
    } else {
        None
    };
    HonorRefreshers {
        quota,
        spend,
        suspend,
    }
}

/// Boot-time capability self-check (04/S1b). Every adapter's advertised
/// descriptor must agree with the operations it actually dispatches
/// (`supported_ops`), so we fail fast at startup rather than serve a lying
/// `/v1/capabilities`. Both sides are compile-time constants, so a mismatch is a
/// programming error, never runtime-triggerable. The same invariant is gated in
/// CI by `make verify-m18` (the `capability_honesty` tests).
fn assert_capability_honesty(adapters: &[Arc<dyn EngineAdapter>]) {
    for adapter in adapters {
        let caps = adapter.capabilities();
        let ops = adapter.supported_ops();
        for kind in &data_plane_core::DataOperationKind::ALL {
            assert_eq!(
                caps.supports_op(kind),
                ops.contains(kind),
                "capability descriptor for engine '{}' lies about {:?}: supports_op={} but dispatch supported_ops={}",
                adapter.engine(),
                kind,
                caps.supports_op(kind),
                ops.contains(kind),
            );
        }
    }
}

/// Optional in-Rust ABAC evaluator. `Some` when `DATA_PLANE_PERMISSION_BUNDLE`
/// holds a valid `PolicyBundle`; otherwise `None` and `/v1/permissions/decide`
/// returns 503 so callers fall back to the permission-engine HTTP path.
pub(super) fn build_evaluator(config: &ServerConfig) -> Option<Arc<Evaluator>> {
    let raw = config.permission_bundle_inline.trim();
    if raw.is_empty() {
        return None;
    }
    let bundle: PolicyBundle = match serde_json::from_str(raw) {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!(
                "DATA_PLANE_PERMISSION_BUNDLE is not valid PolicyBundle JSON ({}); local evaluator disabled",
                e
            );
            return None;
        }
    };
    let mode = PermissionMode::from_env_string(&config.permission_mode);
    Some(Arc::new(Evaluator::new(bundle, mode)))
}
