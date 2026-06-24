//! Proxy hot path: range-forward the resolved upstream media file straight to the
//! browser <video>, reusing one pooled client and never buffering the body.

use axum::body::Body;
use axum::http::{header, HeaderMap, HeaderName, HeaderValue, StatusCode};
use axum::response::Response;
use reqwest::Client;

use crate::error::{Result, StreamError};
use crate::resolve::Resolved;

/// proxy issues an upstream GET mirroring the inbound Range, then streams the
/// upstream body through with the correct partial-content headers.
pub async fn proxy(http: &Client, resolved: &Resolved, range: Option<&str>) -> Result<Response> {
    let mut req = http.get(&resolved.url);
    if let Some(r) = range {
        validate_range(r)?;
        req = req.header(header::RANGE, r);
    }
    let upstream = req
        .send()
        .await
        .map_err(|e| StreamError::Upstream(e.to_string()))?;
    build_response(upstream, resolved.content_length)
}

/// validate_range rejects a malformed or multi-range header before it reaches the
/// upstream (a single "bytes=start-end" is the only accepted form).
fn validate_range(raw: &str) -> Result<()> {
    let spec = raw
        .trim()
        .strip_prefix("bytes=")
        .ok_or(StreamError::BadRange)?;
    if spec.contains(',') || !spec.contains('-') {
        return Err(StreamError::BadRange);
    }
    Ok(())
}

/// build_response maps the upstream status to 206/200/416, copies the byte-range
/// headers, forces video/mp4 + Accept-Ranges, and streams the body unbuffered.
/// fallback_len supplies Content-Length when the upstream omitted it (the catalog
/// stream_url path), so the player can still seek on a full 200.
fn build_response(upstream: reqwest::Response, fallback_len: Option<u64>) -> Result<Response> {
    let status = map_status(upstream.status())?;
    let mut builder = Response::builder().status(status);
    let headers = builder
        .headers_mut()
        .ok_or_else(|| StreamError::Upstream("response builder headers unavailable".to_string()))?;
    copy_passthrough(upstream.headers(), headers);
    set_stream_headers(headers, fallback_len);
    let body = Body::from_stream(upstream.bytes_stream());
    builder
        .body(body)
        .map_err(|e| StreamError::Upstream(e.to_string()))
}

/// map_status translates the upstream code into the client-facing status: 206 for
/// partial, 200 for full, 416 for a bad range; anything else is an upstream error.
fn map_status(code: reqwest::StatusCode) -> Result<StatusCode> {
    match code {
        reqwest::StatusCode::PARTIAL_CONTENT => Ok(StatusCode::PARTIAL_CONTENT),
        reqwest::StatusCode::OK => Ok(StatusCode::OK),
        reqwest::StatusCode::RANGE_NOT_SATISFIABLE => Err(StreamError::BadRange),
        other => Err(StreamError::Upstream(format!("upstream status {other}"))),
    }
}

/// copy_passthrough forwards the length + range headers the player needs to seek.
fn copy_passthrough(from: &HeaderMap, to: &mut HeaderMap) {
    for name in [header::CONTENT_RANGE, header::CONTENT_LENGTH] {
        if let Some(v) = from.get(&name) {
            to.insert(name, v.clone());
        }
    }
}

/// set_stream_headers fixes the content type, advertises range support, disables
/// Kong/WAF response buffering, and fills Content-Length from fallback_len when
/// the upstream omitted it.
fn set_stream_headers(headers: &mut HeaderMap, fallback_len: Option<u64>) {
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("video/mp4"));
    headers.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    headers.insert(
        HeaderName::from_static("x-accel-buffering"),
        HeaderValue::from_static("no"),
    );
    if !headers.contains_key(header::CONTENT_LENGTH) {
        if let Some(len) = fallback_len {
            if let Ok(v) = HeaderValue::from_str(&len.to_string()) {
                headers.insert(header::CONTENT_LENGTH, v);
            }
        }
    }
}
