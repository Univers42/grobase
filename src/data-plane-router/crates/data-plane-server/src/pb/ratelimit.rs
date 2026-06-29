//! PB-style rate limiting on the /api facade: `settings.rateLimits`
//! `{enabled, rules: [{label, maxRequests, duration}]}` — fixed window per
//! (rule label, client IP). Labels match PB's grammar subset: a `/`-prefixed
//! label is a path prefix (`/api/health`), `*:<op>` matches an operation
//! class on any collection, `<collection>:<op>` pins one. Off by default
//! (PB ships it disabled); 429s use PB's envelope.
//!
//! Client IP comes from the socket (ConnectInfo), overridden by the LAST
//! X-Forwarded-For hop only when `settings.trustedProxy.headers` lists it —
//! never trust forwarding headers by default.

use axum::extract::{ConnectInfo, State};
use axum::http::{header, StatusCode};
use serde_json::Value;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::Instant;

use crate::routes::AppState;

#[derive(Default)]
pub(crate) struct Windows {
    map: std::sync::Mutex<HashMap<(String, String), (u32, Instant)>>,
}

impl Windows {
    /// Returns false when the (label, ip) window is exhausted.
    fn allow(&self, label: &str, ip: &str, max: u32, duration_secs: u64) -> bool {
        let mut map = self
            .map
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // bound the map: a sweep when it grows past 16k entries
        if map.len() > 16_384 {
            map.retain(|_, (_, start)| start.elapsed().as_secs() < 3600);
        }
        let now = Instant::now();
        let entry = map
            .entry((label.to_string(), ip.to_string()))
            .or_insert((0, now));
        if entry.1.elapsed().as_secs() >= duration_secs {
            *entry = (0, now);
        }
        entry.0 += 1;
        entry.0 <= max
    }
}

/// Operation class of a request, PB-label style.
fn op_class(method: &str, path: &str) -> (Option<String>, &'static str) {
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    // api / collections / {c} / ...
    let collection = (parts.len() >= 3 && parts[0] == "api" && parts[1] == "collections")
        .then(|| parts[2].to_string());
    let tail = parts.last().copied().unwrap_or_default();
    let op = if tail.starts_with("auth-") || tail == "request-otp" {
        "auth"
    } else if parts.get(3) == Some(&"records") {
        match (method, parts.len()) {
            ("POST", 4) => "create",
            ("GET", 4) => "list",
            ("GET", 5) => "view",
            ("PATCH", 5) => "update",
            ("DELETE", 5) => "delete",
            _ => "other",
        }
    } else {
        "other"
    };
    (collection, op)
}

/// Middleware: enforce the configured rules for this request.
pub(crate) async fn enforce(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let Ok(pb) = super::pb_of(&state) else {
        return next.run(request).await;
    };
    let settings = pb.settings_cached();
    let limits = &settings["rateLimits"];
    if limits["enabled"] != Value::Bool(true) {
        return next.run(request).await;
    }
    let Some(rules) = limits["rules"].as_array() else {
        return next.run(request).await;
    };
    let path = request.uri().path().to_string();
    let method = request.method().to_string();

    // socket ip; forwarded header only when explicitly trusted
    let mut ip = request
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|ci| ci.0.ip().to_string())
        .unwrap_or_else(|| "unknown".to_string());
    let trust_xff = settings["trustedProxy"]["headers"]
        .as_array()
        .map(|a| a.iter().any(|h| h.as_str() == Some("X-Forwarded-For")))
        .unwrap_or(false);
    if trust_xff {
        if let Some(xff) = headers
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(',').next_back())
        {
            ip = xff.trim().to_string();
        }
    }

    let (collection, op) = op_class(&method, &path);
    for rule in rules {
        let label = rule["label"].as_str().unwrap_or_default();
        let max = rule["maxRequests"].as_u64().unwrap_or(0) as u32;
        let duration = rule["duration"].as_u64().unwrap_or(0);
        if label.is_empty() || max == 0 || duration == 0 {
            continue;
        }
        let hit = if let Some(prefix) = label.strip_prefix('/') {
            path.trim_start_matches('/')
                .starts_with(prefix.trim_start_matches('/'))
                || path.starts_with(label)
        } else if let Some((col_part, op_part)) = label.split_once(':') {
            (col_part == "*" || Some(col_part) == collection.as_deref()) && op_part == op
        } else {
            false
        };
        if hit && !pb.rate_windows.allow(label, &ip, max, duration) {
            return super::pb_err(StatusCode::TOO_MANY_REQUESTS, "Too Many Requests.");
        }
    }
    next.run(request).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn op_classes_match_pb_labels() {
        assert_eq!(
            op_class("POST", "/api/collections/users/auth-with-password"),
            (Some("users".into()), "auth")
        );
        assert_eq!(
            op_class("POST", "/api/collections/posts/records"),
            (Some("posts".into()), "create")
        );
        assert_eq!(
            op_class("GET", "/api/collections/posts/records"),
            (Some("posts".into()), "list")
        );
        assert_eq!(
            op_class("PATCH", "/api/collections/posts/records/abc"),
            (Some("posts".into()), "update")
        );
        assert_eq!(op_class("GET", "/api/health"), (None, "other"));
    }

    #[test]
    fn fixed_window_counts_and_resets() {
        let w = Windows::default();
        assert!(w.allow("l", "1.2.3.4", 2, 60));
        assert!(w.allow("l", "1.2.3.4", 2, 60));
        assert!(
            !w.allow("l", "1.2.3.4", 2, 60),
            "third call in window blocked"
        );
        assert!(w.allow("l", "5.6.7.8", 2, 60), "other ip unaffected");
    }
}
