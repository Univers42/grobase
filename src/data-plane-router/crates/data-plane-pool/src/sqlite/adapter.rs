/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   adapter.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:29:51 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:29:52 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The [`SqliteEngineAdapter`] (GoF Adapter): opens a `deadpool-sqlite` pool
//! for the mount's file, tunes and hardens every connection it creates
//! ([`super::harden`]), and spawns the dedicated GROUP-COMMIT writer thread
//! ([`super::writer::writer_loop`]).

use async_trait::async_trait;
use data_plane_core::{
    DataOperationKind, DataPlaneError, DataPlaneResult, DatabaseMount, EngineAdapter,
    EngineCapabilities, EngineHealth, EnginePool,
};
use deadpool_sqlite::{Config as SqliteConfig, Hook, HookError, Pool, Runtime};
use std::sync::Arc;

use crate::resolver::MountResolver;

use super::harden::{harden, refuse_unsafe_path, tune};
use super::pool::SqlitePool;
use super::root::{sqlite_path, SqliteRoot};
use super::writer::{enable_wal, writer_loop};

pub struct SqliteEngineAdapter {
    resolver: Arc<dyn MountResolver>,
    root: SqliteRoot,
}

impl SqliteEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self {
            resolver,
            root: SqliteRoot::from_env(),
        }
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
        refuse_unsafe_path(&path)?;
        self.root.confine(&path, &mount.tenant_id)?;
        let writer_flags = self.root.writer_flags();
        enable_wal(&path, writer_flags).await?;
        let pool = reader_pool(&path)?;

        // Dedicated writer thread (single-writer + GROUP COMMIT): one OS
        // thread owns one connection and drains queued writes in batches of
        // up to GROUP_MAX per transaction — one commit (and one checkpoint
        // share) amortized across the whole group. Reads stay on the pool
        // (WAL = N parallel readers).
        let (writer, jobs) = tokio::sync::mpsc::unbounded_channel();
        let writer_path = path.clone();
        std::thread::Builder::new()
            .name(format!("sqlite-writer-{}", mount.id))
            .spawn(move || writer_loop(&writer_path, writer_flags, jobs))
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

