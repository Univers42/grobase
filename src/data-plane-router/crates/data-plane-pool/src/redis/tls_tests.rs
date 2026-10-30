/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   tls_tests.rs                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 14:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 14:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! R4 (ADR 0024): with `rediss://` now dialable, the dial guard must still refuse
//! it under a scope, and no path may rewrite a TLS address to plaintext TCP.

use super::dial::{pinned_info, plan};
use super::dial_tests::{info, mount, resolver, scope};
use crate::dial_guard::classify::DenyClass;
use crate::dial_guard::scope::recorded_for;
use crate::dial_guard::DialGuardMode;
use crate::RedisEngineAdapter;
use data_plane_core::EngineAdapter;
use std::sync::Arc;
use tokio::io::AsyncReadExt;
use tokio::net::TcpListener;
use tokio::sync::Mutex;

/// A TLS record starts with content type 22 (handshake): what a ClientHello sends.
const TLS_HANDSHAKE: u8 = 0x16;

#[tokio::test]
async fn rediss_under_enforce_is_refused_as_tls_and_never_pinned() {
    let scope = scope("redis-tls-enforce", DialGuardMode::Enforce);
    let parsed = info("rediss://app:pw@db.example:6380/0");
    let refusal = plan(&scope, &parsed).await.expect_err("refused");
    assert_eq!(refusal.class, DenyClass::Tls);
    let ip = "93.184.216.34".parse().expect("ip");
    assert!(
        pinned_info(&parsed, ip).is_err(),
        "a TcpTls address must never become plaintext Tcp"
    );
}

#[tokio::test]
async fn the_adapter_refuses_rediss_under_enforce_with_class_tls() {
    let enforce = RedisEngineAdapter::new(resolver()).with_dial_guard(DialGuardMode::Enforce);
    let dsn = "rediss://app:pw@db.example:6380/0";
    let err = enforce
        .open_pool(mount("redis-tls-adapter", Some(dsn.into())))
        .await
        .err()
        .expect("refused");
    assert!(err.to_string().contains("class tls"), "{err}");
    assert!(!err.to_string().contains("pw"), "{err}");
}

/// The first byte of every connection, then a hang-up so the handshake fails fast.
async fn first_bytes() -> (u16, Arc<Mutex<Vec<u8>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("listener");
    let port = listener.local_addr().expect("addr").port();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink = seen.clone();
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut byte = [0u8; 1];
            if stream.read_exact(&mut byte).await.is_ok() {
                sink.lock().await.push(byte[0]);
            }
        }
    });
    (port, seen)
}

#[tokio::test]
async fn shadow_logs_rediss_and_still_speaks_tls() {
    let (port, seen) = first_bytes().await;
    let shadow = RedisEngineAdapter::new(resolver()).with_dial_guard(DialGuardMode::Shadow);
    let dsn = format!("rediss://127.0.0.1:{port}/0");
    let opened = shadow.open_pool(mount("redis-tls-shadow", Some(dsn))).await;
    assert!(opened.is_err(), "the peer hangs up: no session");
    let lines = recorded_for("redis-tls-shadow");
    assert!(
        lines[0].starts_with("dial_guard would_deny engine=redis ")
            && lines[0].contains("class=tls"),
        "{lines:?}"
    );
    let first = seen.lock().await;
    assert!(!first.is_empty(), "the dial reached the listener");
    assert!(first.iter().all(|b| *b == TLS_HANDSHAKE), "{first:?}");
}
