/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   caller_policy_router_tests.rs                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 16:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 16:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! D1 (ADR 0023) against the real `router()`: every route under each class's
//! key, the rotation window, `off` parity, and K5 — a refused inline DSN is
//! never dialled (a recording listener counts the connects).

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use data_plane_pool::service_auth::compute_service_auth;

use super::caller_keys::{CallerPolicy, CallerPolicyMode};
use super::caller_policy::ROUTE_POLICY;
use super::state::AppState;
use super::{probe, router, CallerClass, InboundAuth, InboundAuthMode};
use crate::config::ServerConfig;

const LEGACY: &str = "legacy-shared-token-0123456789abcdef";
const QR: &str = "query-router-key-0123456789abcdef0123";
const QR_PREV: &str = "query-router-prev-0123456789abcdef01";
const TC: &str = "tenant-control-key-0123456789abcdef01";
const TC_PREV: &str = "tenant-control-prev-0123456789abcdef";

fn key_of(class: CallerClass) -> &'static str {
    match class {
        CallerClass::QueryRouter => QR,
        CallerClass::TenantControl => TC,
        CallerClass::Legacy => LEGACY,
    }
}

async fn serve(policy: CallerPolicyMode, inbound: InboundAuthMode, legacy: &str) -> String {
    let mut config = ServerConfig::from_env();
    config.internal_service_token = legacy.into();
    config.inbound_auth = InboundAuth {
        mode: inbound,
        hmac: true,
        prev_token: String::new(),
        skew_secs: 120,
    };
    config.caller_policy = CallerPolicy {
        mode: policy,
        query_router: QR.into(),
        query_router_prev: QR_PREV.into(),
        tenant_control: TC.into(),
        tenant_control_prev: TC_PREV.into(),
    };
    let app = router(AppState::new(config));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    tokio::spawn(async move { axum::serve(listener, app).await });
    format!("http://{addr}")
}

async fn enforced() -> String {
    serve(CallerPolicyMode::Enforce, InboundAuthMode::Off, LEGACY).await
}

/// `key` empty sends no signature.
async fn post(base: &str, path: &str, key: &str, body: &str) -> u16 {
    let mut req = reqwest::Client::new().post(format!("{base}{path}"));
    if !key.is_empty() {
        let signature = compute_service_auth(key, "POST", path, body.as_bytes());
        req = req.header("x-service-auth", signature);
    }
    let req = req
        .header("content-type", "application/json")
        .body(body.to_owned());
    req.send().await.expect("send").status().as_u16()
}

#[tokio::test]
async fn k4_every_route_answers_its_class_and_refuses_the_others() {
    let base = enforced().await;
    for row in ROUTE_POLICY {
        if row.route == "/v1/probe" && !probe::enabled() {
            continue;
        }
        let path = row.route.replace(":tx_id", "tx-d1");
        for class in [
            CallerClass::QueryRouter,
            CallerClass::TenantControl,
            CallerClass::Legacy,
        ] {
            let status = post(&base, &path, key_of(class), "{}").await;
            if class == row.class {
                assert!(
                    ![401, 403].contains(&status),
                    "{path} refused {class:?}: {status}"
                );
            } else {
                assert_eq!(status, 403, "{path} served {class:?}");
            }
        }
        assert_eq!(post(&base, &path, "", "{}").await, 401, "{path} unsigned");
    }
}

#[tokio::test]
async fn k9_the_prev_key_of_each_caller_still_verifies() {
    let base = enforced().await;
    assert!(![401, 403].contains(&post(&base, "/v1/query", QR_PREV, "{}").await));
    assert!(![401, 403].contains(&post(&base, "/v1/admin/migrate", TC_PREV, "{}").await));
    assert_eq!(post(&base, "/v1/admin/migrate", QR_PREV, "{}").await, 403);
}

