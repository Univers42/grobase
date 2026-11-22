/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   circuit_breaker.rs                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/11/22 01:10:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/11/22 01:10:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Per-mount circuit breaker (grobase#95).
//!
//! A dead or unreachable mount costs every request the full engine timeout (5 s).
//! This breaker tracks consecutive connect/transport failures per mount.
//! After `failure_threshold` consecutive failures, the breaker opens: subsequent
//! requests answer immediately (HTTP 503 `mount_unreachable`, latency <50 ms)
//! for the duration of `cooldown`. Once `cooldown` elapses, the breaker enters
//! `HalfOpen` and allows one probe request through: if it succeeds, the breaker
//! closes; if it fails, the breaker re-opens for another `cooldown`.

use data_plane_core::DataPlaneError;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BreakerState {
    Closed,
    Open,
    HalfOpen,
}

#[derive(Debug)]
struct MountBreaker {
    consecutive_failures: u32,
    state: BreakerState,
    opened_at: Option<Instant>,
}

impl Default for MountBreaker {
    fn default() -> Self {
        Self {
            consecutive_failures: 0,
            state: BreakerState::Closed,
            opened_at: None,
        }
    }
}

pub struct CircuitBreaker {
    failure_threshold: u32,
    cooldown: Duration,
    mounts: Mutex<HashMap<String, MountBreaker>>,
}

impl CircuitBreaker {
    #[must_use]
    pub fn new(failure_threshold: u32, cooldown: Duration) -> Self {
        Self {
            failure_threshold: failure_threshold.max(1),
            cooldown,
            mounts: Mutex::new(HashMap::new()),
        }
    }

    /// Check if a request to `mount_id` is permitted to proceed.
    ///
    /// - `Closed`: returns `Ok(())`.
    /// - `Open`: if `cooldown` has expired, transitions to `HalfOpen` and returns `Ok(())`
    ///   to allow one probe request through. Otherwise returns `Err(DataPlaneError::MountUnreachable)`
    ///   immediately (<1 ms).
    /// - `HalfOpen`: probe is already in flight; returns `Err(DataPlaneError::MountUnreachable)`.
    pub fn check(&self, mount_id: &str) -> Result<(), DataPlaneError> {
        let mut mounts = self.mounts.lock().unwrap();
        let entry = mounts.entry(mount_id.to_string()).or_default();
        match entry.state {
            BreakerState::Closed => Ok(()),
            BreakerState::Open => {
                if let Some(opened_at) = entry.opened_at {
                    if opened_at.elapsed() >= self.cooldown {
                        entry.state = BreakerState::HalfOpen;
                        tracing::info!(mount_id = %mount_id, "circuit breaker entered HalfOpen state; allowing probe");
                        return Ok(());
                    }
                }
                Err(DataPlaneError::MountUnreachable {
                    mount_id: mount_id.to_string(),
                })
            }
            BreakerState::HalfOpen => Err(DataPlaneError::MountUnreachable {
                mount_id: mount_id.to_string(),
            }),
        }
    }

    /// Record a successful operation for `mount_id`.
    ///
    /// Resets consecutive failures to 0 and transitions breaker to `Closed`.
    pub fn record_success(&self, mount_id: &str) {
        let mut mounts = self.mounts.lock().unwrap();
        if let Some(entry) = mounts.get_mut(mount_id) {
            if entry.state != BreakerState::Closed || entry.consecutive_failures > 0 {
                tracing::info!(mount_id = %mount_id, "circuit breaker closed after success");
            }
            entry.consecutive_failures = 0;
            entry.state = BreakerState::Closed;
            entry.opened_at = None;
        }
    }

    /// Record a failure for `mount_id`.
    ///
    /// Non-connect failures (such as query syntax errors or table not found)
    /// do not indicate engine unreachability and are ignored.
    pub fn record_failure(&self, mount_id: &str, is_connect_error: bool) {
        if !is_connect_error {
            return;
        }
        let mut mounts = self.mounts.lock().unwrap();
        let entry = mounts.entry(mount_id.to_string()).or_default();
        match entry.state {
            BreakerState::HalfOpen => {
                entry.state = BreakerState::Open;
                entry.opened_at = Some(Instant::now());
                tracing::warn!(mount_id = %mount_id, "circuit breaker probe failed; returning to Open");
            }
            BreakerState::Closed => {
                entry.consecutive_failures += 1;
                if entry.consecutive_failures >= self.failure_threshold {
                    entry.state = BreakerState::Open;
                    entry.opened_at = Some(Instant::now());
                    tracing::warn!(
                        mount_id = %mount_id,
                        failures = entry.consecutive_failures,
                        "circuit breaker opened after consecutive connect failures"
                    );
                }
            }
            BreakerState::Open => {
                entry.opened_at = Some(Instant::now());
            }
        }
    }

    /// Inspect current breaker state for a mount (used in tests and monitoring).
    #[must_use]
    pub fn state_of(&self, mount_id: &str) -> BreakerState {
        let mounts = self.mounts.lock().unwrap();
        mounts
            .get(mount_id)
            .map(|e| e.state)
            .unwrap_or(BreakerState::Closed)
    }

    /// Determine if a `DataPlaneError` represents an engine connection / reachability failure.
    #[must_use]
    pub fn is_connect_error(err: &DataPlaneError) -> bool {
        match err {
            DataPlaneError::MountUnreachable { .. } => true,
            DataPlaneError::Backend { message } => {
                let lower = message.to_lowercase();
                lower.contains("connection refused")
                    || lower.contains("connection reset")
                    || lower.contains("broken pipe")
                    || lower.contains("timed out")
                    || lower.contains("timeout")
                    || lower.contains("can't connect")
                    || lower.contains("cant connect")
                    || lower.contains("failed to connect")
                    || lower.contains("host unreachable")
                    || lower.contains("network unreachable")
                    || lower.contains("no route to host")
                    || lower.contains("refusing")
                    || lower.contains("i/o error")
                    || lower.contains("pool checkout failed")
                    || lower.contains("connection closed")
                    || lower.contains("error connecting to")
                    || lower.contains("could not connect")
                    || lower.contains("server closed the connection")
                    || lower.contains("not reachable")
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn circuit_breaker_opens_after_n_failures_and_answers_fast() {
        let breaker = CircuitBreaker::new(3, Duration::from_millis(100));
        let mount = "dead-mount-1";

        // Initial state is Closed
        assert_eq!(breaker.state_of(mount), BreakerState::Closed);
        assert!(breaker.check(mount).is_ok());

        // First 2 failures: still Closed
        breaker.record_failure(mount, true);
        assert_eq!(breaker.state_of(mount), BreakerState::Closed);
        assert!(breaker.check(mount).is_ok());

        breaker.record_failure(mount, true);
        assert_eq!(breaker.state_of(mount), BreakerState::Closed);
        assert!(breaker.check(mount).is_ok());

        // 3rd failure: trips Open
        breaker.record_failure(mount, true);
        assert_eq!(breaker.state_of(mount), BreakerState::Open);

        // Immediate read: answers fast (<50ms) with MountUnreachable
        let start = Instant::now();
        let res = breaker.check(mount);
        let elapsed = start.elapsed();
        assert!(elapsed < Duration::from_millis(50));
        assert!(matches!(res, Err(DataPlaneError::MountUnreachable { .. })));
    }

    #[test]
    fn circuit_breaker_non_connect_errors_do_not_trip() {
        let breaker = CircuitBreaker::new(2, Duration::from_millis(100));
        let mount = "query-error-mount";

        // Non-connect error (e.g. invalid request, syntax error)
        breaker.record_failure(mount, false);
        breaker.record_failure(mount, false);
        breaker.record_failure(mount, false);

        assert_eq!(breaker.state_of(mount), BreakerState::Closed);
        assert!(breaker.check(mount).is_ok());
    }

    #[test]
    fn circuit_breaker_probes_after_cooldown_and_recovers() {
        let breaker = CircuitBreaker::new(2, Duration::from_millis(50));
        let mount = "reviving-mount";

        breaker.record_failure(mount, true);
        breaker.record_failure(mount, true);
        assert_eq!(breaker.state_of(mount), BreakerState::Open);

        // Wait for cooldown
        std::thread::sleep(Duration::from_millis(60));

        // First request after cooldown enters HalfOpen
        assert!(breaker.check(mount).is_ok());
        assert_eq!(breaker.state_of(mount), BreakerState::HalfOpen);

        // Concurrent request during HalfOpen is rejected
        assert!(matches!(
            breaker.check(mount),
            Err(DataPlaneError::MountUnreachable { .. })
        ));

        // Revived backend succeeds -> closes breaker
        breaker.record_success(mount);
        assert_eq!(breaker.state_of(mount), BreakerState::Closed);
        assert!(breaker.check(mount).is_ok());
    }
}
