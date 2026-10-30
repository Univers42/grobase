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

//! G2 dial-guard tests for SQL Server (devil C10): the Routing hop is vetted
//! and pinned like the first one, in both modes, against two real listeners;
//! named instances are refused under enforce.

use super::dial::{DialManager, Guard};
use super::Config;
use crate::dial_guard::scope::{fixed_lookup, recorded_for, DialScope};
use crate::dial_guard::DialGuardMode;
use crate::resolver::{EnvMountResolver, MountResolver, Provenance};
use crate::MssqlEngineAdapter;
use data_plane_core::{CredentialRef, DatabaseMount, EngineAdapter, PoolPolicy};
use futures::future::BoxFuture;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

fn mount(id: &str, inline: Option<String>) -> DatabaseMount {
    DatabaseMount {
        id: id.into(),
        tenant_id: "t-dial".into(),
        project_id: None,
        engine: "mssql".into(),
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

/// `fixed_lookup` plus the host a Routing redirect names.
fn routed_lookup(host: String, port: u16) -> BoxFuture<'static, io::Result<Vec<IpAddr>>> {
    if host == "routed.example" {
        return Box::pin(async { Ok(vec!["93.184.216.35".parse().expect("ip")]) });
    }
    fixed_lookup(host, port)
}

/// Stands in for the network: the two public test addresses land on two
/// loopback listeners, so the test sees which vetted IP was dialled.
fn to_listeners(addr: SocketAddr) -> BoxFuture<'static, io::Result<TcpStream>> {
    let last = match addr.ip() {
        IpAddr::V4(v4) => v4.octets()[3] - 33,
        IpAddr::V6(_) => 0,
    };
    let local = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, last)), addr.port());
    Box::pin(TcpStream::connect(local))
}

fn guard(id: &str, mode: DialGuardMode) -> Guard {
    let scope = DialScope::for_mount(mode, "mssql", &mount(id, None), Provenance::Tenant)
        .expect("tenant scope")
        .with_lookup(routed_lookup);
    Guard::with_dial(scope, to_listeners)
}

fn config(host: &str, port: u16) -> Config {
    let mut config = Config::new();
    config.host(host);
    config.port(port);
    config
}

/// The listener on `127.0.0.<last>` reports `label` for each accept.
async fn listener(last: u8, label: &'static str, tx: mpsc::UnboundedSender<&'static str>) -> u16 {
    let bound = TcpListener::bind((Ipv4Addr::new(127, 0, 0, last), 0))
        .await
        .expect("listener");
    let port = bound.local_addr().expect("addr").port();
    crate::dial_guard::scope::count_accepts(bound, label, tx);
    port
}

/// A TDS stand-in: the first server redirects to `to`, the second accepts.
fn redirect_to(
    to: (&'static str, u16),
) -> impl Fn(Config, TcpStream) -> BoxFuture<'static, tiberius::Result<SocketAddr>> {
    move |_config, tcp| {
        Box::pin(async move {
            let peer = tcp.peer_addr()?;
            if peer.ip() == IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)) {
                return Err(tiberius::error::Error::Routing {
                    host: to.0.into(),
                    port: to.1,
                });
            }
            Ok(peer)
        })
    }
}

