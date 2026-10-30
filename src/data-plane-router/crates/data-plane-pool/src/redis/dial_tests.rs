/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dial_tests.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 11:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 11:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! G2 dial-guard tests for Redis: C11 the unix refusal, the driver-parsed
//! settings kept while the address is pinned, and the checkout re-vet.

use super::dial::{connect_dsn, plan, DialManager, Fixture};
use crate::dial_guard::scope::{fixed_lookup, recorded_for, DialScope, Lookup};
use crate::dial_guard::DialGuardMode;
use crate::resolver::{EnvMountResolver, MountResolver, Provenance};
use crate::RedisEngineAdapter;
use data_plane_core::{CredentialRef, DatabaseMount, EngineAdapter, PoolPolicy};
use futures::future::BoxFuture;
use redis::{ConnectionAddr, ConnectionInfo, IntoConnectionInfo, ProtocolVersion};
use std::io;
use std::net::IpAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;

pub(super) fn mount(id: &str, inline: Option<String>) -> DatabaseMount {
    DatabaseMount {
        id: id.into(),
        tenant_id: "t-dial".into(),
        project_id: None,
        engine: "redis".into(),
        name: "n".into(),
        credential_ref: CredentialRef {
            provider: "inline".into(),
            reference: "platform-ref".into(),
            version: "1".into(),
        },
        pool_policy: PoolPolicy::default(),
        capability_overrides: None,
        inline_dsn: inline,
        isolation: None,
        replica_inline_dsn: None,
        read_replica_route: false,
    }
}

pub(super) fn scope(id: &str, mode: DialGuardMode) -> DialScope {
    DialScope::for_mount(mode, "redis", &mount(id, None), Provenance::Tenant)
        .expect("tenant scope")
        .with_lookup(fixed_lookup)
}

pub(super) fn info(dsn: &str) -> ConnectionInfo {
    dsn.into_connection_info().expect("redis dsn")
}

pub(super) fn resolver() -> Arc<dyn MountResolver> {
    Arc::new(EnvMountResolver::from_json("{}"))
}

/// A stand-in server: answers `+OK` to every RESP command, which is all the
/// manager's connect handshake (`CLIENT SETINFO`) needs.
fn answer_ok<S>(mut stream: S)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let mut buf = [0u8; 4096];
        while let Ok(n) = stream.read(&mut buf).await {
            let commands = buf[..n]
                .split(|b| *b == b'\n')
                .filter(|l| l.first() == Some(&b'*'));
            let reply = "+OK\r\n".repeat(commands.count());
            if n == 0 || stream.write_all(reply.as_bytes()).await.is_err() {
                return;
            }
        }
    });
}

async fn fake_redis() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("listener");
    let port = listener.local_addr().expect("addr").port();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            answer_ok(stream);
        }
    });
    port
}

#[tokio::test]
async fn redis_adapter_refuses_tenant_dsns_and_passes_platform() {
    let port = fake_redis().await;
    let platform = format!("redis://127.0.0.1:{port}/0");
    let json = format!(r#"{{"platform-ref":"{platform}"}}"#);
    let mount_resolver: Arc<dyn MountResolver> = Arc::new(EnvMountResolver::from_json(&json));
    let enforce =
        RedisEngineAdapter::new(mount_resolver.clone()).with_dial_guard(DialGuardMode::Enforce);
    for (dsn, class) in [
        ("redis://169.254.169.254:6379", "link_local"),
        ("redis://127.0.0.1:6379", "loopback"),
        ("redis+unix:///tmp/r.sock", "unix_socket"),
    ] {
        let err = enforce
            .open_pool(mount("redis-ad", Some(dsn.into())))
            .await
            .err()
            .expect("refused");
        assert!(
            err.to_string()
                .contains(&format!("dial guard: destination class {class}")),
            "{err}"
        );
    }
    assert!(
        enforce.open_pool(mount("redis-ad", None)).await.is_ok(),
        "Platform passes"
    );
    let off = RedisEngineAdapter::new(mount_resolver);
    let tenant = mount("redis-ad", Some(platform));
    assert!(off.open_pool(tenant).await.is_ok(), "off changes nothing");
}

#[cfg(unix)]
#[tokio::test]
async fn redis_unix_socket_is_refused_under_enforce_and_logged_under_shadow() {
    let path = std::env::temp_dir().join(format!("g2-redis-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let listener = tokio::net::UnixListener::bind(&path).expect("unix listener");
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            answer_ok(stream);
        }
    });
    let dsn = format!("redis+unix://{}", path.display());
    let shadow = RedisEngineAdapter::new(resolver()).with_dial_guard(DialGuardMode::Shadow);
    assert!(
        shadow
            .open_pool(mount("redis-unix-shadow", Some(dsn.clone())))
            .await
            .is_ok(),
        "shadow still dials"
    );
    let lines = recorded_for("redis-unix-shadow");
    assert!(
        lines[0].starts_with("dial_guard would_deny engine=redis ")
            && lines[0].contains("class=unix_socket"),
        "{lines:?}"
    );
    let enforce = RedisEngineAdapter::new(resolver()).with_dial_guard(DialGuardMode::Enforce);
    let err = enforce
        .open_pool(mount("redis-unix-enforce", Some(dsn)))
        .await
        .err()
        .expect("refused");
    assert!(err.to_string().contains("class unix_socket"), "{err}");
    assert!(
        recorded_for("redis-unix-enforce")[0].starts_with("dial_guard deny engine=redis "),
        "enforce logs the deny"
    );
    let _ = std::fs::remove_file(&path);
}

