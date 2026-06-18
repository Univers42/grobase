//! The Redis [`EngineAdapter`]: opens a per-mount auto-reconnecting pool and
//! advertises the engine's capabilities + supported operation set.

use super::convert::resolve_namespace;
use super::pool::RedisPool;
use super::SUPPORTED_OPS;
use crate::resolver::MountResolver;
use async_trait::async_trait;
use data_plane_core::{
    DataOperationKind, DataPlaneError, DataPlaneResult, DatabaseMount, EngineAdapter,
    EngineCapabilities, EngineHealth, EnginePool,
};
use redis::aio::ConnectionManager;
use redis::Client;
use std::sync::Arc;

pub struct RedisEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl RedisEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

#[async_trait]
impl EngineAdapter for RedisEngineAdapter {
    fn engine(&self) -> &str {
        "redis"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::redis()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        // Phase B: refuse the redis `rediss://…#insecure` cert-skip under max.
        crate::tls::reject_insecure_tls(&dsn, crate::tls::max_security(), &["#insecure"])?;
        let client = Client::open(dsn.as_str()).map_err(|e| DataPlaneError::Backend {
            message: format!("invalid redis URL: {e}"),
        })?;
        let manager =
            ConnectionManager::new(client)
                .await
                .map_err(|e| DataPlaneError::Backend {
                    message: format!("redis connection manager init failed: {e}"),
                })?;
        // schema_per_tenant: a per-tenant namespace segment prepended to every
        // key (`<namespace>:<owner>:<resource>:<id>`). Derived from the mount's
        // tenant_id (identity-independent) so resolved once here; `None` for
        // shared_rls / db_per_tenant → the historical `<owner>:<resource>:<id>`
        // envelope, byte-identical to before G5.
        let namespace = resolve_namespace(&mount);
        let shared_pool = crate::pools_shared(&mount);
        Ok(Box::new(RedisPool {
            mount_id: mount.id,
            tenant_id: mount.tenant_id,
            shared_pool,
            manager,
            namespace,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth::unknown("redis", pool.mount_id()))
    }
}
