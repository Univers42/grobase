//! PB backups: one zip of the data directory under `{data_dir}/backups/`.
//!
//! `GET /api/backups` lists `[{key, size, modified}]`; `POST` creates
//! (auto-named `pb_backup_binocle_<ts>.zip` like PB); `GET /{key}` downloads;
//! `DELETE /{key}` removes; `POST /{key}/restore` unpacks over the data dir
//! and EXITS the process — the container/supervisor restart brings the
//! restored state up, exactly PB's restore model. All superuser-only.
//!
//! The archive contains every data file (`*.db` checkpointed via
//! `wal_checkpoint(TRUNCATE)` immediately before reading — WAL keeps recent
//! commits OUTSIDE the main file, and the restore lane caught an archive
//! missing them) plus the `pb_storage/` tree. `-wal`/`-shm` never ship.

use axum::extract::{Path, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{json, Value};
use std::io::Write;

use super::{pb_auth, pb_err, pb_of, PbAuth};
use crate::routes::AppState;

fn backups_dir(pb: &super::PbState) -> std::path::PathBuf {
    pb.storage_root
        .parent()
        .map(|p| p.join("backups"))
        .unwrap_or_else(|| std::path::PathBuf::from("./backups"))
}

fn data_dir(pb: &super::PbState) -> std::path::PathBuf {
    pb.storage_root
        .parent()
        .map(std::path::Path::to_path_buf)
        .unwrap_or_else(|| std::path::PathBuf::from("."))
}

fn safe_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 128
        && key.ends_with(".zip")
        && key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
        && !key.contains("..")
}

/// Build the archive on a blocking thread: db files + pb_storage tree.
fn create_zip(data: &std::path::Path, dest: &std::path::Path) -> Result<(), String> {
    let file = std::fs::File::create(dest).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipWriter::new(file);
    let opts = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    let mut stack = vec![data.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = std::fs::read_dir(&dir).map_err(|e| e.to_string())?;
        for entry in entries.flatten() {
            let path = entry.path();
            let rel = path
                .strip_prefix(data)
                .map_err(|e| e.to_string())?
                .to_string_lossy()
                .into_owned();
            // never recurse into ourselves; skip WAL/SHM (the main db file is
            // the durable artifact; -wal contents checkpoint on next open)
            if rel.starts_with("backups") || rel.ends_with("-wal") || rel.ends_with("-shm") {
                continue;
            }
            if path.is_dir() {
                stack.push(path);
                continue;
            }
            // WAL databases keep recent commits in the -wal file we skip:
            // checkpoint each db into its main file first or the archive
            // silently misses everything since the last checkpoint (the m50
            // restore lane caught exactly that).
            if rel.ends_with(".db") {
                if let Ok(conn) = rusqlite::Connection::open(&path) {
                    let _ = conn.pragma_update(None, "busy_timeout", 3000);
                    let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
                }
            }
            zip.start_file(rel, opts).map_err(|e| e.to_string())?;
            let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
            zip.write_all(&bytes).map_err(|e| e.to_string())?;
        }
    }
    zip.finish().map_err(|e| e.to_string())?;
    Ok(())
}

fn restore_zip(archive: &std::path::Path, data: &std::path::Path) -> Result<(), String> {
    let file = std::fs::File::open(archive).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| e.to_string())?;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| e.to_string())?;
        let Some(rel) = entry.enclosed_name() else {
            return Err("archive contains an unsafe path".into());
        };
        let dest = data.join(rel);
        if entry.is_dir() {
            let _ = std::fs::create_dir_all(&dest);
            continue;
        }
        if let Some(parent) = dest.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let mut out = std::fs::File::create(&dest).map_err(|e| e.to_string())?;
        std::io::copy(&mut entry, &mut out).map_err(|e| e.to_string())?;
        // stale WAL/SHM beside a restored db must die
        for suffix in ["-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", dest.display(), suffix));
        }
    }
    Ok(())
}

