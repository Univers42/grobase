/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   one_files.rs                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:33:20 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:33:22 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! binocle-one file storage — upload, serve, thumbnails, protected links.
//!
//! Files attach to a `(table, record, field)` coordinate like PocketBase's
//! file fields. Bytes live on disk under
//! `{NANO_DATA_DIR}/storage/{table}/{record}/{field}/{uuid}.{ext}` (names are
//! server-minted uuids — user input never reaches the filesystem), metadata
//! in `one_files` in the meta DB, owner-stamped with the uploader principal.
//!
//! Access: the uploader (owner) or an admin-scope key; or a 5-minute signed
//! file token (`POST /one/v1/files/{id}/token` → `GET …?token=`) for `<img>`
//! and download links — PB's "protected files" shape.
//!
//! `?thumb=WxH` serves a cached jpeg/png thumbnail (the `image` crate,
//! jpeg+png decoders only — binary weight). Caps: `ONE_MAX_FILE_MB`
//! (default 10), content-type allowlist (`ONE_FILES_ALLOW` overrides; html
//! and svg stay out by default — stored-XSS vectors). S3 backends remain a
//! cloud-tier concern (MinIO) — documented, deliberately not in this binary.

use axum::extract::{DefaultBodyLimit, Multipart, Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;

use crate::auth::VerifiedIdentity;
use crate::one::{one_of, FileMeta, OneState};
use crate::routes::{api_err, bypass_verify, AppState};

const DEFAULT_MAX_MB: usize = 10;
const DEFAULT_ALLOW: &[&str] = &[
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "application/pdf",
    "text/plain",
    "text/csv",
    "application/json",
    "application/zip",
    "application/gzip",
    "audio/mpeg",
    "video/mp4",
    "application/octet-stream",
];

fn max_bytes() -> usize {
    std::env::var("ONE_MAX_FILE_MB")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(DEFAULT_MAX_MB)
        * 1024
        * 1024
}

fn type_allowed(ct: &str) -> bool {
    if let Ok(allow) = std::env::var("ONE_FILES_ALLOW") {
        return allow.split(',').any(|t| t.trim().eq_ignore_ascii_case(ct));
    }
    DEFAULT_ALLOW.contains(&ct)
}

/// Identifier-grade path segments only — user input never names a filesystem
/// entry beyond passing this gate.
fn safe_segment(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Keep a short alphanumeric extension from the client filename (display +
/// content sniffing stay honest); everything else is dropped.
fn safe_ext(filename: &str) -> Option<String> {
    let ext = filename.rsplit_once('.')?.1;
    (ext.len() <= 8 && !ext.is_empty() && ext.bytes().all(|b| b.is_ascii_alphanumeric()))
        .then(|| ext.to_lowercase())
}

fn storage_dir(one: &OneState, f: &FileMeta) -> std::path::PathBuf {
    one.data_dir
        .join("storage")
        .join(&f.table_name)
        .join(&f.record_id)
        .join(&f.field)
}

fn is_admin(id: &VerifiedIdentity) -> bool {
    id.scopes.iter().any(|s| s == "admin")
}

fn can_read(id: &VerifiedIdentity, meta: &FileMeta) -> bool {
    is_admin(id) || id.principal == meta.owner
}

// ─── handlers ────────────────────────────────────────────────────────────────

/// POST /one/v1/files/{table}/{record}/{field} — multipart, first file part.
async fn upload(
    State(state): State<AppState>,
    Path((table, record, field)): Path<(String, String, String)>,
    headers: header::HeaderMap,
    mut multipart: Multipart,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let id = match bypass_verify(&state, &headers).await {
        Ok(id) => id,
        Err(r) => return r,
    };
    if !id.scopes.iter().any(|s| s == "write" || s == "admin") {
        return api_err(
            StatusCode::FORBIDDEN,
            "scope_denied",
            "write scope required",
        );
    }
    if !(safe_segment(&table) && safe_segment(&record) && safe_segment(&field)) {
        return api_err(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "table/record/field must be 1-64 chars of [A-Za-z0-9_-]",
        );
    }
    let part = match multipart.next_field().await {
        Ok(Some(p)) => p,
        _ => {
            return api_err(
                StatusCode::BAD_REQUEST,
                "invalid_request",
                "a multipart file field is required",
            )
        }
    };
    let filename = part.file_name().unwrap_or("upload").to_string();
    let content_type = part
        .content_type()
        .unwrap_or("application/octet-stream")
        .to_string();
    if !type_allowed(&content_type) {
        return api_err(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "type_not_allowed",
            "this content type is not allowed (ONE_FILES_ALLOW configures the list)",
        );
    }
    let bytes = match part.bytes().await {
        Ok(b) => b,
        Err(_) => {
            return api_err(
                StatusCode::PAYLOAD_TOO_LARGE,
                "file_too_large",
                "upload exceeds the size limit (ONE_MAX_FILE_MB)",
            )
        }
    };
    if bytes.len() > max_bytes() {
        return api_err(
            StatusCode::PAYLOAD_TOO_LARGE,
            "file_too_large",
            "upload exceeds the size limit (ONE_MAX_FILE_MB)",
        );
    }
    let file_id = uuid::Uuid::new_v4().simple().to_string();
    let stored = match safe_ext(&filename) {
        Some(ext) => format!("{file_id}.{ext}"),
        None => file_id.clone(),
    };
    let meta = FileMeta {
        id: file_id,
        table_name: table,
        record_id: record,
        field,
        owner: id.principal.clone(),
        filename: filename.chars().take(128).collect(),
        stored,
        content_type,
        size: bytes.len() as i64,
        created_at: chrono::Utc::now().to_rfc3339(),
    };
    let dir = storage_dir(&one, &meta);
    if tokio::fs::create_dir_all(&dir).await.is_err()
        || tokio::fs::write(dir.join(&meta.stored), &bytes)
            .await
            .is_err()
    {
        return api_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            "storage_failed",
            "could not persist the file",
        );
    }
    if one.users.file_insert(&meta).is_err() {
        let _ = tokio::fs::remove_file(dir.join(&meta.stored)).await;
        return api_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            "storage_failed",
            "could not record the file",
        );
    }
    tracing::info!(target: "audit", event = "file_uploaded", file = %meta.id, owner = %meta.owner, size = meta.size, "file stored");
    (
        StatusCode::CREATED,
        Json(json!({ "file": meta, "url": format!("/one/v1/file/{}", meta.id) })),
    )
        .into_response()
}

#[derive(Deserialize)]
struct ServeQuery {
    thumb: Option<String>,
    token: Option<String>,
}

/// Parse + clamp `WxH` (1..=2048 each).
fn parse_thumb(spec: &str) -> Option<(u32, u32)> {
    let (w, h) = spec.split_once('x')?;
    let (w, h): (u32, u32) = (w.parse().ok()?, h.parse().ok()?);
    ((1..=2048).contains(&w) && (1..=2048).contains(&h)).then_some((w, h))
}

/// GET /one/v1/files/{id}[?thumb=WxH][&token=…]
async fn serve(
    State(state): State<AppState>,
    Path(file_id): Path<String>,
    Query(q): Query<ServeQuery>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let Some(meta) = one.users.file_get(&file_id) else {
        return api_err(StatusCode::NOT_FOUND, "not_found", "no such file");
    };
    // A valid signed file token grants access on its own; otherwise the
    // caller must be the owner or an admin key.
    let token_ok = q
        .token
        .as_deref()
        .and_then(|t| one.verify_file_token(t))
        .is_some_and(|sub| sub == meta.id);
    if !token_ok {
        match bypass_verify(&state, &headers).await {
            Ok(id) if can_read(&id, &meta) => {}
            Ok(_) => return api_err(StatusCode::NOT_FOUND, "not_found", "no such file"),
            Err(r) => return r,
        }
    }
    let dir = storage_dir(&one, &meta);
    let (path, content_type) = match q.thumb.as_deref() {
        Some(spec) if meta.content_type == "image/jpeg" || meta.content_type == "image/png" => {
            let Some((w, h)) = parse_thumb(spec) else {
                return api_err(
                    StatusCode::BAD_REQUEST,
                    "invalid_request",
                    "thumb must be WxH (1-2048)",
                );
            };
            let thumb_path = dir.join(format!("{}.t{w}x{h}", meta.stored));
            if tokio::fs::metadata(&thumb_path).await.is_err() {
                let src = dir.join(&meta.stored);
                let fmt = if meta.content_type == "image/png" {
                    image::ImageFormat::Png
                } else {
                    image::ImageFormat::Jpeg
                };
                let out = thumb_path.clone();
                let made = tokio::task::spawn_blocking(move || -> Result<(), String> {
                    let img = image::open(&src).map_err(|e| e.to_string())?;
                    img.thumbnail(w, h)
                        .save_with_format(&out, fmt)
                        .map_err(|e| e.to_string())
                })
                .await;
                if !matches!(made, Ok(Ok(()))) {
                    return api_err(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "thumb_failed",
                        "could not generate the thumbnail",
                    );
                }
            }
            (thumb_path, meta.content_type.clone())
        }
        _ => (dir.join(&meta.stored), meta.content_type.clone()),
    };
    let Ok(bytes) = tokio::fs::read(&path).await else {
        return api_err(StatusCode::NOT_FOUND, "not_found", "file bytes missing");
    };
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, content_type),
            (
                header::CONTENT_DISPOSITION,
                format!("inline; filename=\"{}\"", meta.filename.replace('"', "")),
            ),
            (header::CACHE_CONTROL, "private, max-age=3600".to_string()),
            // Belt over the allowlist: never let a browser sniff its way to HTML.
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff".to_string()),
        ],
        bytes,
    )
        .into_response()
}

