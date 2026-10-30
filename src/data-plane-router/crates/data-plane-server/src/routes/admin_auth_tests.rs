/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   admin_auth_tests.rs                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 12:55:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 12:55:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! m243 (G1, ADR 0007) against the real `router()`, not an echo route: the
//! admin routes sit behind the service-auth layer in `enforce`, so a caller
//! without `INTERNAL_SERVICE_TOKEN` — an edge function, a container on the
//! network — gets 401 before any handler runs. `inbound_auth.rs` tests the
//! layer itself; this proves the routes are wired under it.

use super::router;
use super::state::AppState;
use crate::config::ServerConfig;
use crate::routes::{InboundAuth, InboundAuthMode};
use data_plane_pool::service_auth::compute_service_auth;

const TOKEN: &str = "m243-test-token";
const ADMIN_ROUTES: [&str; 4] = [
    "/v1/admin/raw",
    "/v1/admin/migrate",
    "/v1/admin/rotate",
    "/v1/admin/evict-verify",
];
const RAW_BODY: &[u8] = br#"{"identity":{"tenant_id":"t1"},"sql":"select 1"}"#;

async fn serve_enforced() -> String {
    let mut config = ServerConfig::from_env();
    config.internal_service_token = TOKEN.into();
    config.inbound_auth = InboundAuth {
        mode: InboundAuthMode::Enforce,
        hmac: true,
        prev_token: String::new(),
        skew_secs: 120,
    };
    let app = router(AppState::new(config));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    tokio::spawn(async move { axum::serve(listener, app).await });
    format!("http://{addr}")
}

async fn post_status(url: &str, signature: Option<String>, body: &[u8]) -> u16 {
    let mut req = reqwest::Client::new().post(url).body(body.to_vec());
    if let Some(sig) = signature {
        req = req.header("x-service-auth", sig);
    }
    req.send().await.expect("send").status().as_u16()
}

#[tokio::test]
async fn m243_unsigned_admin_routes_are_401() {
    let base = serve_enforced().await;
    for route in ADMIN_ROUTES {
        let status = post_status(&format!("{base}{route}"), None, RAW_BODY).await;
        assert_eq!(status, 401, "{route} served an unsigned call");
    }
}

#[tokio::test]
async fn m243_a_plain_token_or_a_signature_for_another_body_is_401() {
    let base = serve_enforced().await;
    let url = format!("{base}/v1/admin/raw");
    let plain = reqwest::Client::new()
        .post(&url)
        .header("x-service-token", TOKEN)
        .body(RAW_BODY.to_vec())
        .send()
        .await
        .expect("send");
    assert_eq!(plain.status().as_u16(), 401, "hmac mode took a plain token");
    let other = compute_service_auth(TOKEN, "POST", "/v1/admin/raw", b"{}");
    assert_eq!(post_status(&url, Some(other), RAW_BODY).await, 401);
}

// The handler answers whatever it answers for an unresolvable mount; the
// point is that the layer let a correctly signed call through.
#[tokio::test]
async fn m243_a_signed_admin_call_reaches_the_handler() {
    let base = serve_enforced().await;
    let sig = compute_service_auth(TOKEN, "POST", "/v1/admin/raw", RAW_BODY);
    let status = post_status(&format!("{base}/v1/admin/raw"), Some(sig), RAW_BODY).await;
    assert_ne!(status, 401, "a signed call was refused");
}

#[tokio::test]
async fn m243_health_and_capabilities_stay_open() {
    let base = serve_enforced().await;
    for route in ["/v1/health", "/v1/capabilities"] {
        let resp = reqwest::get(format!("{base}{route}")).await.expect("get");
        assert_eq!(resp.status().as_u16(), 200, "{route} needs no signature");
    }
}
