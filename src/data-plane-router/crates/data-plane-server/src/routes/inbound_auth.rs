/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   inbound_auth.rs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/29 21:11:50 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 16:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! G1a — the internal `/v1/*` routes accept only signed service calls.
//!
//! Until now anything that could reach port 4011 could run `/v1/query` or
//! `/v1/admin/raw` with a self-declared identity. This layer verifies the same
//! `X-Service-Token` / v1 `X-Service-Auth` scheme the Go control plane checks
//! (`serviceauth.Verify`). `DATA_PLANE_INBOUND_AUTH` rolls it out: `off` (the
//! default, byte-parity, the body is never buffered), `shadow` (log
//! `would_deny`, serve anyway) and `enforce` (answer 401). Health, metrics,
//! capabilities and the API-key `/data/v1` bypass stay outside the layer.

use axum::body::Body;
use axum::extract::{MatchedPath, Request, State};
use axum::http::request::Parts;
use axum::http::StatusCode;
use axum::middleware::Next;
use axum::response::Response;
use data_plane_pool::service_auth::{
    hmac_mode, prev_service_token, service_auth_skew, ServiceAuthDenial, SignedRequest,
};

use super::caller_keys::{CallerClass, CallerPolicyMode};
use super::caller_policy;
use super::helpers::api_err;
use super::state::AppState;

pub(crate) const INBOUND_AUTH_KEY: &str = "DATA_PLANE_INBOUND_AUTH";

/// The signature covers the whole body, so it must be buffered. 2 MiB is axum's
/// default extractor limit: every handler behind this layer already refuses a
/// larger body, so the cap rejects nothing that used to be served.
const MAX_SIGNED_BODY: usize = 2 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum InboundAuthMode {
    #[default]
    Off,
    Shadow,
    Enforce,
}

impl InboundAuthMode {
    /// `None` for a value outside `off|shadow|enforce` (empty means `off`).
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "" | "off" => Some(Self::Off),
            "shadow" => Some(Self::Shadow),
            "enforce" => Some(Self::Enforce),
            _ => None,
        }
    }
}

/// Read once at startup so the request path never touches the environment.
#[derive(Clone, Default)]
pub struct InboundAuth {
    pub mode: InboundAuthMode,
    pub hmac: bool,
    pub prev_token: String,
    pub skew_secs: i64,
}

impl InboundAuth {
    /// An unknown mode reads as `off` here; `ServerConfig::try_from_env` refuses it.
    #[must_use]
    pub fn from_env() -> Self {
        let raw = std::env::var(INBOUND_AUTH_KEY).unwrap_or_default();
        Self {
            mode: InboundAuthMode::parse(&raw).unwrap_or_default(),
            hmac: hmac_mode(),
            prev_token: prev_service_token(),
            skew_secs: service_auth_skew(),
        }
    }
}

impl std::fmt::Debug for InboundAuth {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InboundAuth")
            .field("mode", &self.mode)
            .field("hmac", &self.hmac)
            .field("prev_token_set", &!self.prev_token.is_empty())
            .field("skew_secs", &self.skew_secs)
            .finish()
    }
}

pub(super) fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

/// One verification serves both rollouts: G1a asks "did any service key
/// verify", D1 (`caller_policy.rs`) asks "which class, on which route". With
/// both off the body is never buffered. Logs carry the route template, the
/// class and the denial reason only — never the body, the signature or a key.
///
/// Caveat: a body that fails to read for another reason (client hang-up, a
/// broken chunked stream) is also answered 413, in every mode but `off`.
pub(super) async fn require_service_auth(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    let (auth, policy) = (&state.config.inbound_auth, &state.config.caller_policy);
    if auth.mode == InboundAuthMode::Off && policy.mode == CallerPolicyMode::Off {
        return next.run(request).await;
    }
    let (parts, body) = request.into_parts();
    let Ok(bytes) = axum::body::to_bytes(body, MAX_SIGNED_BODY).await else {
        return api_err(
            StatusCode::PAYLOAD_TOO_LARGE,
            "payload_too_large",
            "request body exceeds 2 MiB",
        );
    };
    if let Some(refused) = refusal(&state, &parts, &bytes) {
        return refused;
    }
    next.run(Request::from_parts(parts, Body::from(bytes)))
        .await
}

/// The class is identified once and judged by both rollouts, G1a first.
fn refusal(state: &AppState, parts: &Parts, body: &[u8]) -> Option<Response> {
    let (auth, policy) = (&state.config.inbound_auth, &state.config.caller_policy);
    let signed = SignedRequest {
        method: parts.method.as_str(),
        path: parts.uri.path(),
        body,
    };
    let header = |name: &str| parts.headers.get(name).and_then(|v| v.to_str().ok());
    let class = policy.identify(&state.config.internal_service_token, auth, header, &signed);
    let route = parts
        .extensions
        .get::<MatchedPath>()
        .map_or("unmatched", MatchedPath::as_str);
    inbound_verdict(auth.mode, route, &class)
        .or_else(|| caller_policy::verdict(policy.mode, route, &class, body))
}

