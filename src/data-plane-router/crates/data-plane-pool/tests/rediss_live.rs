//! R7/R9/R11 (D3, ADR 0024), driven by scripts/verify/m260-redis-client-tls.sh
//! against a redis serving TLS on 6380 with a throwaway CA. Ignored without it.
//! Each case sets the process TLS env first, so m260 runs `--test-threads=1`.
#![cfg(feature = "redis")]

use data_plane_core::{CredentialRef, DatabaseMount, EngineAdapter, PoolPolicy, TlsPosture};
use data_plane_pool::{EnvMountResolver, RedisEngineAdapter};
use std::sync::Arc;

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is set by m260"))
}

fn mount(dsn: String) -> DatabaseMount {
    DatabaseMount {
        id: "m260".into(),
        tenant_id: "t-m260".into(),
        project_id: None,
        engine: "redis".into(),
        name: "m260".into(),
        credential_ref: CredentialRef {
            provider: "inline".into(),
            reference: "m260".into(),
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

/// The adapter's own open + probe, with `DATA_PLANE_TLS_CA_FILE` from `ca`.
async fn open(url: &str, ca: Option<String>) -> Result<TlsPosture, String> {
    match ca {
        Some(path) => std::env::set_var("DATA_PLANE_TLS_CA_FILE", path),
        None => std::env::remove_var("DATA_PLANE_TLS_CA_FILE"),
    }
    let adapter = RedisEngineAdapter::new(Arc::new(EnvMountResolver::from_json("{}")));
    let pool = adapter
        .open_pool(mount(url.into()))
        .await
        .map_err(|e| e.to_string())?;
    let probe = pool.probe().await.map_err(|e| e.to_string())?;
    assert_ne!(
        probe.server_version, "unknown",
        "INFO answered over the link"
    );
    Ok(probe.tls)
}

fn refused(case: &str, outcome: Result<TlsPosture, String>) {
    let err = outcome.expect_err(case);
    assert!(
        err.contains("certificate"),
        "{case}: refused for the wrong reason: {err}"
    );
    println!("refused as expected ({case}): {err}");
}

#[tokio::test]
#[ignore = "needs the m260 TLS redis"]
async fn rediss_with_the_ca_verifies() {
    let tls = open(&env("M260_REDISS_URL"), Some(env("M260_CA_FILE"))).await;
    assert_eq!(tls, Ok(TlsPosture::Verified));
    println!("rediss + CA: probe tls=verified");
}

#[tokio::test]
#[ignore = "needs the m260 TLS redis"]
async fn rediss_with_a_wrong_ca_is_refused() {
    refused(
        "wrong CA",
        open(&env("M260_REDISS_URL"), Some(env("M260_WRONG_CA_FILE"))).await,
    );
}

#[tokio::test]
#[ignore = "needs the m260 TLS redis"]
async fn rediss_to_a_name_outside_the_sans_is_refused() {
    refused(
        "SAN mismatch",
        open(&env("M260_UNLISTED_URL"), Some(env("M260_CA_FILE"))).await,
    );
}

/// R9: an image with no system store (`SSL_CERT_FILE` names an empty bundle, as a
/// scratch image has none) trusts only the CA, and without it trusts nothing.
#[tokio::test]
#[ignore = "needs the m260 TLS redis"]
async fn an_empty_system_store_fails_closed() {
    std::env::set_var("SSL_CERT_FILE", env("M260_EMPTY_STORE"));
    refused(
        "empty store, no CA",
        open(&env("M260_REDISS_URL"), None).await,
    );
    let tls = open(&env("M260_REDISS_URL"), Some(env("M260_CA_FILE"))).await;
    std::env::remove_var("SSL_CERT_FILE");
    assert_eq!(tls, Ok(TlsPosture::Verified), "the CA alone is enough");
    println!("empty store: refused without the CA, verified with it");
}

#[tokio::test]
#[ignore = "needs the m260 TLS redis"]
async fn plaintext_6379_is_unchanged() {
    let tls = open(&env("M260_PLAIN_URL"), Some(env("M260_CA_FILE"))).await;
    assert_eq!(tls, Ok(TlsPosture::Plaintext));
    println!("redis:// 6379: probe tls=plaintext");
}
