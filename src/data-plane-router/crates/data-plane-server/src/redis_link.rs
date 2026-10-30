/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   redis_link.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 08:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 08:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The one bounded Redis dial shared by the limiter, the quota honor-set and the
//! usage flusher (m230). redis 0.27.6's `ConnectionManager::new` has no connect
//! timeout and retries 6 times on backon's builder (1 s floor, `factor` 100 read
//! as a multiplier): a refused port was still dialling after 90 s (measured), and
//! the callers' `OnceCell::get_or_try_init` caches no failure, so every
//! rate-limited request paid that before failing open. No retries here, measured
//! 255 µs on a refused port: the next call is the retry.

use redis_rl::aio::{ConnectionManager, ConnectionManagerConfig};
use std::time::Duration;

/// Open a `ConnectionManager` on `url` with a bounded first dial.
///
/// Caveat: the bound is per call, not per outage — while Redis is blackholed each
/// caller still waits the 1 s connect timeout. One attempt means a single dropped
/// SYN reads as down until the next call, and 1 s assumes a LAN Redis; a WAN one
/// slow to accept reads as down.
pub(crate) async fn connect(url: &str) -> redis_rl::RedisResult<ConnectionManager> {
    let client = redis_rl::Client::open(url)?;
    let config = ConnectionManagerConfig::new()
        .set_connection_timeout(Duration::from_secs(1))
        .set_number_of_retries(0);
    ConnectionManager::new_with_config(client, config).await
}

#[cfg(test)]
mod tests {
    use super::connect;
    use std::time::{Duration, Instant};

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
}