/// GET /one/v1/files/{table}/{record} — list (owner's view; admin sees all).
async fn list(
    State(state): State<AppState>,
    Path((table, record)): Path<(String, String)>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let id = match bypass_verify(&state, &headers).await {
        Ok(id) => id,
        Err(r) => return r,
    };
    let files: Vec<FileMeta> = one
        .users
        .file_list(&table, &record)
        .into_iter()
        .filter(|f| can_read(&id, f))
        .collect();
    Json(json!({ "files": files })).into_response()
}

/// DELETE /one/v1/files/{id} — owner or admin; removes bytes + thumbnails.
async fn delete(
    State(state): State<AppState>,
    Path(file_id): Path<String>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let id = match bypass_verify(&state, &headers).await {
        Ok(id) => id,
        Err(r) => return r,
    };
    let Some(meta) = one.users.file_get(&file_id) else {
        return api_err(StatusCode::NOT_FOUND, "not_found", "no such file");
    };
    if !can_read(&id, &meta) {
        return api_err(StatusCode::NOT_FOUND, "not_found", "no such file");
    }
    one.users.file_delete(&file_id);
    let dir = storage_dir(&one, &meta);
    if let Ok(mut entries) = tokio::fs::read_dir(&dir).await {
        while let Ok(Some(e)) = entries.next_entry().await {
            if e.file_name().to_string_lossy().starts_with(&meta.stored) {
                let _ = tokio::fs::remove_file(e.path()).await;
            }
        }
    }
    tracing::info!(target: "audit", event = "file_deleted", file = %file_id, by = %id.principal, "file removed");
    StatusCode::NO_CONTENT.into_response()
}

