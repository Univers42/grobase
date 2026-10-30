/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   adapter.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:28:14 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The HTTP [`EngineAdapter`]: parses the mount connection, runs the SSRF guard
//! while opening a pinned `reqwest::Client`, and advertises capabilities.

use super::pool::HttpPool;
use super::redirect::build_client;
use super::validate::{guard_and_resolve, parse_connection};
use super::SUPPORTED_OPS;
use crate::resolver::MountResolver;
use async_trait::async_trait;
use data_plane_core::{
    DataOperationKind, DataPlaneResult, DatabaseMount, EngineAdapter, EngineCapabilities,
    EngineHealth, EnginePool,
};
use std::sync::Arc;

pub struct HttpEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl HttpEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

#[async_trait]
impl EngineAdapter for HttpEngineAdapter {
    fn engine(&self) -> &str {
        "http"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::http()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        let conn = parse_connection(&dsn)?;
        // SSRF guard: resolve + validate the base-URL host, reject internal /
        // link-local / cloud-metadata targets, and PIN the client to the
        // validated public IP(s) so a later DNS rebind can't redirect requests
        // inward. `DATA_PLANE_HTTP_ALLOW_INTERNAL=1` skips it (trusted dev mocks).
        let pinned = guard_and_resolve(&conn.base_url).await?;
        let client = build_client(&conn.base_url, pinned)?;
        let shared_pool = crate::pools_shared(&mount);
        Ok(Box::new(HttpPool {
            mount_id: mount.id,
            tenant_id: mount.tenant_id,
            shared_pool,
            client,
            conn,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth::unknown("http", pool.mount_id()))
    }
}
