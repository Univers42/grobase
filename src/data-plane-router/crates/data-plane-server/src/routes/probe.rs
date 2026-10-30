/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   probe.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 03:20:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 03:20:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Read-only engine probe (`/v1/probe`): the server version and the TLS posture
//! the pool connected with, as `EngineProbe`. Behind `DATA_PLANE_PROBE=1` — OFF
//! by default (devil G4 P11) — and mounted inside the service-auth layer, so a
//! caller without the service token gets 401.
//!
//! Caveat: the TLS label is the pool's own connect setting, so a pool already
//! open before a TLS config change keeps its old label until it is evicted.
use std::future::Future;
use std::time::Duration;

use axum::extract::State;
use axum::Json;
use data_plane_core::{DataPlaneResult, DatabaseMount, EngineProbe, PoolRegistry, RequestIdentity};
use serde::Deserialize;

use super::helpers::{bad_request, json_result, too_many_requests, validate_identity_mount};
use super::state::AppState;

/// Devil P2: mongo's server selection alone can take 30 s and postgres has no
/// pool timeout, so the probe is cut off well before a caller would hang.
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, Deserialize)]
pub(super) struct ProbeRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
}

pub(super) fn enabled() -> bool {
    std::env::var("DATA_PLANE_PROBE").as_deref() == Ok("1")
}

pub(super) async fn probe(
    State(state): State<AppState>,
    Json(request): Json<ProbeRequest>,
) -> axum::response::Response {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    let key = format!("probe:{}", request.mount.id);
    if !state.ratelimiter.allow(&key, 1, 1).await {
        return too_many_requests(1);
    }
    let outcome = bounded(PROBE_TIMEOUT, async {
        let pool = state.registry.get_or_create(request.mount).await?;
        pool.probe().await
    })
    .await;
    json_result(outcome)
}

// Caveat: a probe cut at 3 s reports `unknown` even for an engine that would have answered at 3.1 s.
async fn bounded<F>(limit: Duration, fut: F) -> DataPlaneResult<EngineProbe>
where
    F: Future<Output = DataPlaneResult<EngineProbe>>,
{
    match tokio::time::timeout(limit, fut).await {
        Ok(result) => result,
        Err(_) => Ok(EngineProbe::unknown()),
    }
}

#[cfg(test)]
mod tests {
    use super::bounded;
    use data_plane_core::{DataPlaneError, EngineProbe, TlsPosture};
    use std::time::Duration;

    #[tokio::test]
    async fn bounded_times_out_to_unknown() {
        let result = bounded(Duration::from_millis(10), std::future::pending()).await;
        let probe = result.expect("an elapsed probe must be unknown, not an error");
        assert_eq!(probe, EngineProbe::unknown());
    }

    #[tokio::test]
    async fn bounded_passes_through_a_fast_probe() {
        let probe = EngineProbe {
            server_version: "1.2".into(),
            tls: TlsPosture::Verified,
            tls_version: None,
        };
        let expected = probe.clone();
        let result = bounded(Duration::from_millis(10), async { Ok(probe) }).await;
        let actual = result.expect("a fast probe must pass through unchanged");
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn bounded_passes_through_an_error() {
        let result = bounded(Duration::from_millis(10), async {
            Err(DataPlaneError::Backend {
                message: "x".into(),
            })
        })
        .await;
        assert!(matches!(
            result,
            Err(DataPlaneError::Backend { message }) if message == "x"
        ));
    }
}
