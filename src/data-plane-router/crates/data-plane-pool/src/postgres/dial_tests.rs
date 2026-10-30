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

//! G2 dial-guard tests for pgwire: C1 driver-parsed config, C2 every host and
//! hostaddr, C3 the pooler repoint, C4 a fresh resolve at every physical dial.

use super::conn::repoint_dsn_host;
use super::dial::{guard_for, GuardedConnect, PgDialGuard};
use crate::dial_guard::classify::DenyClass;
use crate::dial_guard::scope::{count_accepts, fixed_lookup, recorded_for, DialScope, Refusal};
use crate::dial_guard::DialGuardMode;
use crate::resolver::{EnvMountResolver, MountResolver, Provenance};
use crate::PostgresEngineAdapter;
use data_plane_core::{CredentialRef, DatabaseMount, EngineAdapter, PoolPolicy};
use deadpool_postgres::{ConfigConnectImpl, Connect};
use futures::future::BoxFuture;
use std::io;
use std::net::IpAddr;
use std::str::FromStr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_postgres::{Config as PgConfig, NoTls};

fn mount(id: &str, inline: Option<String>) -> DatabaseMount {
    DatabaseMount {
        id: id.into(),
        tenant_id: "t-dial".into(),
        project_id: None,
        engine: "postgresql".into(),
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

fn guard(id: &str, mode: DialGuardMode, pooler: Option<&str>) -> PgDialGuard {
    let scope = DialScope::for_mount(mode, "postgresql", &mount(id, None), Provenance::Tenant)
        .expect("tenant scope")
        .with_lookup(fixed_lookup);
    PgDialGuard::new(scope, pooler)
}

async fn plan(guard: &PgDialGuard, dsn: &str) -> (PgConfig, Vec<Refusal>) {
    guard.plan(&PgConfig::from_str(dsn).expect("dsn")).await
}

fn classes(refusals: &[Refusal]) -> Vec<DenyClass> {
    refusals.iter().map(|r| r.class).collect()
}

#[tokio::test]
async fn pg_plan_pins_one_vetted_hostaddr_per_host() {
    let g = guard("pg-pin", DialGuardMode::Enforce, None);
    let (vetted, refusals) = plan(&g, "postgres://u:pw@db.example:5433/db").await;
    assert!(refusals.is_empty(), "{refusals:?}");
    assert_eq!(
        vetted.get_hostaddrs(),
        ["93.184.216.34".parse::<IpAddr>().unwrap()]
    );
    assert_eq!(vetted.get_ports(), [5433]);
}

#[tokio::test]
async fn pg_enforce_denies_loopback_metadata_and_names_resolving_to_them() {
    let g = guard("pg-deny", DialGuardMode::Enforce, None);
    let cases = [
        ("postgres://u@127.0.0.1/db", DenyClass::Loopback),
        ("postgres://u@169.254.169.254/db", DenyClass::LinkLocal),
        ("postgres://u@evil.example/db", DenyClass::Loopback),
        ("postgres://u@meta.example/db", DenyClass::LinkLocal),
        ("postgres://u@split.example/db", DenyClass::Private),
        ("postgres://u@localhost/db", DenyClass::InternalName),
        ("postgres://u@nxdomain.example/db", DenyClass::Unresolved),
        ("host=/var/run/postgresql user=u", DenyClass::UnixSocket),
    ];
    for (dsn, class) in cases {
        assert_eq!(classes(&plan(&g, dsn).await.1), [class], "{dsn}");
    }
}

#[tokio::test]
async fn pg_every_host_and_tenant_hostaddr_is_classified() {
    let g = guard("pg-c2", DialGuardMode::Enforce, None);
    let (_, r) = plan(&g, "postgres://u@db.example/db?host=10.0.0.5").await;
    assert_eq!(classes(&r), [DenyClass::Private]);
    let (_, r) = plan(&g, "postgres://u@db.example,evil.example/db").await;
    assert_eq!(classes(&r), [DenyClass::Loopback]);
    let dsn = "host=db.example,db.example hostaddr=93.184.216.34,127.0.0.1 user=u";
    let (vetted, r) = plan(&g, dsn).await;
    assert_eq!(classes(&r), [DenyClass::Loopback]);
    assert_eq!(
        vetted.get_hostaddrs().len(),
        2,
        "the tenant list is not extended"
    );
    let (vetted, r) = plan(&g, "postgres://u@db.example,db.example/db").await;
    assert!(r.is_empty());
    assert_eq!(vetted.get_hostaddrs().len(), vetted.get_hosts().len());
}

#[tokio::test]
async fn pg_repointed_dsn_with_tenant_hostaddr_is_denied() {
    let pooler = "postgres://pool@supavisor:6543/postgres";
    let g = guard("pg-c3", DialGuardMode::Enforce, Some(pooler));
    let tenant = "postgres://u:pw@tenant.example:5432/db?hostaddr=127.0.0.1";
    let repointed = repoint_dsn_host(tenant, pooler);
    assert!(repointed.contains("@supavisor:6543/db?hostaddr=127.0.0.1"));
    assert_eq!(
        classes(&plan(&g, &repointed).await.1),
        [DenyClass::Loopback]
    );
    let extra = repoint_dsn_host("postgres://u@t.example/db?host=10.0.0.5", pooler);
    assert_eq!(classes(&plan(&g, &extra).await.1), [DenyClass::Private]);
    let clean = repoint_dsn_host("postgres://u@t.example/db", pooler);
    let (vetted, r) = plan(&g, &clean).await;
    assert!(r.is_empty(), "the exact pooler endpoint passes: {r:?}");
    assert_eq!(
        vetted.get_hostaddrs(),
        ["172.18.0.5".parse::<IpAddr>().unwrap()]
    );
    let other_port = "postgres://u@supavisor:5432/db";
    assert_eq!(classes(&plan(&g, other_port).await.1), [DenyClass::Private]);
}

static FLIPS: AtomicUsize = AtomicUsize::new(0);

fn flipping(_host: String, _port: u16) -> BoxFuture<'static, io::Result<Vec<IpAddr>>> {
    let ip = if FLIPS.fetch_add(1, Ordering::SeqCst) == 0 {
        "127.0.0.1"
    } else {
        "127.0.0.2"
    };
    Box::pin(async move { Ok(vec![ip.parse().expect("ip")]) })
}

#[tokio::test]
async fn pg_each_dial_resolves_again_and_uses_the_new_vetted_ip() {
    let first = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = first.local_addr().unwrap().port();
    let second = TcpListener::bind(("127.0.0.2", port)).await.unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel();
    count_accepts(first, "127.0.0.1", tx.clone());
    count_accepts(second, "127.0.0.2", tx);
    let pooler = format!("postgres://p@pooler.test:{port}/x");
    let scope = DialScope::for_mount(
        DialGuardMode::Enforce,
        "postgresql",
        &mount("pg-c4", None),
        Provenance::Tenant,
    )
    .unwrap()
    .with_lookup(flipping);
    let connect = GuardedConnect {
        inner: ConfigConnectImpl { tls: NoTls },
        guard: Arc::new(PgDialGuard::new(scope, Some(&pooler))),
    };
    let cfg = PgConfig::from_str(&format!("postgres://u@pooler.test:{port}/db")).unwrap();
    for want in ["127.0.0.1", "127.0.0.2"] {
        let dialled = tokio::time::timeout(Duration::from_secs(5), connect.connect(&cfg)).await;
        assert!(
            dialled.expect("dial bounded").is_err(),
            "the fake server drops"
        );
        let got = tokio::time::timeout(Duration::from_secs(2), rx.recv()).await;
        assert_eq!(got.expect("one accept").expect("open channel"), want);
    }
}

async fn guarded_dial(mode: DialGuardMode, id: &str) -> (bool, Vec<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, mut rx) = mpsc::unbounded_channel();
    count_accepts(listener, "local", tx);
    let m = mount(id, None);
    let guard = guard_for(mode, "postgresql", &m, Provenance::Tenant, None).unwrap();
    let connect = GuardedConnect {
        inner: ConfigConnectImpl { tls: NoTls },
        guard,
    };
    let cfg = PgConfig::from_str(&format!("postgres://u:pw@127.0.0.1:{port}/db")).unwrap();
    let dialled = tokio::time::timeout(Duration::from_secs(5), connect.connect(&cfg)).await;
    assert!(dialled.expect("dial bounded").is_err());
    let accepted = tokio::time::timeout(Duration::from_millis(300), rx.recv()).await;
    (accepted.is_ok(), recorded_for(id))
}

