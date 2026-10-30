//! R5 (D3, ADR 0024): a `--features dynamodb` build links ring AND aws-lc-rs, so
//! rustls has no default provider and redis's `ClientConfig::builder()` panics on
//! the first `rediss://` dial unless one was installed. Its own test binary: a
//! fresh process, so no other test can have installed a provider first.
#![cfg(all(feature = "redis-tls", feature = "dynamodb"))]

use rustls::crypto::CryptoProvider;
use tokio::net::TcpListener;

/// A port that accepts TCP and hangs up: the TLS handshake fails, after redis
/// has built its rustls config (the call that panics without a provider).
async fn hang_up_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            drop(stream);
        }
    });
    port
}

#[tokio::test]
async fn a_dynamodb_build_dials_rediss_without_a_provider_panic() {
    assert!(
        CryptoProvider::get_default().is_none(),
        "fresh process, no provider yet"
    );
    let unprovided = std::panic::catch_unwind(rustls::ClientConfig::builder);
    assert!(
        unprovided.is_err(),
        "ring + aws-lc-rs linked: builder() panics with no provider"
    );
    let url = format!("rediss://127.0.0.1:{}", hang_up_port().await);
    let client = data_plane_pool::redis_client(&url).expect("client");
    let dialled = client.get_multiplexed_async_connection().await;
    assert!(
        dialled.is_err(),
        "the peer hangs up: the handshake must fail"
    );
    assert!(
        CryptoProvider::get_default().is_some(),
        "the dial installed a provider"
    );
}