/// POST /one/v1/files/{id}/token — owner/admin mints a 5-minute access grant.
async fn token(
    State(state): State<AppState>,
    Path(file_id): Path<String>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let id = match bypass_verify(&state, &headers).await {
        Ok(id) => id,
        Err(r) => return r,
    };
    let Some(meta) = one.users.file_get(&file_id) else {
        return api_err(StatusCode::NOT_FOUND, "not_found", "no such file");
    };
    if !can_read(&id, &meta) {
        return api_err(StatusCode::NOT_FOUND, "not_found", "no such file");
    }
    match one.mint_file_token(&file_id) {
        Ok(t) => Json(json!({ "token": t, "expires_in": 300 })).into_response(),
        Err(e) => api_err(StatusCode::INTERNAL_SERVER_ERROR, "token_failed", &e),
    }
}

pub fn routes() -> Router<AppState> {
    // Coordinate routes live under /files/…, id-addressed ones under
    // /file/:id — matchit forbids differently-named params at one position.
    Router::new()
        .route("/one/v1/files/:table/:record/:field", post(upload))
        .route("/one/v1/files/:table/:record", get(list))
        .route("/one/v1/file/:id", get(serve).delete(delete))
        .route("/one/v1/file/:id/token", post(token))
        // The multipart body cap: configured max + headroom for the envelope.
        .layer(DefaultBodyLimit::max(max_bytes() + 64 * 1024))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segments_and_extensions_are_strict() {
        assert!(safe_segment("notes_2024-v1"));
        assert!(!safe_segment(""));
        assert!(!safe_segment("a/b"));
        assert!(!safe_segment("../etc"));
        assert!(!safe_segment(&"x".repeat(65)));
        assert_eq!(safe_ext("photo.JPG").as_deref(), Some("jpg"));
        assert_eq!(safe_ext("archive.tar.gz").as_deref(), Some("gz"));
        assert!(safe_ext("no-extension").is_none());
        assert!(safe_ext("evil.sh;rm -rf").is_none());
    }

    #[test]
    fn thumb_spec_is_clamped() {
        assert_eq!(parse_thumb("100x80"), Some((100, 80)));
        assert_eq!(parse_thumb("0x80"), None);
        assert_eq!(parse_thumb("100x4096"), None);
        assert_eq!(parse_thumb("axb"), None);
        assert_eq!(parse_thumb("100"), None);
    }

    #[test]
    fn default_allowlist_blocks_active_content() {
        assert!(type_allowed("image/png"));
        assert!(type_allowed("application/pdf"));
        assert!(
            !type_allowed("text/html"),
            "stored-XSS vector must be off by default"
        );
        assert!(
            !type_allowed("image/svg+xml"),
            "svg scripts must be off by default"
        );
    }
}
