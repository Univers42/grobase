/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dynamodb_dial_tests.rs                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 11:45:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 11:45:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! G2 dial-guard tests for DynamoDB (devil C12): every lookup the SDK makes
//! for a new connection is vetted, so a name that passed at open and later
//! points at a denied address gets no connection under enforce; Tenant mounts
//! without static keys are refused.

use crate::dial_guard::scope::{count_accepts, fixed_lookup, recorded_for, DialScope};
use crate::dial_guard::DialGuardMode;
use crate::dynamodb_dial::{DynamoGuard, VettingResolver};
use crate::resolver::{EnvMountResolver, MountResolver, Provenance};
use crate::DynamoEngineAdapter;
use aws_config::{BehaviorVersion, Region, SdkConfig};
use aws_sdk_dynamodb::config::{Builder, Credentials};
use aws_smithy_runtime_api::client::dns::ResolveDns;
use data_plane_core::{CredentialRef, DatabaseMount, EngineAdapter, PoolPolicy};
use std::net::IpAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::mpsc;

fn mount(id: &str, inline: Option<String>) -> DatabaseMount {
    DatabaseMount {
        id: id.into(),
        tenant_id: "t-dial".into(),
        project_id: None,
        engine: "dynamodb".into(),
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

fn tenant_scope(id: &str, mode: DialGuardMode) -> Option<DialScope> {
    DialScope::for_mount(mode, "dynamodb", &mount(id, None), Provenance::Tenant)
}

fn guard(id: &str, mode: DialGuardMode, endpoint: &str) -> DynamoGuard {
    let scope = tenant_scope(id, mode)
        .expect("tenant scope")
        .with_lookup(fixed_lookup);
    DynamoGuard::new(scope, Some(endpoint))
}

#[tokio::test]
async fn dynamodb_resolver_vets_every_lookup_under_enforce() {
    let g = guard("ddb-enf", DialGuardMode::Enforce, "http://db.example:8000");
    let resolver = VettingResolver::of(&g);
    let public: IpAddr = "93.184.216.34".parse().expect("ip");
    for _ in 0..2 {
        let ips = resolver.resolve_dns("db.example").await.expect("public");
        assert_eq!(ips, vec![public]);
        for denied in ["evil.example", "meta.example", "split.example", "supavisor"] {
            assert!(resolver.resolve_dns(denied).await.is_err(), "{denied}");
        }
    }
    let lines = recorded_for("ddb-enf");
    assert_eq!(lines.len(), 8, "{lines:?}");
    assert!(lines.iter().all(|l| l.starts_with("dial_guard deny ")));
    assert!(lines.iter().any(|l| l.contains("class=link_local")));
}

#[tokio::test]
async fn dynamodb_resolver_logs_and_returns_the_records_under_shadow() {
    let g = guard("ddb-sh", DialGuardMode::Shadow, "http://db.example:8000");
    let resolver = VettingResolver::of(&g);
    let ips = resolver.resolve_dns("evil.example").await.expect("shadow");
    assert_eq!(ips, vec!["127.0.0.1".parse::<IpAddr>().expect("ip")]);
    let lines = recorded_for("ddb-sh");
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].starts_with("dial_guard would_deny engine=dynamodb "));
    assert!(lines[0].contains("class=loopback ip=127.0.0.1 port=8000"));
}

/// Dials `http://evil.example:<port>` (127.0.0.1 through `fixed_lookup`)
/// with the SDK itself and counts what reached the listener.
async fn sdk_connections(id: &str, mode: DialGuardMode) -> usize {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let (tx, mut rx) = mpsc::unbounded_channel();
    count_accepts(listener, "evil", tx);
    let endpoint = format!("http://evil.example:{port}");
    let g = guard(id, mode, &endpoint);
    let conf = SdkConfig::builder()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new("us-east-1"))
        .build();
    let config = Builder::from(&conf)
        .endpoint_url(endpoint)
        .credentials_provider(Credentials::new("a", "b", None, None, "test"))
        .http_client(g.http_client())
        .build();
    let client = aws_sdk_dynamodb::Client::from_conf(config);
    let _ = tokio::time::timeout(Duration::from_secs(3), client.list_tables().send()).await;
    let mut seen = 0;
    while rx.try_recv().is_ok() {
        seen += 1;
    }
    seen
}

#[tokio::test]
async fn dynamodb_sdk_connection_to_a_denied_name_is_refused_under_enforce() {
    assert_eq!(
        sdk_connections("ddb-sdk-enf", DialGuardMode::Enforce).await,
        0
    );
    assert!(
        !recorded_for("ddb-sdk-enf").is_empty(),
        "the refusal is logged"
    );
}

