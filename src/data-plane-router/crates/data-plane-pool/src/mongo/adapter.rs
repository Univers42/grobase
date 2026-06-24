/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   adapter.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:27:49 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:27:50 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The [`MongoEngineAdapter`] (GoF Adapter): builds a mount-scoped
//! [`super::pool::MongoPool`] from a [`DatabaseMount`], caching one
//! `mongodb::Client` (itself a connection pool) per mount.

use async_trait::async_trait;
use data_plane_core::{
    DataOperationKind, DataPlaneError, DataPlaneResult, DatabaseMount, EngineAdapter,
    EngineCapabilities, EngineHealth, EnginePool,
};
use mongodb::{options::ClientOptions, Client};
use std::{sync::Arc, time::Duration};

use crate::resolver::MountResolver;

use super::pool::MongoPool;

/// Adapter that knows how to construct [`MongoPool`] instances from a
/// [`DatabaseMount`]. Held as `Arc<dyn EngineAdapter>` inside the registry.
pub struct MongoEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl MongoEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

#[async_trait]
impl EngineAdapter for MongoEngineAdapter {
    fn engine(&self) -> &str {
        "mongodb"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::mongodb()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        super::SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        // tenant_owned (no per-row owner scoping) is implemented for
        // PostgreSQL only so far — fail CLOSED here rather than silently
        // owner-scoping a mount that promised not to (wrong rows beat
        // surprising rows, but a clear error beats both).
        if !mount.isolation().owner_scoped() {
            return Err(DataPlaneError::NotImplemented {
                feature: "tenant_owned isolation on this engine (PostgreSQL only for now)"
                    .to_string(),
            });
        }
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        // Phase B: under SECURITY_MODE=max, refuse a DSN that disables TLS
        // verification (the mongodb driver verifies by default otherwise).
        crate::tls::reject_insecure_tls(
            &dsn,
            crate::tls::max_security(),
            &[
                "tlsinsecure=true",
                "tlsallowinvalidcertificates=true",
                "tlsallowinvalidhostnames=true",
            ],
        )?;
        let mut options =
            ClientOptions::parse(&dsn)
                .await
                .map_err(|e| DataPlaneError::Backend {
                    message: format!("invalid mongo URI: {e}"),
                })?;
        // Bound concurrent connections per mount via pool policy; the
        // driver already enforces this efficiently.
        options.max_pool_size = Some(mount.pool_policy.max);
        options.min_pool_size = Some(mount.pool_policy.min);
        options.server_selection_timeout = Some(Duration::from_millis(
            mount.pool_policy.idle_ttl_ms.max(5_000),
        ));
        options.app_name = Some(format!("mini-baas/{}", mount.id));

        let client = Client::with_options(options).map_err(|e| DataPlaneError::Backend {
            message: format!("mongo client init failed: {e}"),
        })?;

        // Database name resolution mirrors the TypeScript adapter: take the
        // URI path component, fall back to "test" so misconfigured mounts
        // surface a backend error, not a panic.
        //
        // schema_per_tenant: the engine-neutral scope directive selects a
        // per-tenant database (`tenant_<id>`) instead of the DSN-default db.
        // The namespace is derived from the mount's tenant_id (identity-
        // independent), so it's stable for the pool's lifetime and resolved
        // once here. For shared_rls / db_per_tenant the directive is `None` →
        // the DSN-default db, byte-identical to before G5.
        let db_name = resolve_namespace(&mount).unwrap_or_else(|| parse_db_name(&dsn));
        let shared_pool = crate::pools_shared(&mount);
        let shared_resources: std::sync::Arc<[String]> = if per_table_isolation_enabled() {
            mount.shared_resources().into()
        } else {
            Vec::<String>::new().into()
        };

        Ok(Box::new(MongoPool {
            mount_id: mount.id.clone(),
            tenant_id: mount.tenant_id.clone(),
            shared_pool,
            client,
            db_name,
            shared_resources,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth::unknown("mongodb", pool.mount_id()))
    }
}

/// Per-tenant database name for a `schema_per_tenant` Mongo mount — delegates to
/// the single source of truth, [`DatabaseMount::resolve_namespace`].
// ponytail: thin wrapper kept so call sites read `resolve_namespace(&mount)`;
// inline + delete in a follow-up.
fn resolve_namespace(mount: &DatabaseMount) -> Option<String> {
    mount.resolve_namespace()
}

/// F1 per-table isolation master flag (`DATA_PLANE_PER_TABLE_ISOLATION`). OFF by
/// default → `shared_resources` is forced empty so every read stays owner-scoped
/// (byte-parity). Mirrors the Postgres/MySQL adapters' identical gate.
fn per_table_isolation_enabled() -> bool {
    matches!(
        std::env::var("DATA_PLANE_PER_TABLE_ISOLATION").as_deref(),
        Ok("1" | "true" | "TRUE" | "on" | "ON" | "yes")
    )
}

fn parse_db_name(dsn: &str) -> String {
    // Strict-enough URI parsing: split off the path component after the host.
    if let Some(after_scheme) = dsn.split("://").nth(1) {
        if let Some((_, after_host)) = after_scheme.split_once('/') {
            let name = after_host.split('?').next().unwrap_or("");
            if !name.is_empty() {
                return name.to_string();
            }
        }
    }
    "test".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── parse_db_name: DSN → database name, with default ──────────────────────

    #[test]
    fn parse_db_name_extracts_path_or_defaults_to_test() {
        assert_eq!(parse_db_name("mongodb://host:27017/mydb"), "mydb");
        assert_eq!(
            parse_db_name("mongodb://u:p@host/appdb?retryWrites=true"),
            "appdb"
        );
        assert_eq!(parse_db_name("mongodb+srv://host/prod"), "prod");
        // no path → default "test".
        assert_eq!(parse_db_name("mongodb://host:27017"), "test");
        assert_eq!(parse_db_name("mongodb://host/"), "test");
        assert_eq!(parse_db_name("garbage"), "test");
    }
}
