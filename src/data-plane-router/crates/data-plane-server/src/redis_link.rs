/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   redis_link.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 08:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 14:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The one bounded Redis dial shared by the limiter, the quota honor-set and the
//! usage flusher (m230). redis 0.27.6's `ConnectionManager::new` has no connect
//! timeout and retries 6 times on backon's builder (1 s floor, `factor` 100 read
//! as a multiplier): a refused port was still dialling after 90 s (measured), and
//! the callers' `OnceCell::get_or_try_init` caches no failure, so every
//! rate-limited request paid that before failing open. No retries here, measured
//! 255 µs on a refused port: the next call is the retry.
//!
//! A `rediss://` URL dials TLS through the pool's `redis_client` (ADR 0024: the
//! CA bundle, the crypto provider, the `#insecure` refusal). A TLS failure (wrong
//! CA, name mismatch, `#insecure`, a bad `DATA_PLANE_TLS_CA_FILE`) is an `Err`
//! here exactly like a refused port, inside the same 1 s bound, so each caller
//! keeps its failure mode: the limiter admits (fail-open), the honor sets keep
//! their prior snapshot, the usage flusher drops the windows (best-effort).

use redis_rl::aio::{ConnectionManager, ConnectionManagerConfig};
use std::time::Duration;

/// Open a `ConnectionManager` on `url` with a bounded first dial.
///
/// Caveat: the bound is per call, not per outage — while Redis is blackholed each
/// caller still waits the 1 s connect timeout. One attempt means a single dropped
/// SYN reads as down until the next call, and 1 s assumes a LAN Redis; a WAN one
/// slow to accept reads as down.
pub(crate) async fn connect(url: &str) -> redis_rl::RedisResult<ConnectionManager> {
    let client = data_plane_pool::redis_client(url)?;
    let config = ConnectionManagerConfig::new()
        .set_connection_timeout(Duration::from_secs(1))
        .set_number_of_retries(0);
    ConnectionManager::new_with_config(client, config).await
}

#[cfg(test)]
mod tests {
    use super::connect;
    use crate::quota::{QuotaRefresher, QuotaSet};
    use crate::ratelimit::{RateLimiter, RedisRateLimiter};
    use std::time::{Duration, Instant};
    use tokio::net::TcpListener;

    /// Accepts TCP and never answers: a TLS handshake waits on it until the bound.
    async fn silent_peer() -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let port = listener.local_addr().expect("addr").port();
        tokio::spawn(async move {
            let mut held = Vec::new();
            while let Ok((stream, _)) = listener.accept().await {
                held.push(stream);
            }
        });
        port
    }

    #[tokio::test]
    async fn a_stalled_tls_handshake_fails_inside_the_bound() {
        let url = format!("rediss://127.0.0.1:{}", silent_peer().await);
        let started = Instant::now();
        assert!(connect(&url).await.is_err(), "no TLS server answers");
        let took = started.elapsed();
        assert!(
            took < Duration::from_millis(1500),
            "rediss dial took {took:?}"
        );
    }

    #[tokio::test]
    async fn an_insecure_fragment_never_dials() {
        let url = format!("rediss://127.0.0.1:{}#insecure", silent_peer().await);
        let started = Instant::now();
        assert!(connect(&url).await.is_err(), "#insecure is refused");
        assert!(
            started.elapsed() < Duration::from_millis(100),
            "refused before any dial"
        );
    }

    #[tokio::test]
    async fn a_tls_failure_keeps_each_consumers_failure_mode() {
        let url = format!("rediss://127.0.0.1:{}", silent_peer().await);
        let limiter = RateLimiter::Redis(RedisRateLimiter::new(url.clone()));
        assert!(
            limiter.allow("t-d3", 1, 1).await,
            "the limiter admits (fail-open)"
        );
        let set = QuotaSet::new();
        set.replace(std::iter::once("t-d3".to_string()).collect());
        QuotaRefresher::new(url).refresh(&set).await;
        assert!(
            set.is_over("t-d3"),
            "the honor set keeps its prior snapshot"
        );
    }

    #[tokio::test]
    async fn refused_dial_fails_fast() {
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .and_then(|l| l.local_addr())
            .map(|a| a.port())
            .expect("reserve a free port");
        let started = Instant::now();
        let res = connect(&format!("redis://127.0.0.1:{port}")).await;
        assert!(res.is_err(), "nothing listens on {port}");
        assert!(
            started.elapsed() < Duration::from_millis(500),
            "refused dial took {:?}",
            started.elapsed()
        );
    }

    /// m260 (R11): the server's own consumer over `rediss://` with the CA. A member
    /// written through the link must come back through the honor-set refresh.
    #[tokio::test]
    #[ignore = "needs the m260 TLS redis"]
    async fn the_honor_set_refreshes_over_rediss() {
        let url = std::env::var("M260_REDISS_URL").expect("M260_REDISS_URL");
        let ca = std::env::var("M260_CA_FILE").expect("M260_CA_FILE");
        std::env::set_var("DATA_PLANE_TLS_CA_FILE", ca);
        let mut link = connect(&url).await.expect("rediss link with the CA");
        let member = format!("m260-{}", std::process::id());
        let key = crate::quota::QUOTA_OVER_SET;
        let added: i64 = redis_rl::cmd("SADD")
            .arg(key)
            .arg(&member)
            .query_async(&mut link)
            .await
            .expect("SADD over TLS");
        assert_eq!(added, 1);
        let set = QuotaSet::new();
        QuotaRefresher::new(url).refresh(&set).await;
        let _: i64 = redis_rl::cmd("SREM")
            .arg(key)
            .arg(&member)
            .query_async(&mut link)
            .await
            .expect("SREM over TLS");
        assert!(set.is_over(&member), "the refresher read the set over TLS");
        println!("server honor-set refresh over rediss: ok");
    }
}
