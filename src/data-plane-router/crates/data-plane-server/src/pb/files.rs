//! PB file storage: bytes live at `{storage_root}/{collection id}/{record
//! id}/{stored name}`, the record's file column stores the generated name
//! (PB shape: `{sanitized base}_{10 random}.{ext}`). Serving is
//! `GET /api/files/{collection}/{recordId}/{filename}` with `?thumb=` crop/
//! fit variants for jpeg/png, cached as siblings (`thumbs_{spec}_{name}`).

use axum::extract::{Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::json;
use std::collections::HashMap;

use super::{pb_err, pb_of};
use crate::routes::AppState;

// ─── S3 backend (settings.s3, feature s3) ────────────────────────────────────

/// Presign-capable S3 target from settings: (bucket, credentials).
#[cfg(feature = "s3")]
pub(crate) fn s3_target(
    settings: &serde_json::Value,
) -> Option<(rusty_s3::Bucket, rusty_s3::Credentials)> {
    let s3 = settings.get("s3")?;
    if s3.get("enabled") != Some(&serde_json::Value::Bool(true)) {
        return None;
    }
    let endpoint = s3.get("endpoint")?.as_str()?.parse().ok()?;
    let bucket = s3.get("bucket")?.as_str()?.to_string();
    let region = s3.get("region").and_then(|v| v.as_str()).unwrap_or("us-east-1").to_string();
    let path_style = if s3.get("forcePathStyle") == Some(&serde_json::Value::Bool(true)) {
        rusty_s3::UrlStyle::Path
    } else {
        rusty_s3::UrlStyle::VirtualHost
    };
    let bucket = rusty_s3::Bucket::new(endpoint, path_style, bucket, region).ok()?;
    let creds = rusty_s3::Credentials::new(
        s3.get("accessKey")?.as_str()?.to_string(),
        s3.get("secret")?.as_str()?.to_string(),
    );
    Some((bucket, creds))
}

#[cfg(feature = "s3")]
fn s3_http() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .unwrap_or_default()
    })
}

#[cfg(feature = "s3")]
pub(crate) async fn s3_put(
    bucket: &rusty_s3::Bucket,
    creds: &rusty_s3::Credentials,
    key: &str,
    bytes: Vec<u8>,
) -> Result<(), String> {
    use rusty_s3::S3Action;
    let action = bucket.put_object(Some(creds), key);
    let url = action.sign(std::time::Duration::from_secs(300));
    let resp = s3_http().put(url).body(bytes).send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("s3 put {} -> {}", key, resp.status()));
    }
    Ok(())
}

#[cfg(feature = "s3")]
pub(crate) async fn s3_get(
    bucket: &rusty_s3::Bucket,
    creds: &rusty_s3::Credentials,
    key: &str,
) -> Option<Vec<u8>> {
    use rusty_s3::S3Action;
    let action = bucket.get_object(Some(creds), key);
    let url = action.sign(std::time::Duration::from_secs(300));
    let resp = s3_http().get(url).send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.bytes().await.ok().map(|b| b.to_vec())
}

#[cfg(feature = "s3")]
pub(crate) async fn s3_delete(
    bucket: &rusty_s3::Bucket,
    creds: &rusty_s3::Credentials,
    key: &str,
) {
    use rusty_s3::S3Action;
    let action = bucket.delete_object(Some(creds), key);
    let url = action.sign(std::time::Duration::from_secs(300));
    let _ = s3_http().delete(url).send().await;
}

/// `photo one.PNG` → `photo_one_a1b2c3d4e5.PNG` — PB sanitizes the base and
/// KEEPS the original extension case (the m48 diff caught a lowercased ext).
pub(crate) fn stored_name(original: &str) -> String {
    let (base, ext) = match original.rsplit_once('.') {
        Some((b, e)) => (b, e.to_string()),
        None => (original, String::new()),
    };
    let safe: String = base
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' })
        .take(40)
        .collect();
    let rand: String = super::pb_id().chars().take(10).collect();
    if ext.is_empty() {
        format!("{safe}_{rand}")
    } else {
        format!("{safe}_{rand}.{ext}")
    }
}