/// G1a: any key verifying is enough; `Some(401)` only under enforce.
fn inbound_verdict(
    mode: InboundAuthMode,
    route: &str,
    class: &Result<CallerClass, ServiceAuthDenial>,
) -> Option<Response> {
    let Err(denial) = class else { return None };
    let reason = denial.as_str();
    match mode {
        InboundAuthMode::Off => None,
        InboundAuthMode::Shadow => {
            tracing::warn!(target: "inbound_auth", route, outcome = "would_deny", reason);
            None
        }
        InboundAuthMode::Enforce => {
            tracing::warn!(target: "inbound_auth", route, outcome = "deny", reason);
            Some(api_err(
                StatusCode::UNAUTHORIZED,
                "service_auth_required",
                "this route accepts signed service calls only",
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ServerConfig;
    use axum::routing::post;
    use axum::Router;
    use data_plane_pool::service_auth::compute_service_auth;

    const TOKEN: &str = "inbound-test-token";

    #[test]
    fn mode_parses_the_three_values_and_refuses_the_rest() {
        assert_eq!(InboundAuthMode::parse(""), Some(InboundAuthMode::Off));
        assert_eq!(InboundAuthMode::parse(" OFF "), Some(InboundAuthMode::Off));
        assert_eq!(
            InboundAuthMode::parse("shadow"),
            Some(InboundAuthMode::Shadow)
        );
        assert_eq!(
            InboundAuthMode::parse("Enforce"),
            Some(InboundAuthMode::Enforce)
        );
        assert_eq!(InboundAuthMode::parse("enforced"), None);
        assert_eq!(InboundAuthMode::parse("1"), None);
    }

    #[test]
    fn debug_never_prints_the_previous_token() {
        let auth = InboundAuth {
            prev_token: "prev-SECRET".into(),
            ..InboundAuth::default()
        };
        assert!(!format!("{auth:?}").contains("prev-SECRET"));
    }

    /// One echo route behind the layer, served on a loopback port, so the test
    /// goes through axum's real routing (MatchedPath) and body handling.
    async fn serve(mode: InboundAuthMode, hmac: bool) -> String {
        let mut config = ServerConfig::from_env();
        config.internal_service_token = TOKEN.into();
        config.inbound_auth = InboundAuth {
            mode,
            hmac,
            prev_token: String::new(),
            skew_secs: 120,
        };
        let state = AppState::new(config);
        let app = Router::new()
            .route("/v1/query", post(|body: String| async move { body }))
            .route_layer(axum::middleware::from_fn_with_state(
                state.clone(),
                require_service_auth,
            ))
            .with_state(state);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind");
        let addr = listener.local_addr().expect("addr");
        tokio::spawn(async move { axum::serve(listener, app).await });
        format!("http://{addr}/v1/query")
    }

    async fn post_to(url: &str, headers: &[(&str, String)], body: Vec<u8>) -> (u16, String) {
        let mut req = reqwest::Client::new().post(url).body(body);
        for (k, v) in headers {
            req = req.header(*k, v);
        }
        let resp = req.send().await.expect("send");
        let status = resp.status().as_u16();
        (status, resp.text().await.expect("text"))
    }

    #[tokio::test]
    async fn off_serves_an_unsigned_call() {
        let url = serve(InboundAuthMode::Off, true).await;
        assert_eq!(post_to(&url, &[], b"x".to_vec()).await, (200, "x".into()));
    }

    #[tokio::test]
    async fn shadow_serves_an_unsigned_call() {
        let url = serve(InboundAuthMode::Shadow, true).await;
        assert_eq!(post_to(&url, &[], b"x".to_vec()).await, (200, "x".into()));
    }

    #[tokio::test]
    async fn enforce_refuses_unsigned_and_wrong_body_and_serves_signed() {
        let url = serve(InboundAuthMode::Enforce, true).await;
        assert_eq!(post_to(&url, &[], b"{}".to_vec()).await.0, 401);

        let sig = compute_service_auth(TOKEN, "POST", "/v1/query", b"{\"a\":1}");
        let headers = [("x-service-auth", sig)];
        let tampered = post_to(&url, &headers, b"{\"a\":2}".to_vec()).await;
        assert_eq!(tampered.0, 401, "signature bound to another body");

        let signed = post_to(&url, &headers, b"{\"a\":1}".to_vec()).await;
        assert_eq!(
            signed,
            (200, "{\"a\":1}".into()),
            "body reaches the handler intact"
        );
    }

    #[tokio::test]
    async fn enforce_static_mode_checks_the_plain_token() {
        let url = serve(InboundAuthMode::Enforce, false).await;
        let wrong = [("x-service-token", "nope".to_string())];
        assert_eq!(post_to(&url, &wrong, b"x".to_vec()).await.0, 401);
        let right = [("x-service-token", TOKEN.to_string())];
        assert_eq!(post_to(&url, &right, b"x".to_vec()).await.0, 200);
    }

    #[tokio::test]
    async fn a_body_over_2_mib_is_413() {
        let url = serve(InboundAuthMode::Shadow, true).await;
        let body = vec![b'a'; MAX_SIGNED_BODY + 1];
        assert_eq!(post_to(&url, &[], body).await.0, 413);
    }
}