#[tokio::test]
async fn pg_shadow_logs_would_deny_and_dials_unchanged() {
    let (accepted, lines) = guarded_dial(DialGuardMode::Shadow, "pg-shadow").await;
    assert!(accepted, "shadow must not change the dial");
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].starts_with("dial_guard would_deny engine=postgresql "));
    assert!(lines[0].contains("provenance=tenant class=loopback ip=127.0.0.1"));
}

#[tokio::test]
async fn pg_enforce_refuses_at_the_physical_dial() {
    let (accepted, lines) = guarded_dial(DialGuardMode::Enforce, "pg-enforce").await;
    assert!(!accepted, "enforce must not open a socket");
    assert!(
        lines[0].starts_with("dial_guard deny engine=postgresql "),
        "{lines:?}"
    );
}

#[tokio::test]
async fn pg_adapter_refuses_tenant_dsns_and_passes_platform() {
    let platform = "postgres://u@127.0.0.1:1/db";
    let json = format!(r#"{{"platform-ref":"{platform}"}}"#);
    let resolver: Arc<dyn MountResolver> = Arc::new(EnvMountResolver::from_json(&json));
    let enforce =
        PostgresEngineAdapter::new(resolver.clone()).with_dial_guard(DialGuardMode::Enforce);
    for (dsn, class) in [
        ("postgres://u@127.0.0.1:1/db", "loopback"),
        ("postgres://u@169.254.169.254/db", "link_local"),
    ] {
        let err = enforce
            .open_pool(mount("pg-ad", Some(dsn.into())))
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
        enforce.open_pool(mount("pg-ad", None)).await.is_ok(),
        "Platform passes"
    );
    let off = PostgresEngineAdapter::new(resolver);
    let tenant = mount("pg-ad", Some(platform.into()));
    assert!(off.open_pool(tenant).await.is_ok(), "off changes nothing");
}