fn content_type_of(name: &str) -> &'static str {
    match name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).as_deref() {
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("svg") => "image/svg+xml",
        Some("pdf") => "application/pdf",
        Some("txt") => "text/plain; charset=utf-8",
        Some("json") => "application/json",
        Some("html") => "text/html; charset=utf-8",
        Some("css") => "text/css",
        Some("js" | "mjs") => "text/javascript",
        Some("mp4") => "video/mp4",
        Some("mp3") => "audio/mpeg",
        Some("zip") => "application/zip",
        _ => "application/octet-stream",
    }
}

/// A path segment must be exactly one safe component — no traversal.
fn safe_segment(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
        && !s.contains("..")
}

/// `?thumb=WxH | WxHt | WxHb | WxHf | 0xH | Wx0` → resized bytes (png).
fn make_thumb(bytes: &[u8], spec: &str) -> Option<Vec<u8>> {
    let (dims, mode) = match spec.chars().last() {
        Some('t' | 'b' | 'f') => (&spec[..spec.len() - 1], spec.chars().last().unwrap_or('c')),
        _ => (spec, 'c'),
    };
    let (w_raw, h_raw) = dims.split_once('x')?;
    let w: u32 = w_raw.parse().ok()?;
    let h: u32 = h_raw.parse().ok()?;
    if w == 0 && h == 0 || w > 4000 || h > 4000 {
        return None;
    }
    let img = image::load_from_memory(bytes).ok()?;
    let out = match (w, h, mode) {
        // 0xH / Wx0: preserve aspect ratio on the free axis
        (0, h, _) => img.resize(u32::MAX, h, image::imageops::FilterType::Triangle),
        (w, 0, _) => img.resize(w, u32::MAX, image::imageops::FilterType::Triangle),
        // f = fit inside WxH (no crop)
        (w, h, 'f') => img.resize(w, h, image::imageops::FilterType::Triangle),
        // default/t/b = cover WxH then crop (center/top/bottom)
        (w, h, m) => {
            let covered = img.resize_to_fill(w, h, image::imageops::FilterType::Triangle);
            // resize_to_fill center-crops; t/b shift the crop window
            if m == 'c' {
                covered
            } else {
                let scale = f64::max(
                    w as f64 / img.width() as f64,
                    h as f64 / img.height() as f64,
                );
                let sw = (img.width() as f64 * scale).round() as u32;
                let sh = (img.height() as f64 * scale).round() as u32;
                let scaled = img.resize_exact(sw.max(w), sh.max(h), image::imageops::FilterType::Triangle);
                let y = if m == 't' { 0 } else { scaled.height().saturating_sub(h) };
                let x = (scaled.width().saturating_sub(w)) / 2;
                scaled.crop_imm(x, y, w, h)
            }
        }
    };
    let mut buf = std::io::Cursor::new(Vec::new());
    out.write_to(&mut buf, image::ImageFormat::Png).ok()?;
    Some(buf.into_inner())
}

/// POST /api/files/token — an authenticated caller (record or superuser)
/// mints a short-lived token that unlocks PROTECTED file fields via
/// `?token=` (PB's flow for files behind auth).
async fn file_token(
    State(state): State<AppState>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    let principal = match super::pb_auth(&state, &headers) {
        super::PbAuth::Superuser => "su".to_string(),
        super::PbAuth::Record { collection_id, record_id } => {
            format!("{collection_id}:{record_id}")
        }
        _ => {
            return super::pb_err(
                StatusCode::UNAUTHORIZED,
                "The request requires valid authorization token.",
            )
        }
    };
    let one = match crate::one::one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    match one.mint_flow_jwt(&principal, "", "pbfile") {
        Ok(t) => (StatusCode::OK, Json(json!({ "token": t }))).into_response(),
        Err(e) => super::pb_err(StatusCode::INTERNAL_SERVER_ERROR, &e),
    }
}