/// The reader pool. `post_create` runs on EVERY connection deadpool opens, not
/// only the first checkout, so a second reader is as locked down as the first.
///
/// Caveat: deadpool-sqlite opens with `Connection::open(path)` and no flags,
/// so a reader follows a symlink swapped in at `path` after the root check; a
/// custom Manager is the way to pass `SQLITE_OPEN_NOFOLLOW` (the writer does).
fn reader_pool(path: &str) -> DataPlaneResult<Pool> {
    let failed = |e: String| DataPlaneError::Backend {
        message: format!("sqlite pool create failed: {e}"),
    };
    SqliteConfig::new(path)
        .builder(Runtime::Tokio1)
        .map_err(|e| failed(e.to_string()))?
        .post_create(Hook::async_fn(|conn, _| {
            Box::pin(async move {
                conn.interact(|conn| tune(conn).and_then(|()| harden(conn)))
                    .await
                    .map_err(|e| {
                        HookError::Message(format!("sqlite connection setup: {e}").into())
                    })?
                    .map_err(HookError::Backend)
            })
        }))
        .build()
        .map_err(|e| failed(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::resolver::EnvMountResolver;
    use data_plane_core::{
        CredentialRef, IdentitySource, PoolPolicy, RawStatement, RequestIdentity,
    };

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("g2-adapter-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn mount(dsn: &str) -> DatabaseMount {
        DatabaseMount {
            id: "m".into(),
            tenant_id: "t".into(),
            project_id: None,
            engine: "sqlite".into(),
            name: "m".into(),
            credential_ref: CredentialRef {
                provider: "inline".into(),
                reference: "-".into(),
                version: "1".into(),
            },
            pool_policy: PoolPolicy::default(),
            capability_overrides: None,
            inline_dsn: Some(dsn.into()),
            isolation: None,
            replica_inline_dsn: None,
            read_replica_route: false,
        }
    }

    fn adapter() -> SqliteEngineAdapter {
        SqliteEngineAdapter::new(Arc::new(EnvMountResolver::default()))
    }

    fn raw(sql: &str, expect_rows: bool) -> RawStatement {
        RawStatement {
            statement: sql.into(),
            params: vec![],
            expect_rows,
        }
    }

    fn identity() -> RequestIdentity {
        RequestIdentity {
            tenant_id: "t".into(),
            project_id: None,
            app_id: None,
            user_id: None,
            roles: vec![],
            scopes: vec![],
            source: IdentitySource::Test,
        }
    }

    #[tokio::test]
    async fn a_second_reader_connection_is_tuned_and_hardened_too() {
        let dir = scratch("readers");
        let pool = reader_pool(dir.join("m.db").to_str().unwrap()).unwrap();
        let first = pool.get().await.unwrap();
        let second = pool.get().await.unwrap();
        for conn in [&first, &second] {
            let (fk, attach) = conn
                .interact(|c| {
                    let fk: i64 = c
                        .query_row("PRAGMA foreign_keys", [], |r| r.get(0))
                        .unwrap();
                    (
                        fk,
                        c.execute_batch("ATTACH ':memory:' AS x")
                            .map_err(|e| e.to_string()),
                    )
                })
                .await
                .unwrap();
            assert_eq!(fk, 1);
            assert!(attach.unwrap_err().contains("not authorized"));
        }
        assert_eq!(
            pool.status().size,
            2,
            "the two checkouts were one connection"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn raw_attach_is_refused_on_the_read_and_the_write_path() {
        let dir = scratch("raw");
        let path = dir.join("m.db");
        let pool = adapter()
            .open_pool(mount(&format!("sqlite://{}", path.display())))
            .await
            .unwrap();
        let attach = format!("ATTACH '{}' AS other", dir.join("other.db").display());
        for expect_rows in [true, false] {
            let err = pool
                .execute_raw(raw(&attach, expect_rows), identity())
                .await
                .expect_err("ATTACH ran");
            assert!(err.to_string().contains("not authorized"), "{err}");
        }
        pool.execute_raw(raw("CREATE TABLE t (id INTEGER)", false), identity())
            .await
            .unwrap();
        let rows = pool
            .execute_raw(raw("SELECT name FROM sqlite_master", true), identity())
            .await
            .unwrap();
        assert_eq!(rows.rows.len(), 1);
        assert!(!dir.join("other.db").exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn a_fresh_file_survives_its_first_read_and_write_racing() {
        let dir = scratch("race");
        for i in 0..20 {
            let dsn = format!("sqlite://{}/m{i}.db", dir.display());
            let pool = adapter().open_pool(mount(&dsn)).await.unwrap();
            let (read, write) = tokio::join!(
                pool.execute_raw(raw("SELECT 1", true), identity()),
                pool.execute_raw(raw("CREATE TABLE t (id INTEGER)", false), identity()),
            );
            read.unwrap();
            write.unwrap();
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn an_unsafe_path_is_refused_before_any_file_is_created() {
        let dir = scratch("refused");
        for dsn in [
            format!("sqlite:file:{}/x.db?vfs=memdb", dir.display()),
            format!("sqlite://file:{}/y.db", dir.display()),
            format!("sqlite://{}/a?b.db", dir.display()),
            format!("sqlite://{}/nano_meta.db", dir.display()),
        ] {
            assert!(adapter().open_pool(mount(&dsn)).await.is_err(), "{dsn}");
        }
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn a_confined_adapter_opens_only_its_own_tenant_directory() {
        let dir = scratch("confined");
        let adapter = SqliteEngineAdapter {
            root: SqliteRoot::from_value(Some(dir.clone().into())),
            ..adapter()
        };
        let foreign = format!("sqlite://{}/u/m.db", dir.display());
        assert!(adapter.open_pool(mount(&foreign)).await.is_err());
        let own = format!("sqlite://{}/t/m.db", dir.display());
        let pool = adapter.open_pool(mount(&own)).await.unwrap();
        pool.execute_raw(raw("CREATE TABLE t (id INTEGER)", false), identity())
            .await
            .unwrap();
        assert!(dir.join("t/m.db").exists() && !dir.join("u").exists());
        let _ = std::fs::remove_dir_all(dir);
    }
}
