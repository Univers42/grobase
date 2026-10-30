/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   canary.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 09:10:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! m230: a mount whose DSN carries a canary password, dialled at a refused port,
//! must fail without the canary in the error's Display or Debug — that string is
//! what `tracing::warn!(error = %err)` logs on every request failure.
//!
//! The same harness bounds how long a dead mongo or mssql holds a request: refused,
//! and a listener that completes the handshake then never answers.
//!
//! G2 (ADR 0019): the dial guard's own refusal and its `dial_guard` log line,
//! under shadow and enforce, carry neither the password, the user, the
//! database nor the DSN query.
//!
//! Caveat: one failure per engine (connection refused). An error raised after
//! authentication (a bad query, a TLS handshake) is not exercised here, and the
//! http adapter stops at its SSRF guard: its upstream message is `http/pool.rs`.

use std::sync::Arc;
use std::time::Duration;

use data_plane_core::{
    CredentialRef, DataOperation, DataPlaneError, DatabaseMount, EngineAdapter, PoolPolicy,
    RequestIdentity,
};
use serde_json::json;

use crate::dial_guard::scope::recorded_for;
use crate::dial_guard::DialGuardMode;
use crate::resolver::{EnvMountResolver, MountResolver};

const CANARY: &str = "Canary-pw_7f3a";
/// mssql is the slowest to fail: bb8 retries a refused dial until its 5 s checkout timeout.
const DIAL_BOUND: Duration = Duration::from_secs(10);

fn mount(engine: &str, dsn: String) -> DatabaseMount {
    DatabaseMount {
        id: format!("canary-{engine}"),
        tenant_id: "t".into(),
        project_id: None,
        engine: engine.into(),
        name: "canary".into(),
        credential_ref: CredentialRef {
            provider: "inline".into(),
            reference: "canary".into(),
            version: "1".into(),
        },
        pool_policy: PoolPolicy::default(),
        capability_overrides: None,
        inline_dsn: Some(dsn),
        isolation: None,
        replica_inline_dsn: None,
        read_replica_route: false,
    }
}

fn list_items() -> (DataOperation, RequestIdentity) {
    let op = serde_json::from_value(json!({"op": "list", "resource": "items"})).unwrap();
    let who = serde_json::from_value(json!({"tenant_id": "t", "source": "test"})).unwrap();
    (op, who)
}

fn assert_hidden(engine: &str, stage: &str, err: &DataPlaneError) {
    for text in [err.to_string(), format!("{err:?}")] {
        assert!(!text.contains(CANARY), "{engine} {stage} leaked: {text}");
    }
}

/// Open, then (if the pool is lazy) run one list, each bounded by `DIAL_BOUND`.
async fn dial(engine: &str, adapter: &dyn EngineAdapter, dsn: String) {
    dial_mount(engine, adapter, mount(engine, dsn)).await;
}

async fn dial_mount(engine: &str, adapter: &dyn EngineAdapter, mount: DatabaseMount) {
    let opened = tokio::time::timeout(DIAL_BOUND, adapter.open_pool(mount)).await;
    let pool = match opened.unwrap_or_else(|_| panic!("{engine} open hung")) {
        Err(err) => return assert_hidden(engine, "open", &err),
        Ok(pool) => pool,
    };
    let (op, who) = list_items();
    let ran = tokio::time::timeout(DIAL_BOUND, pool.execute(op, who)).await;
    match ran.unwrap_or_else(|_| panic!("{engine} list hung")) {
        Err(err) => assert_hidden(engine, "list", &err),
        Ok(_) => panic!("{engine} answered on a refused port"),
    }
}

#[tokio::test]
async fn a_refused_dial_never_repeats_the_password() {
    let resolver: Arc<dyn MountResolver> = Arc::new(EnvMountResolver::from_json("{}"));
    let at = "127.0.0.1:1";
    let cases: Vec<(&str, Box<dyn EngineAdapter>, String)> = vec![
        (
            "postgresql",
            Box::new(crate::PostgresEngineAdapter::new(resolver.clone())),
            format!("postgresql://app:{CANARY}@{at}/db"),
        ),
        (
            "mysql",
            Box::new(crate::MysqlEngineAdapter::new(resolver.clone())),
            format!("mysql://app:{CANARY}@{at}/db"),
        ),
        (
            "mongodb",
            Box::new(crate::MongoEngineAdapter::new(resolver.clone())),
            format!("mongodb://app:{CANARY}@{at}/db?serverSelectionTimeoutMS=500&connectTimeoutMS=500"),
        ),
        (
            "redis",
            Box::new(crate::RedisEngineAdapter::new(resolver.clone())),
            format!("redis://:{CANARY}@{at}/0"),
        ),
        (
            "mssql",
            Box::new(crate::MssqlEngineAdapter::new(resolver.clone())),
            format!("mssql://sa:{CANARY}@{at}/db"),
        ),
        (
            "http",
            Box::new(crate::HttpEngineAdapter::new(resolver.clone())),
            format!("http://app:{CANARY}@{at}"),
        ),
        #[cfg(feature = "dynamodb")]
        (
            "dynamodb",
            Box::new(crate::DynamoEngineAdapter::new(resolver.clone())),
            format!(
                "dynamodb://local?region=us-east-1&endpoint=http://{at}&access_key=AKIDCANARY&secret_key={CANARY}"
            ),
        ),
    ];
    let mut dials = tokio::task::JoinSet::new();
    for (engine, adapter, dsn) in cases {
        dials.spawn(async move { dial(engine, adapter.as_ref(), dsn).await });
    }
    while let Some(done) = dials.join_next().await {
        done.unwrap();
    }
}