/// Which file FIELD owns `filename` on this record, and is it protected?
async fn field_is_protected(
    state: &AppState,
    col: &super::collections::Collection,
    rid: &str,
    filename: &str,
) -> bool {
    let protected_fields: Vec<String> = col
        .fields
        .as_array()
        .map(|fields| {
            fields
                .iter()
                .filter(|f| {
                    f.get("type").and_then(serde_json::Value::as_str) == Some("file")
                        && f.get("protected").and_then(serde_json::Value::as_bool) == Some(true)
                })
                .filter_map(|f| f.get("name").and_then(serde_json::Value::as_str).map(String::from))
                .collect()
        })
        .unwrap_or_default();
    if protected_fields.is_empty() {
        return false;
    }
    let mut op = super::records::base_op_pub(data_plane_core::DataOperationKind::Get, &col.name);
    op.filter = Some(json!({ "id": rid }));
    let Ok(result) = super::exec(state, op).await else {
        return true; // can't prove it's public → protect
    };
    let Some(row) = result.rows.first() else { return true };
    protected_fields.iter().any(|f| match row.get(f) {
        Some(serde_json::Value::String(s)) => s == filename || s.starts_with('[') && s.contains(filename),
        _ => false,
    })
}

/// GET /api/files/{collection}/{recordId}/{filename}[?thumb=spec]
async fn serve(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path((cname, rid, filename)): Path<(String, String, String)>,
    Query(q): Query<HashMap<String, String>>,
) -> axum::response::Response {
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let Some(col) = pb.col_get(&cname) else {
        return pb_err(StatusCode::NOT_FOUND, "collection not found");
    };
    if !safe_segment(&rid) || !safe_segment(&filename) {
        return pb_err(StatusCode::BAD_REQUEST, "invalid path");
    }
    if field_is_protected(&state, &col, &rid, &filename).await {
        let authorized = q
            .get("token")
            .map(|t| {
                crate::one::one_of(&state)
                    .ok()
                    .map(|one| one.verify_flow_jwt(t, "pbfile").is_ok())
                    .unwrap_or(false)
            })
            .unwrap_or(false)
            || matches!(super::pb_auth(&state, &headers), super::PbAuth::Superuser);
        if !authorized {
            return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found.");
        }
    }
    let dir = pb.storage_root.join(&col.id).join(&rid);
    let path = dir.join(&filename);
    #[allow(unused_mut)]
    let mut bytes: Option<Vec<u8>> = tokio::fs::read(&path).await.ok();
    #[cfg(feature = "s3")]
    if bytes.is_none() {
        if let Some((bucket, creds)) = s3_target(&pb.settings_cached()) {
            bytes = s3_get(&bucket, &creds, &format!("{}/{}/{}", col.id, rid, filename)).await;
        }
    }
    let Some(bytes) = bytes else {
        return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found.");
    };

    if let Some(spec) = q.get("thumb").filter(|s| !s.is_empty()) {
        if !safe_segment(spec) {
            return pb_err(StatusCode::BAD_REQUEST, "invalid thumb spec");
        }
        let cache = dir.join(format!("thumbs_{spec}_{filename}"));
        if let Ok(cached) = tokio::fs::read(&cache).await {
            return ([(header::CONTENT_TYPE, "image/png")], cached).into_response();
        }
        let src = bytes.clone();
        let spec_owned = spec.clone();
        let made = tokio::task::spawn_blocking(move || make_thumb(&src, &spec_owned))
            .await
            .ok()
            .flatten();
        if let Some(thumb) = made {
            let _ = tokio::fs::write(&cache, &thumb).await;
            return ([(header::CONTENT_TYPE, "image/png")], thumb).into_response();
        }
        // not an image / bad spec → PB serves the original
    }
    (
        [
            (header::CONTENT_TYPE, content_type_of(&filename)),
            (header::CACHE_CONTROL, "max-age=2592000, public"),
        ],
        bytes,
    )
        .into_response()
}

/// Best-effort removal of a record's file directory (record deleted).
pub(crate) async fn remove_record_files(pb: &super::PbState, collection_id: &str, record_id: &str) {
    if !safe_segment(record_id) {
        return;
    }
    let dir = pb.storage_root.join(collection_id).join(record_id);
    let _ = tokio::fs::remove_dir_all(dir).await;
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/files/token", post(file_token))
        .route("/api/files/:collection/:record/:filename", get(serve))
}