#[tokio::test]
async fn redis_pins_the_vetted_ip_not_the_name() {
    let scope = scope("redis-pin", DialGuardMode::Enforce);
    let parsed = info("redis://app:pw@db.example:6380/3?protocol=resp3");
    let pinned = plan(&scope, &parsed)
        .await
        .expect("vetted")
        .expect("plain tcp pins");
    assert_eq!(
        pinned.addr,
        ConnectionAddr::Tcp("93.184.216.34".into(), 6380)
    );
    assert_eq!(pinned.redis.db, 3);
    assert_eq!(pinned.redis.username.as_deref(), Some("app"));
    assert_eq!(pinned.redis.password.as_deref(), Some("pw"));
    assert_eq!(pinned.redis.protocol, ProtocolVersion::RESP3);
}

static FLIPS: AtomicUsize = AtomicUsize::new(0);

fn flipping(_host: String, _port: u16) -> BoxFuture<'static, io::Result<Vec<IpAddr>>> {
    let ip = if FLIPS.fetch_add(1, Ordering::SeqCst) == 0 {
        "93.184.216.34"
    } else {
        "93.184.216.35"
    };
    Box::pin(async move { Ok(vec![ip.parse().expect("ip")]) })
}

async fn guarded(mode: DialGuardMode, lookup: Lookup, revet_after: Duration) -> DialManager {
    let port = fake_redis().await;
    let manager = connect_dsn(&format!("redis://127.0.0.1:{port}/0"))
        .await
        .expect("local manager");
    let fixture = Fixture {
        scope: scope("redis-c4", mode).with_lookup(lookup),
        info: info("redis://u@db.example:6379/0"),
        ip: "93.184.216.34".parse().expect("ip"),
        revet_after,
    };
    DialManager::for_test(manager, fixture)
}

#[tokio::test]
async fn redis_revets_after_the_interval_and_rebuilds_on_change() {
    let dial = guarded(DialGuardMode::Enforce, flipping, Duration::from_secs(3600)).await;
    dial.checkout().await.expect("not due: no lookup");
    assert_eq!(
        FLIPS.load(Ordering::SeqCst),
        0,
        "no re-vet before the interval"
    );
    let same = dial.next_pin_now().await.expect("re-vet");
    assert_eq!(same, None, "an unchanged address keeps the manager");
    let moved = dial.next_pin_now().await.expect("re-vet");
    assert_eq!(
        moved,
        Some("93.184.216.35".parse().expect("ip")),
        "the pin moves"
    );
    assert_eq!(
        dial.pinned_ip(),
        Some("93.184.216.34".parse().expect("ip")),
        "the pin changes only once the new manager is up"
    );
}

fn to_loopback(_host: String, _port: u16) -> BoxFuture<'static, io::Result<Vec<IpAddr>>> {
    Box::pin(async { Ok(vec!["127.0.0.1".parse().expect("ip")]) })
}

#[tokio::test]
async fn redis_checkout_refuses_a_name_that_moved_to_a_denied_address() {
    let dial = guarded(DialGuardMode::Enforce, to_loopback, Duration::ZERO).await;
    let err = dial.checkout().await.err().expect("refused at checkout");
    assert!(err.to_string().contains("loopback"), "{err}");
    let dial = guarded(DialGuardMode::Shadow, to_loopback, Duration::ZERO).await;
    dial.checkout()
        .await
        .expect("shadow logs and keeps serving");
}

#[tokio::test]
async fn redis_refusal_never_repeats_the_password() {
    let canary = "Canary-pw_7f3a";
    let dsn = format!("redis://canaryuser:{canary}@127.0.0.1:6379/3");
    let opened = DialManager::open(&dsn, Some(scope("redis-canary", DialGuardMode::Enforce))).await;
    let err = opened.err().expect("refused");
    for text in [err.to_string(), format!("{err:?}")] {
        for secret in [canary, "canaryuser"] {
            assert!(!text.contains(secret), "leaked {secret}: {text}");
        }
    }
    let lines = recorded_for("redis-canary");
    assert!(!lines.is_empty(), "the refusal is logged");
    for line in lines {
        assert!(line.starts_with("dial_guard deny engine=redis "), "{line}");
        for secret in [canary, "canaryuser"] {
            assert!(!line.contains(secret), "leaked {secret}: {line}");
        }
    }
}
