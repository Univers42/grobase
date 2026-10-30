/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   canary.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! m230: a mount whose DSN carries a canary password, dialled at a refused port,
//! must fail without the canary in the error's Display or Debug — that string is
//! what `tracing::warn!(error = %err)` logs on every request failure.
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

use crate::resolver::{EnvMountResolver, MountResolver};

const CANARY: &str = "Canary-pw_7f3a";
/// mssql is the slowest to fail: bb8 retries a refused dial until its 30 s checkout timeout.
const DIAL_BOUND: Duration = Duration::from_secs(45);

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
        // mongo's server-selection timeout is max(idle_ttl_ms, 5 s): 30 s by default.
        pool_policy: PoolPolicy {
            idle_ttl_ms: 1,
            ..PoolPolicy::default()
        },
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
    let opened = tokio::time::timeout(DIAL_BOUND, adapter.open_pool(mount(engine, dsn))).await;
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