/// The next `n` accepts, sorted: the two accept tasks race each other.
async fn accepts(rx: &mut mpsc::UnboundedReceiver<&'static str>, n: usize) -> Vec<&'static str> {
    let mut seen = Vec::with_capacity(n);
    while seen.len() < n {
        let next = tokio::time::timeout(Duration::from_secs(2), rx.recv()).await;
        seen.push(next.expect("an accept").expect("open channel"));
    }
    seen.sort_unstable();
    seen
}

#[tokio::test]
async fn mssql_routing_hop_is_vetted_and_pinned_under_enforce() {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let first = listener(1, "first", tx.clone()).await;
    let second = listener(2, "second", tx).await;
    let guard = guard("mssql-route", DialGuardMode::Enforce);
    let reached = guard
        .connect(
            config("db.example", first),
            redirect_to(("routed.example", second)),
        )
        .await
        .expect("both hops vetted");
    assert_eq!(reached.ip(), IpAddr::V4(Ipv4Addr::new(127, 0, 0, 2)));
    assert_eq!(accepts(&mut rx, 2).await, ["first", "second"]);
}

#[tokio::test]
async fn mssql_routing_to_a_denied_host_is_refused_under_enforce() {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let first = listener(1, "first", tx.clone()).await;
    let second = listener(2, "second", tx).await;
    let enforce = guard("mssql-route-deny", DialGuardMode::Enforce);
    let err = enforce
        .connect(
            config("db.example", first),
            redirect_to(("meta.example", second)),
        )
        .await
        .expect_err("the redirect is refused");
    assert!(err.to_string().contains("class link_local"), "{err}");
    let lines = recorded_for("mssql-route-deny");
    assert!(
        lines[0].starts_with("dial_guard deny engine=mssql "),
        "{lines:?}"
    );
    assert_eq!(accepts(&mut rx, 1).await, ["first"]);
    assert!(rx.try_recv().is_err(), "the denied hop is never dialled");
}

#[tokio::test]
async fn mssql_routing_to_a_denied_host_is_logged_under_shadow() {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let first = listener(1, "first", tx.clone()).await;
    let second = listener(2, "second", tx).await;
    let shadow = guard("mssql-route-shadow", DialGuardMode::Shadow);
    let reached = shadow
        .connect(
            config("127.0.0.1", first),
            redirect_to(("127.0.0.2", second)),
        )
        .await
        .expect("shadow follows the redirect");
    assert_eq!(reached.ip(), IpAddr::V4(Ipv4Addr::new(127, 0, 0, 2)));
    let lines = recorded_for("mssql-route-shadow");
    assert_eq!(lines.len(), 2, "one would_deny per hop: {lines:?}");
    assert!(lines
        .iter()
        .all(|l| l.starts_with("dial_guard would_deny ")));
    assert_eq!(accepts(&mut rx, 2).await, ["first", "second"]);
}

#[tokio::test]
async fn mssql_second_redirect_is_an_error() {
    let (tx, _rx) = mpsc::unbounded_channel();
    let first = listener(1, "first", tx).await;
    let guard = guard("mssql-route-twice", DialGuardMode::Enforce);
    let err = guard
        .connect(
            config("db.example", first),
            redirect_to(("db.example", first)),
        )
        .await
        .expect_err("one hop only");
    assert!(
        matches!(
            err,
            bb8_tiberius::Error::Tiberius(tiberius::error::Error::Routing { .. })
        ),
        "{err}"
    );
}

#[tokio::test]
async fn mssql_named_instance_is_refused_under_enforce() {
    let scope =
        |id: &str, mode| DialScope::for_mount(mode, "mssql", &mount(id, None), Provenance::Tenant);
    let enforce = DialManager::new(
        config("db.example\\SQLEXPRESS", 1433),
        scope("mssql-named", DialGuardMode::Enforce),
    );
    let err = enforce.precheck().await.expect_err("refused");
    assert!(err.to_string().contains("class named_instance"), "{err}");
    let shadow = DialManager::new(
        config("db.example\\SQLEXPRESS", 1433),
        scope("mssql-named-shadow", DialGuardMode::Shadow),
    );
    assert!(shadow.precheck().await.is_ok(), "shadow refuses nothing");
}

async fn assert_refused(adapter: &MssqlEngineAdapter, dsn: &str, class: &str) {
    let err = adapter
        .open_pool(mount("mssql-ad", Some(dsn.into())))
        .await
        .err()
        .expect("refused");
    let want = format!("dial guard: destination class {class}");
    assert!(err.to_string().contains(&want), "{err}");
}

#[tokio::test]
async fn mssql_adapter_refuses_tenant_dsns_and_passes_platform() {
    let json = r#"{"platform-ref":"mssql://sa:pw@127.0.0.1:1433/db"}"#;
    let resolver: Arc<dyn MountResolver> = Arc::new(EnvMountResolver::from_json(json));
    let enforce = MssqlEngineAdapter::new(resolver.clone()).with_dial_guard(DialGuardMode::Enforce);
    assert_refused(
        &enforce,
        "mssql://sa:pw@169.254.169.254:1433/db",
        "link_local",
    )
    .await;
    assert_refused(&enforce, "mssql://sa:pw@127.0.0.1:1433/db", "loopback").await;
    assert!(
        enforce.open_pool(mount("mssql-ad", None)).await.is_ok(),
        "Platform passes"
    );
    let off = MssqlEngineAdapter::new(resolver);
    let tenant = mount("mssql-ad", Some("mssql://sa:pw@127.0.0.1:1433/db".into()));
    assert!(off.open_pool(tenant).await.is_ok(), "off changes nothing");
}

#[tokio::test]
async fn mssql_refusal_never_repeats_the_password() {
    let canary = "Canary-pw_7f3a";
    let dsn = format!("mssql://canaryuser:{canary}@127.0.0.1:1433/db");
    let enforce = MssqlEngineAdapter::new(Arc::new(EnvMountResolver::from_json("{}")))
        .with_dial_guard(DialGuardMode::Enforce);
    let err = enforce
        .open_pool(mount("mssql-canary", Some(dsn)))
        .await
        .err()
        .expect("refused");
    let lines = recorded_for("mssql-canary");
    assert!(!lines.is_empty(), "the refusal is logged");
    for text in [err.to_string(), format!("{err:?}")].iter().chain(&lines) {
        for secret in [canary, "canaryuser"] {
            assert!(!text.contains(secret), "leaked {secret}: {text}");
        }
    }
}
