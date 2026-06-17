//! The [`SqliteEngineAdapter`] (GoF Adapter): opens a `deadpool-sqlite` pool
//! for the mount's file, sets the WAL pragmas once, and spawns the dedicated
//! GROUP-COMMIT writer thread ([`super::writer::writer_loop`]).

use async_trait::async_trait;
use data_plane_core::{
    DataOperationKind, DataPlaneError, DataPlaneResult, DatabaseMount, EngineAdapter,
    EngineCapabilities, EngineHealth, EnginePool,
};
use deadpool_sqlite::{Config as SqliteConfig, Runtime};
use std::sync::Arc;

use crate::resolver::MountResolver;

use super::error::backend;
use super::pool::SqlitePool;
use super::writer::writer_loop;

pub struct SqliteEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl SqliteEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

#[async_trait]
impl EngineAdapter for SqliteEngineAdapter {
    fn engine(&self) -> &str {
        "sqlite"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::sqlite()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        super::SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        let path = sqlite_path(&dsn);
        let cfg = SqliteConfig::new(path.clone());
        let pool = cfg
            .create_pool(Runtime::Tokio1)
            .map_err(|e| DataPlaneError::Backend {
                message: format!("sqlite pool create failed: {e}"),
            })?;

        // Enable WAL + a busy timeout once (WAL persists in the file; the timeout
        // is per-connection but harmless to set here on the first checkout).
        let obj = pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("sqlite checkout failed: {e}"),
        })?;
        obj.interact(|conn| {
            conn.pragma_update(None, "journal_mode", "WAL")?;
            // The standard WAL pairing (and what PocketBase ships): NORMAL
            // skips the per-commit fsync that FULL forces — the database can
            // never corrupt, at worst the last commits roll back on an OS
            // crash. Default FULL made every insert pay a ~10 ms fsync,
            // 2-3x slower than PocketBase on the same disk.
            conn.pragma_update(None, "synchronous", "NORMAL")?;
            conn.pragma_update(None, "busy_timeout", 5000)?;
            conn.pragma_update(None, "foreign_keys", "ON")
        })
        .await
        .map_err(|e| DataPlaneError::Backend {
            message: format!("sqlite pragma setup failed: {e}"),
        })?
        .map_err(backend)?;

        // Dedicated writer thread (single-writer + GROUP COMMIT): one OS
        // thread owns one connection and drains queued writes in batches of
        // up to GROUP_MAX per transaction — one commit (and one checkpoint
        // share) amortized across the whole group. Reads stay on the pool
        // (WAL = N parallel readers).
        let (writer, jobs) = tokio::sync::mpsc::unbounded_channel();
        let writer_path = path.clone();
        std::thread::Builder::new()
            .name(format!("sqlite-writer-{}", mount.id))
            .spawn(move || writer_loop(&writer_path, jobs))
            .map_err(|e| DataPlaneError::Backend {
                message: format!("sqlite writer thread spawn failed: {e}"),
            })?;

        Ok(Box::new(SqlitePool {
            mount_id: mount.id.clone(),
            tenant_id: mount.tenant_id.clone(),
            owner_scoped: mount.isolation().owner_scoped(),
            shared_pool: crate::pools_shared(&mount),
            pool,
            writer,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth::unknown("sqlite", pool.mount_id()))
    }
}

/// Parse a `sqlite:` DSN to a file path (or `:memory:`).
fn sqlite_path(dsn: &str) -> String {
    let s = dsn
        .strip_prefix("sqlite://")
        .or_else(|| dsn.strip_prefix("sqlite:"))
        .unwrap_or(dsn);
    if s.is_empty() || s == ":memory:" {
        ":memory:".to_string()
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dsn_parsing() {
        assert_eq!(sqlite_path("sqlite:///var/lib/x.db"), "/var/lib/x.db");
        assert_eq!(sqlite_path("sqlite::memory:"), ":memory:");
        assert_eq!(sqlite_path("sqlite://"), ":memory:");
        assert_eq!(sqlite_path("/abs/path.db"), "/abs/path.db");
    }

    // ── DSN parsing edge cases ───────────────────────────────────────────────

    #[test]
    fn dsn_parsing_edge_cases() {
        assert_eq!(sqlite_path("sqlite:"), ":memory:");
        assert_eq!(
            sqlite_path("sqlite://relative/db.sqlite"),
            "relative/db.sqlite"
        );
        assert_eq!(sqlite_path(""), ":memory:");
        assert_eq!(sqlite_path(":memory:"), ":memory:");
        assert_eq!(sqlite_path("sqlite:///tmp/a b.db"), "/tmp/a b.db");
    }
}