#[tokio::test]
async fn k1_off_judges_no_class_and_caller_keys_only_add_to_g1a() {
    let off = serve(CallerPolicyMode::Off, InboundAuthMode::Off, LEGACY).await;
    assert!(![401, 403].contains(&post(&off, "/v1/admin/raw", "", "{}").await));
    assert!(![401, 403].contains(&post(&off, "/v1/query", LEGACY, "{}").await));
    let g1a = serve(CallerPolicyMode::Off, InboundAuthMode::Enforce, "").await;
    assert_eq!(post(&g1a, "/v1/query", "", "{}").await, 401);
    assert!(![401, 403].contains(&post(&g1a, "/v1/query", QR, "{}").await));
}

#[tokio::test]
async fn k7_shadow_serves_what_enforce_refuses() {
    let base = serve(CallerPolicyMode::Shadow, InboundAuthMode::Off, LEGACY).await;
    assert!(![401, 403].contains(&post(&base, "/v1/query", LEGACY, "{}").await));
    assert!(![401, 403].contains(&post(&base, "/v1/admin/raw", QR, "{}").await));
}

/// Accepts and drops every connection, counting them.
async fn recording_listener() -> (u16, Arc<AtomicUsize>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let connects = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&connects);
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            counter.fetch_add(1, Ordering::SeqCst);
            drop(stream);
        }
    });
    (port, connects)
}

/// The mount id follows the port: the registry keys pools by mount, so a
/// second listener behind a reused id would never be dialled.
fn inline_body(port: u16, tail: &str) -> String {
    format!(
        r#"{{"identity":{{"tenant_id":"t1","user_id":"u1","roles":["service_role"],"source":"service_token"}},"mount":{{"id":"m{port}","tenant_id":"t1","engine":"postgresql","name":"db","credential_ref":{{"provider":"inline","reference":"db","version":"1"}},"inline_dsn":"postgres://u:p@127.0.0.1:{port}/db"}},{tail}}}"#
    )
}

const QUERY_TAIL: &str = r#""operation":{"op":"list","resource":"items"}"#;
const MIGRATE_TAIL: &str = r#""name":"d1","statements":["select 1"]"#;
const RAW_TAIL: &str = r#""sql":"select 1""#;

async fn connects_after(connects: &AtomicUsize) -> usize {
    tokio::time::sleep(Duration::from_millis(300)).await;
    connects.load(Ordering::SeqCst)
}

#[tokio::test]
async fn k5_a_refused_inline_dsn_is_never_dialled() {
    let base = enforced().await;
    let (port, connects) = recording_listener().await;
    let query = inline_body(port, QUERY_TAIL);
    assert_eq!(post(&base, "/v1/query", TC, &query).await, 403);
    assert_eq!(post(&base, "/v1/query", LEGACY, &query).await, 403);
    assert_eq!(
        post(&base, "/v1/admin/raw", TC, &inline_body(port, RAW_TAIL)).await,
        403
    );
    let migrate = inline_body(port, MIGRATE_TAIL);
    assert_eq!(post(&base, "/v1/admin/migrate", QR, &migrate).await, 403);
    assert_eq!(connects_after(&connects).await, 0, "a refused call dialled");
}

// Positive control: the same listener does see a dial from an allowed class,
// so the zero above is a refusal and not a harness that cannot count. The
// nano/one editions ship no postgres adapter, so nothing dials there.
#[cfg(feature = "postgres")]
#[tokio::test]
async fn k5_an_allowed_class_does_dial_its_inline_dsn() {
    let base = enforced().await;
    let (port, connects) = recording_listener().await;
    let query = inline_body(port, QUERY_TAIL);
    assert!(![401, 403].contains(&post(&base, "/v1/query", QR, &query).await));
    assert!(
        connects_after(&connects).await >= 1,
        "query-router did not dial"
    );
    let (port, connects) = recording_listener().await;
    let migrate = inline_body(port, MIGRATE_TAIL);
    let status = post(&base, "/v1/admin/migrate", TC, &migrate).await;
    assert!(![401, 403].contains(&status), "migrate refused: {status}");
    let dials = connects_after(&connects).await;
    assert!(dials >= 1, "tenant-control did not dial (status {status})");
}
