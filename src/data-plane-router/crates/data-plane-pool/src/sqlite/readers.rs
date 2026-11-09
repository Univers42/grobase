/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   readers.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/11/09 12:20:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/11/09 12:20:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Reader connections for one SQLite file.
//!
//! Published `deadpool-sqlite` (0.14, and current master) pins `rusqlite` 0.40,
//! which bundles SQLite before 3.54.0 (RUSTSEC-2026-0459). This pool opens
//! `rusqlite` 0.41 directly so every reader links the patched bundled SQLite.
//! A checkout runs the closure on a blocking thread, the same shape `interact`
//! had, and idle connections are reused up to [`MAX_READERS`].
//!
//! Caveat: [`Connection::open`] takes no flags, so a reader follows a symlink
//! swapped in at the path after the root check. The writer passes
//! `SQLITE_OPEN_NOFOLLOW`.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use data_plane_core::{DataPlaneError, DataPlaneResult};
use rusqlite::Connection;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::harden::{harden, tune};

const MAX_READERS: usize = 16;

struct Inner {
    path: Arc<str>,
    free: Mutex<Vec<Connection>>,
    permits: Arc<Semaphore>,
    created: AtomicUsize,
    closed: AtomicBool,
}

pub(super) struct ReaderPool {
    inner: Arc<Inner>,
}

#[cfg(test)]
pub(super) struct PoolStatus {
    pub size: usize,
}

pub(super) struct Reader {
    slot: Arc<Mutex<Option<Connection>>>,
    home: Arc<Inner>,
    permit: Option<OwnedSemaphorePermit>,
}

impl ReaderPool {
    pub(super) fn open(path: &str) -> Self {
        Self {
            inner: Arc::new(Inner {
                path: Arc::from(path),
                free: Mutex::new(Vec::new()),
                permits: Arc::new(Semaphore::new(MAX_READERS)),
                created: AtomicUsize::new(0),
                closed: AtomicBool::new(false),
            }),
        }
    }

    pub(super) async fn get(&self) -> DataPlaneResult<Reader> {
        if self.inner.closed.load(Ordering::Relaxed) {
            return Err(closed());
        }
        let permit = self
            .inner
            .permits
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| closed())?;
        let recycled = self
            .inner
            .free
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .pop();
        let fresh = recycled.is_none();
        let conn = match recycled {
            Some(conn) => conn,
            None => open_fresh(&self.inner.path).await?,
        };
        if fresh {
            self.inner.created.fetch_add(1, Ordering::Relaxed);
        }
        Ok(Reader {
            slot: Arc::new(Mutex::new(Some(conn))),
            home: Arc::clone(&self.inner),
            permit: Some(permit),
        })
    }

    #[cfg(test)]
    pub(super) fn status(&self) -> PoolStatus {
        PoolStatus {
            size: self.inner.created.load(Ordering::Relaxed),
        }
    }

    pub(super) fn close(&self) {
        self.inner.closed.store(true, Ordering::Relaxed);
        self.inner.permits.close();
        self.inner
            .free
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clear();
    }
}

impl Reader {
    pub(super) async fn interact<T, F>(&self, f: F) -> Result<T, String>
    where
        F: FnOnce(&mut Connection) -> T + Send + 'static,
        T: Send + 'static,
    {
        let slot = Arc::clone(&self.slot);
        let ran = tokio::task::spawn_blocking(move || with_conn(&slot, f))
            .await
            .map_err(|e| e.to_string())?;
        ran
    }
}

impl Drop for Reader {
    fn drop(&mut self) {
        let conn = self
            .slot
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(conn) = conn {
            if !self.home.closed.load(Ordering::Relaxed) {
                self.home
                    .free
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .push(conn);
            }
        }
        self.permit.take();
    }
}

fn with_conn<T, F>(slot: &Mutex<Option<Connection>>, f: F) -> Result<T, String>
where
    F: FnOnce(&mut Connection) -> T,
{
    let mut guard = slot
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let conn = guard
        .as_mut()
        .ok_or_else(|| "sqlite reader is closed".to_string())?;
    Ok(f(conn))
}

async fn open_fresh(path: &Arc<str>) -> DataPlaneResult<Connection> {
    let path = Arc::clone(path);
    let opened = tokio::task::spawn_blocking(move || {
        let mut conn = Connection::open(path.as_ref())?;
        tune(&conn)?;
        harden(&mut conn)?;
        Ok(conn)
    })
    .await
    .map_err(|e| backend(e.to_string()))?;
    opened.map_err(|e: rusqlite::Error| backend(e.to_string()))
}

fn backend(detail: String) -> DataPlaneError {
    DataPlaneError::Backend {
        message: format!("sqlite pool create failed: {detail}"),
    }
}

fn closed() -> DataPlaneError {
    DataPlaneError::Backend {
        message: "sqlite pool is closed".into(),
    }
}
