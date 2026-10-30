/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dial_tests.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 10:57:31 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 10:57:31 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! G2 dial-guard tests for the MySQL wire: C9 driver-parsed `Opts`, a refused
//! `socket=`, and C4 the pinned `resolved_ips` re-vetted while the pool lives.

use super::dial::{pinned_opts, DialPool};
use super::Opts;
use crate::dial_guard::scope::{count_accepts, fixed_lookup, recorded_for, DialScope};
use crate::dial_guard::DialGuardMode;
use crate::resolver::{EnvMountResolver, MountResolver, Provenance};
use crate::MysqlEngineAdapter;
use data_plane_core::{CredentialRef, DatabaseMount, EngineAdapter, PoolPolicy};
use futures::future::BoxFuture;
use std::io;
use std::net::IpAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::mpsc;

fn mount(id: &str, inline: Option<String>) -> DatabaseMount {
    DatabaseMount {
        id: id.into(),
        tenant_id: "t-dial".into(),
        project_id: None,
        engine: "mysql".into(),
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

fn scope(id: &str, mode: DialGuardMode) -> DialScope {
    DialScope::for_mount(mode, "mysql", &mount(id, None), Provenance::Tenant)
        .expect("tenant scope")
        .with_lookup(fixed_lookup)
}

fn opts(url: &str) -> Opts {
    Opts::from_url(url).expect("mysql url")
}

#[tokio::test]
async fn mysql_enforce_denies_loopback_metadata_and_names_resolving_to_them() {
    let cases = [
        ("mysql://u:pw@127.0.0.1:3306/db", "loopback"),
        ("mysql://u:pw@169.254.169.254/db", "link_local"),
        ("mysql://u:pw@evil.example/db", "loopback"),
        ("mysql://u:pw@meta.example/db", "link_local"),
        ("mysql://u:pw@split.example/db", "private"),
        ("mysql://u:pw@localhost/db", "internal_name"),
        ("mysql://u:pw@nxdomain.example/db", "unresolved"),
        (
            "mysql://u:pw@db.example/db?socket=/run/mysqld/mysqld.sock",
            "unix_socket",
        ),
    ];
    for (url, class) in cases {
        let opened =
            DialPool::open(opts(url), Some(scope("my-deny", DialGuardMode::Enforce))).await;
        let err = opened.err().expect("refused");
        let want = format!("mysql dial refused by the dial guard: destination class {class}");
        assert!(err.to_string().contains(&want), "{url}: {err}");
    }
}

/// Opens a guarded pool at a local listener and checks one connection out.
async fn guarded_dial(mode: DialGuardMode, id: &str) -> (bool, bool, Vec<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, mut rx) = mpsc::unbounded_channel();
    count_accepts(listener, "local", tx);
    let url = format!("mysql://u:pw@127.0.0.1:{port}/db");
    let opened = DialPool::open(opts(&url), Some(scope(id, mode))).await;
    let opened_ok = opened.is_ok();
    if let Ok(pool) = opened {
        let conn = tokio::time::timeout(Duration::from_secs(5), pool.get_conn()).await;
        assert!(
            conn.expect("checkout bounded").is_err(),
            "the fake server drops"
        );
    }
    let accepted = tokio::time::timeout(Duration::from_millis(300), rx.recv()).await;
    (opened_ok, accepted.is_ok(), recorded_for(id))
}

#[tokio::test]
async fn mysql_shadow_logs_would_deny_and_dials_unchanged() {
    let (opened, accepted, lines) = guarded_dial(DialGuardMode::Shadow, "my-shadow").await;
    assert!(opened && accepted, "shadow must not change the dial");
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].starts_with("dial_guard would_deny engine=mysql "));
    assert!(lines[0].contains("provenance=tenant class=loopback ip=127.0.0.1"));
}

#[tokio::test]
async fn mysql_enforce_refuses_before_any_socket() {
    let (opened, accepted, lines) = guarded_dial(DialGuardMode::Enforce, "my-enforce").await;
    assert!(!opened && !accepted, "enforce must not open a socket");
    assert!(
        lines[0].starts_with("dial_guard deny engine=mysql "),
        "{lines:?}"
    );
}

#[tokio::test]
async fn mysql_pinned_opts_dial_only_the_vetted_ip() {
    let decoy = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = decoy.local_addr().unwrap().port();
    let vetted = TcpListener::bind(("127.0.0.2", port)).await.unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel();
    count_accepts(decoy, "127.0.0.1", tx.clone());
    count_accepts(vetted, "127.0.0.2", tx);
    let base = opts(&format!("mysql://u:pw@127.0.0.1:{port}/db"));
    let ip: IpAddr = "127.0.0.2".parse().unwrap();
    let pinned = pinned_opts(&base, &[ip]);
    assert_eq!(pinned.resolved_ips().as_deref(), Some(&[ip][..]));
    assert!(
        !pinned.prefer_socket(),
        "a loopback TCP connect must not hop to a socket"
    );
    let pool = mysql_async::Pool::new(pinned);
    let conn = tokio::time::timeout(Duration::from_secs(5), pool.get_conn()).await;
    assert!(
        conn.expect("checkout bounded").is_err(),
        "the fake server drops"
    );
    let got = tokio::time::timeout(Duration::from_secs(2), rx.recv()).await;
    assert_eq!(got.expect("one accept").expect("open channel"), "127.0.0.2");
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

#[tokio::test]
async fn mysql_revet_moves_the_pin_to_the_new_vetted_ip() {
    let scope = scope("my-c4", DialGuardMode::Enforce).with_lookup(flipping);
    let pool = DialPool::open(opts("mysql://u:pw@db.example/db"), Some(scope))
        .await
        .unwrap();
    assert_eq!(
        pool.pinned_ips(),
        ["93.184.216.34".parse::<IpAddr>().unwrap()]
    );
    pool.revet_now().await.unwrap();
    assert_eq!(
        pool.pinned_ips(),
        ["93.184.216.35".parse::<IpAddr>().unwrap()]
    );
}

#[tokio::test]
async fn mysql_adapter_refuses_tenant_dsns_and_passes_platform() {
    let platform = "mysql://u@127.0.0.1:1/db";
    let json = format!(r#"{{"platform-ref":"{platform}"}}"#);
    let resolver: Arc<dyn MountResolver> = Arc::new(EnvMountResolver::from_json(&json));
    let enforce = MysqlEngineAdapter::new(resolver.clone()).with_dial_guard(DialGuardMode::Enforce);
    for (dsn, class) in [
        ("mysql://u@127.0.0.1:1/db", "loopback"),
        ("mysql://u@169.254.169.254/db", "link_local"),
    ] {
        let err = enforce
            .open_pool(mount("my-ad", Some(dsn.into())))
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
        enforce.open_pool(mount("my-ad", None)).await.is_ok(),
        "Platform passes"
    );
    let off = MysqlEngineAdapter::new(resolver);
    let tenant = mount("my-ad", Some(platform.into()));
    assert!(off.open_pool(tenant).await.is_ok(), "off changes nothing");
}