fn require_su(state: &AppState, headers: &header::HeaderMap) -> Result<(), axum::response::Response> {
    match pb_auth(state, headers) {
        PbAuth::Superuser => Ok(()),
        _ => Err(pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.")),
    }
}

/// GET /api/backups
async fn list(State(state): State<AppState>, headers: header::HeaderMap) -> axum::response::Response {
    if let Err(r) = require_su(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let dir = backups_dir(&pb);
    let mut out: Vec<Value> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if !name.ends_with(".zip") {
                continue;
            }
            let meta = e.metadata().ok();
            let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
            let modified = meta
                .and_then(|m| m.modified().ok())
                .map(chrono::DateTime::<chrono::Utc>::from)
                .map(|t| t.format("%Y-%m-%d %H:%M:%S%.3fZ").to_string())
                .unwrap_or_default();
            out.push(json!({ "key": name, "size": size, "modified": modified }));
        }
    }
    out.sort_by(|a, b| a["key"].as_str().cmp(&b["key"].as_str()));
    (StatusCode::OK, Json(Value::Array(out))).into_response()
}

/// POST /api/backups {name?}
async fn create(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    body: Option<Json<Value>>,
) -> axum::response::Response {
    if let Err(r) = require_su(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let key = body
        .as_ref()
        .and_then(|Json(b)| b.get("name").and_then(|v| v.as_str()))
        .filter(|s| !s.is_empty())
        .map(String::from)
        .unwrap_or_else(|| {
            format!(
                "pb_backup_binocle_{}.zip",
                chrono::Utc::now().format("%Y%m%d%H%M%S")
            )
        });
    if !safe_key(&key) {
        return pb_err(StatusCode::BAD_REQUEST, "invalid backup name (must be a .zip key)");
    }
    let dir = backups_dir(&pb);
    if std::fs::create_dir_all(&dir).is_err() {
        return pb_err(StatusCode::INTERNAL_SERVER_ERROR, "backups dir unavailable");
    }
    let data = data_dir(&pb);
    let dest = dir.join(&key);
    let made = tokio::task::spawn_blocking(move || create_zip(&data, &dest)).await;
    match made {
        Ok(Ok(())) => StatusCode::NO_CONTENT.into_response(),
        Ok(Err(e)) => pb_err(StatusCode::INTERNAL_SERVER_ERROR, &e),
        Err(_) => pb_err(StatusCode::INTERNAL_SERVER_ERROR, "backup task failed"),
    }
}

/// GET /api/backups/{key} — download.
async fn download(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(key): Path<String>,
) -> axum::response::Response {
    if let Err(r) = require_su(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    if !safe_key(&key) {
        return pb_err(StatusCode::BAD_REQUEST, "invalid key");
    }
    match tokio::fs::read(backups_dir(&pb).join(&key)).await {
        Ok(bytes) => (
            [
                (header::CONTENT_TYPE, "application/zip".to_string()),
                (
                    header::CONTENT_DISPOSITION,
                    format!("attachment; filename=\"{key}\""),
                ),
            ],
            bytes,
        )
            .into_response(),
        Err(_) => pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found."),
    }
}

/// DELETE /api/backups/{key}
async fn remove(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(key): Path<String>,
) -> axum::response::Response {
    if let Err(r) = require_su(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    if !safe_key(&key) {
        return pb_err(StatusCode::BAD_REQUEST, "invalid key");
    }
    match tokio::fs::remove_file(backups_dir(&pb).join(&key)).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(_) => pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found."),
    }
}

/// POST /api/backups/{key}/restore — unpack + exit (supervisor restarts).
async fn restore(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(key): Path<String>,
) -> axum::response::Response {
    if let Err(r) = require_su(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    if !safe_key(&key) {
        return pb_err(StatusCode::BAD_REQUEST, "invalid key");
    }
    let archive = backups_dir(&pb).join(&key);
    if !archive.exists() {
        return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found.");
    }
    let data = data_dir(&pb);
    let unpacked = tokio::task::spawn_blocking(move || restore_zip(&archive, &data)).await;
    match unpacked {
        Ok(Ok(())) => {
            tracing::warn!(target: "audit", event = "pb_restore", key = %key,
                "backup restored — exiting for a clean reload (supervisor restarts)");
            tokio::spawn(async {
                tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                std::process::exit(0);
            });
            StatusCode::NO_CONTENT.into_response()
        }
        Ok(Err(e)) => pb_err(StatusCode::BAD_REQUEST, &e),
        Err(_) => pb_err(StatusCode::INTERNAL_SERVER_ERROR, "restore task failed"),
    }
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/backups", get(list).post(create))
        .route("/api/backups/:key", get(download).delete(remove))
        .route("/api/backups/:key/restore", post(restore))
}