#[tokio::test]
async fn dynamodb_sdk_connection_to_a_denied_name_is_logged_under_shadow() {
    assert!(sdk_connections("ddb-sdk-sh", DialGuardMode::Shadow).await >= 1);
    let lines = recorded_for("ddb-sdk-sh");
    assert!(lines
        .iter()
        .all(|l| l.starts_with("dial_guard would_deny ")));
    assert!(!lines.is_empty(), "the would_deny is logged");
}

// The adapter's own client must carry the vetting resolver: the precheck logs
// once, and every SDK connection after it logs again.
#[tokio::test]
async fn dynamodb_adapter_client_vets_each_connection() {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let (tx, mut rx) = mpsc::unbounded_channel();
    count_accepts(listener, "localhost", tx);
    let id = "ddb-client";
    let scope = tenant_scope(id, DialGuardMode::Shadow);
    let dsn =
        format!("dynamodb://local?endpoint=http://localhost:{port}&access_key=a&secret_key=b");
    let (client, _) = crate::dynamodb::build_client(&dsn, scope)
        .await
        .expect("client");
    assert_eq!(recorded_for(id).len(), 1, "the precheck logs once");
    let _ = tokio::time::timeout(Duration::from_secs(3), client.list_tables().send()).await;
    assert!(rx.try_recv().is_ok(), "shadow still dials");
    let lines = recorded_for(id);
    assert!(
        lines.len() >= 2,
        "the SDK lookup went through the resolver: {lines:?}"
    );
    assert!(
        lines.iter().all(|l| l.contains("class=internal_name")),
        "{lines:?}"
    );
}

async fn assert_refused(adapter: &DynamoEngineAdapter, dsn: &str, class: &str) {
    let err = adapter
        .open_pool(mount("ddb-ad", Some(dsn.into())))
        .await
        .err()
        .expect("refused");
    let want = format!("dial guard: destination class {class}");
    assert!(err.to_string().contains(&want), "{err}");
}

#[tokio::test]
async fn dynamodb_adapter_refuses_tenant_dsns_and_passes_platform() {
    let keys = "access_key=fake&secret_key=fake";
    let json =
        format!(r#"{{"platform-ref":"dynamodb://local?endpoint=http://127.0.0.1:8000&{keys}"}}"#);
    let resolver: Arc<dyn MountResolver> = Arc::new(EnvMountResolver::from_json(&json));
    let enforce =
        DynamoEngineAdapter::new(resolver.clone()).with_dial_guard(DialGuardMode::Enforce);
    let local = |host: &str| format!("dynamodb://local?endpoint=http://{host}:8000&{keys}");
    assert_refused(&enforce, &local("169.254.169.254"), "link_local").await;
    assert_refused(&enforce, &local("127.0.0.1"), "loopback").await;
    assert_refused(&enforce, &local("[::1]"), "loopback").await;
    let no_host = format!("dynamodb://local?endpoint=localhost:8000&{keys}");
    assert_refused(&enforce, &no_host, "unresolved").await;
    assert_refused(
        &enforce,
        "dynamodb://aws?region=us-east-1",
        "default_credentials",
    )
    .await;
    assert!(
        enforce.open_pool(mount("ddb-ad", None)).await.is_ok(),
        "Platform passes"
    );
    let off = DynamoEngineAdapter::new(resolver);
    let tenant = mount("ddb-ad", Some(local("127.0.0.1")));
    assert!(off.open_pool(tenant).await.is_ok(), "off changes nothing");
}

#[tokio::test]
async fn dynamodb_tenant_without_static_keys_is_logged_not_refused_under_shadow() {
    let shadow = DynamoEngineAdapter::new(Arc::new(EnvMountResolver::from_json("{}")))
        .with_dial_guard(DialGuardMode::Shadow);
    let tenant = mount("ddb-nokeys", Some("dynamodb://aws?region=us-east-1".into()));
    assert!(
        shadow.open_pool(tenant).await.is_ok(),
        "shadow refuses nothing"
    );
    let lines = recorded_for("ddb-nokeys");
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].contains("class=default_credentials ip=- port=443 host=\"aws\""));
}

#[tokio::test]
async fn dynamodb_refusal_never_repeats_the_keys() {
    let (ak, sk) = ("canaryak", "Canary-sk_7f3a");
    let dsn =
        format!("dynamodb://local?endpoint=http://127.0.0.1:8000&access_key={ak}&secret_key={sk}");
    let enforce = DynamoEngineAdapter::new(Arc::new(EnvMountResolver::from_json("{}")))
        .with_dial_guard(DialGuardMode::Enforce);
    let err = enforce
        .open_pool(mount("ddb-canary", Some(dsn)))
        .await
        .err()
        .expect("refused");
    let lines = recorded_for("ddb-canary");
    assert!(!lines.is_empty(), "the refusal is logged");
    for text in [err.to_string(), format!("{err:?}")].iter().chain(&lines) {
        for secret in [ak, sk] {
            assert!(!text.contains(secret), "leaked {secret}: {text}");
        }
    }
}
