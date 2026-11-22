/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sec_circuit_breaker.rs                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/11/22 01:20:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/11/22 01:20:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Conformance test for per-mount circuit breaker (grobase#95).
//!
//! A dead mount whose engine refuses connections trips the breaker after
//! N consecutive failures. Subsequent requests answer immediately (<50 ms)
//! with 503 mount_unreachable without waiting for backend timeouts.
//! When the backend revives, the mount serves traffic again within one cooldown.

use data_plane_core::DataPlaneError;
use data_plane_server::circuit_breaker::{BreakerState, CircuitBreaker};
use std::net::TcpListener;
use std::time::{Duration, Instant};

#[tokio::test]
async fn test_circuit_breaker_with_refusing_backend() {
    // 1. Find an unused port and immediately drop listener so TCP connections are refused.
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
    let addr = listener.local_addr().expect("local addr");
    drop(listener); // Refusing backend!

    let mount_id = "test-refusing-mount-42";
    let threshold = 3;
    let cooldown = Duration::from_millis(80);
    let breaker = CircuitBreaker::new(threshold, cooldown);

    // Initial state: Closed
    assert_eq!(breaker.state_of(mount_id), BreakerState::Closed);
    assert!(breaker.check(mount_id).is_ok());

    // 2. Simulate N connect failures against the refusing backend
    for i in 1..=threshold {
        // Attempt TCP connect to verify backend is genuinely refusing
        let conn_res = tokio::net::TcpStream::connect(addr).await;
        assert!(conn_res.is_err(), "backend must refuse connection");

        let err = DataPlaneError::Backend {
            message: format!("Can't connect to MySQL server on '{addr}' (Connection refused)"),
        };
        assert!(CircuitBreaker::is_connect_error(&err));

        breaker.record_failure(mount_id, CircuitBreaker::is_connect_error(&err));

        if i < threshold {
            assert_eq!(breaker.state_of(mount_id), BreakerState::Closed);
            assert!(breaker.check(mount_id).is_ok());
        }
    }

    // 3. Breaker is now Open
    assert_eq!(breaker.state_of(mount_id), BreakerState::Open);

    // 4. Verification: A read on a dead mount answers in under 50 ms after breaker opens
    let start = Instant::now();
    let res = breaker.check(mount_id);
    let elapsed = start.elapsed();

    assert!(
        elapsed < Duration::from_millis(50),
        "read on dead mount must answer in under 50 ms, took {:?}",
        elapsed
    );
    match res {
        Err(DataPlaneError::MountUnreachable { ref mount_id }) => {
            assert_eq!(mount_id, "test-refusing-mount-42");
        }
        other => panic!("expected MountUnreachable, got {:?}", other),
    }

    // 5. Revive backend: start listening on the port
    let revived_listener = tokio::net::TcpListener::bind(addr).await.expect("revived backend bind");

    // Wait for cooldown to expire
    tokio::time::sleep(cooldown + Duration::from_millis(20)).await;

    // 6. First read after cooldown enters HalfOpen (probe allowed)
    let probe_check = breaker.check(mount_id);
    assert!(probe_check.is_ok(), "probe check must be allowed");
    assert_eq!(breaker.state_of(mount_id), BreakerState::HalfOpen);

    // Probe connects to revived backend successfully
    let mut client = tokio::net::TcpStream::connect(addr).await.expect("connect to revived backend");
    let (mut server_conn, _) = revived_listener.accept().await.expect("accept connection");
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    client.write_all(b"ping").await.unwrap();
    let mut buf = [0u8; 4];
    server_conn.read_exact(&mut buf).await.unwrap();
    assert_eq!(&buf, b"ping");

    // Probe succeeded -> record success
    breaker.record_success(mount_id);

    // Breaker has closed and serves normally
    assert_eq!(breaker.state_of(mount_id), BreakerState::Closed);
    assert!(breaker.check(mount_id).is_ok());
}