/// D3 (ADR 0024): the rediss:// error class. A handshake the peer hangs up on and
/// an `#insecure` refusal both end before any AUTH, and neither quotes the URL.
#[tokio::test]
async fn a_tls_refusal_never_repeats_the_password() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let at = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            drop(stream);
        }
    });
    let resolver: Arc<dyn MountResolver> = Arc::new(EnvMountResolver::from_json("{}"));
    let adapter = crate::RedisEngineAdapter::new(resolver);
    for dsn in [
        format!("rediss://:{CANARY}@{at}/0"),
        format!("rediss://:{CANARY}@{at}/0#insecure"),
    ] {
        dial("redis", &adapter, dsn).await;
    }
}

#[tokio::test]
async fn a_dial_guard_refusal_never_repeats_the_password() {
    let resolver: Arc<dyn MountResolver> = Arc::new(EnvMountResolver::from_json("{}"));
    let at = "127.0.0.1:1";
    for (mode, verdict) in [
        (DialGuardMode::Shadow, "would_deny"),
        (DialGuardMode::Enforce, "deny"),
    ] {
        let cases: Vec<(&str, Box<dyn EngineAdapter>, String)> = vec![
            (
                "postgresql",
                Box::new(crate::PostgresEngineAdapter::new(resolver.clone()).with_dial_guard(mode)),
                format!("postgresql://canaryuser:{CANARY}@{at}/canarydb?application_name=QSECRET"),
            ),
            (
                "mysql",
                Box::new(crate::MysqlEngineAdapter::new(resolver.clone()).with_dial_guard(mode)),
                format!("mysql://canaryuser:{CANARY}@{at}/canarydb?tcp_nodelay=true"),
            ),
        ];
        for (engine, adapter, dsn) in cases {
            let id = format!("canary-guard-{engine}-{verdict}");
            let mut guarded = mount(engine, dsn);
            guarded.id.clone_from(&id);
            dial_mount(engine, adapter.as_ref(), guarded).await;
            let lines = recorded_for(&id);
            assert!(!lines.is_empty(), "{engine} {verdict}: no dial_guard line");
            for line in &lines {
                assert!(
                    line.starts_with(&format!("dial_guard {verdict} ")),
                    "{line}"
                );
                for secret in [CANARY, "canaryuser", "canarydb", "QSECRET", "tcp_nodelay"] {
                    assert!(
                        !line.contains(secret),
                        "{engine} {verdict} leaked {secret}: {line}"
                    );
                }
            }
        }
    }
}

/// One open + list against `at`, returning how long the failure took.
async fn failure_time(engine: &str, adapter: &dyn EngineAdapter, dsn: String) -> Duration {
    let started = std::time::Instant::now();
    dial(engine, adapter, dsn).await;
    started.elapsed()
}

#[tokio::test]
async fn a_dead_mongo_or_mssql_fails_within_six_seconds() {
    let resolver: Arc<dyn MountResolver> = Arc::new(EnvMountResolver::from_json("{}"));
    // Bound but never accepted: the kernel completes the handshake, nothing answers.
    let silent = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let silent_at = silent.local_addr().unwrap().to_string();
    let mongo = crate::MongoEngineAdapter::new(resolver.clone());
    let mssql = crate::MssqlEngineAdapter::new(resolver);
    for at in ["127.0.0.1:1", silent_at.as_str()] {
        // No serverSelectionTimeoutMS: the 5 s default is what is measured.
        let (m, s) = tokio::join!(
            failure_time("mongodb", &mongo, format!("mongodb://app:{CANARY}@{at}/db")),
            failure_time("mssql", &mssql, format!("mssql://sa:{CANARY}@{at}/db")),
        );
        for (engine, took) in [("mongodb", m), ("mssql", s)] {
            assert!(
                took < Duration::from_secs(6),
                "{engine} at {at} took {took:?}"
            );
        }
    }
    drop(silent);
}
