/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   adapter.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:29:33 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:29:35 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The Redis [`EngineAdapter`]: opens a per-mount auto-reconnecting pool and
//! advertises the engine's capabilities + supported operation set.

use super::convert::resolve_namespace;
use super::dial::DialManager;
use super::pool::RedisPool;
use super::SUPPORTED_OPS;
use crate::dial_guard::scope::DialScope;
use crate::dial_guard::DialGuardMode;
use crate::resolver::MountResolver;
use async_trait::async_trait;
use data_plane_core::{
    DataOperationKind, DataPlaneResult, DatabaseMount, EngineAdapter, EngineCapabilities,
    EngineHealth, EnginePool, TlsPosture,
};
use redis::{ConnectionAddr, IntoConnectionInfo};
use std::sync::Arc;

pub struct RedisEngineAdapter {
    resolver: Arc<dyn MountResolver>,
    dial_guard: DialGuardMode,
}

impl RedisEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self {
            resolver,
            dial_guard: DialGuardMode::Off,
        }
    }

    /// G2 (ADR 0019): guard every Tenant dial; `Off` (the default) changes nothing.
    #[must_use]
    pub fn with_dial_guard(mut self, mode: DialGuardMode) -> Self {
        self.dial_guard = mode;
        self
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
        let resolved = self.resolver.resolve(&mount).await?;
        // G2: Off or a Platform DSN → no scope, the manager is built as before.
        let scope = DialScope::for_mount(self.dial_guard, "redis", &mount, resolved.provenance);
        let manager = DialManager::open(&resolved.dsn, scope).await?;
        // schema_per_tenant: a per-tenant namespace segment prepended to every
        // key (`<namespace>:<owner>:<resource>:<id>`). Derived from the mount's
        // tenant_id (identity-independent) so resolved once here; `None` for
        // shared_rls / db_per_tenant → the historical `<owner>:<resource>:<id>`
        // envelope, byte-identical to before G5.
        let namespace = resolve_namespace(&mount);
        let shared_pool = crate::pools_shared(&mount);
        let tls = tls_posture(&resolved.dsn);
        Ok(Box::new(RedisPool {
            mount_id: mount.id,
            tenant_id: mount.tenant_id,
            shared_pool,
            manager,
            namespace,
            tls,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth::unknown("redis", pool.mount_id()))
    }
}

/// `Verified` for `rediss://`: `#insecure` never reaches a dial (`redis_client`), so
/// a TLS pool that opened checked the certificate. The probe reports it.
fn tls_posture(dsn: &str) -> TlsPosture {
    match dsn.into_connection_info().map(|info| info.addr) {
        Ok(ConnectionAddr::TcpTls { .. }) => TlsPosture::Verified,
        _ => TlsPosture::Plaintext,
    }
}
