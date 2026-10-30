/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   caller_policy.rs                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 16:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 16:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! D1 (ADR 0023) — one table says which caller class may call each internal
//! `/v1/*` route and whether that route may carry `inline_dsn` /
//! `replica_inline_dsn`. The decision runs in the inbound layer, before any
//! handler parses the body, so a refused call never resolves or dials.
//!
//! What this proves: the caller CLASS (who holds the verifying key), the route
//! that class may reach, and that the identity and mount name one tenant. What
//! it does not prove: that the tenant the query-router asserts is the end
//! user's. That stays trusted, as in ADR 0007.

use axum::http::StatusCode;
use axum::response::Response;
use data_plane_pool::service_auth::ServiceAuthDenial;
use serde_json::Value;

use super::caller_keys::{CallerClass, CallerPolicyMode};
use super::helpers::api_err;

pub(crate) struct RouteRule {
    pub(crate) route: &'static str,
    pub(crate) class: CallerClass,
    pub(crate) inline_dsn: bool,
}

const fn rule(route: &'static str, class: CallerClass, inline_dsn: bool) -> RouteRule {
    RouteRule {
        route,
        class,
        inline_dsn,
    }
}

const QR: CallerClass = CallerClass::QueryRouter;
const TC: CallerClass = CallerClass::TenantControl;

/// `/v1/admin/raw` has no production caller (scripts only); it is
/// tenant-control's and refuses inline DSNs, because migrate already runs
/// arbitrary statements against an inline DSN for provisioning.
pub(crate) const ROUTE_POLICY: &[RouteRule] = &[
    rule("/v1/query", QR, true),
    rule("/v1/schema", QR, true),
    rule("/v1/schema/ddl", QR, true),
    rule("/v1/transactions", QR, true),
    rule("/v1/transactions/:tx_id/execute", QR, true),
    rule("/v1/transactions/:tx_id/commit", QR, true),
    rule("/v1/transactions/:tx_id/rollback", QR, true),
    rule("/v1/probe", QR, true),
    rule("/v1/permissions/decide", QR, false),
    rule("/v1/admin/raw", TC, false),
    rule("/v1/admin/migrate", TC, true),
    rule("/v1/admin/rotate", TC, true),
    rule("/v1/admin/evict-verify", TC, false),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PolicyDenial {
    Unsigned,
    LegacyToken,
    UnlistedRoute,
    WrongClass,
    BadEnvelope,
    InlineDsnRefused,
    TenantMismatch,
}

impl PolicyDenial {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Unsigned => "unsigned",
            Self::LegacyToken => "legacy_token",
            Self::UnlistedRoute => "unlisted_route",
            Self::WrongClass => "wrong_class",
            Self::BadEnvelope => "bad_envelope",
            Self::InlineDsnRefused => "inline_dsn_refused",
            Self::TenantMismatch => "tenant_mismatch",
        }
    }

    fn response(self) -> Response {
        match self {
            Self::Unsigned => api_err(
                StatusCode::UNAUTHORIZED,
                "service_auth_required",
                "this route accepts signed service calls only",
            ),
            Self::BadEnvelope => api_err(
                StatusCode::BAD_REQUEST,
                "invalid_request",
                "the request body is not JSON",
            ),
            _ => api_err(
                StatusCode::FORBIDDEN,
                "caller_not_allowed",
                "this caller may not make this call",
            ),
        }
    }
}

/// The verdict for one call: the verifying key's class against the table row,
/// then the envelope. Every refusal happens before resolve or dial.
pub(crate) fn decide(
    route: &str,
    class: &Result<CallerClass, ServiceAuthDenial>,
    body: &[u8],
) -> Result<(), PolicyDenial> {
    let class = *class.as_ref().map_err(|_| PolicyDenial::Unsigned)?;
    if class == CallerClass::Legacy {
        return Err(PolicyDenial::LegacyToken);
    }
    let row = ROUTE_POLICY
        .iter()
        .find(|row| row.route == route)
        .ok_or(PolicyDenial::UnlistedRoute)?;
    if row.class != class {
        return Err(PolicyDenial::WrongClass);
    }
    check_envelope(row, body)
}

/// Only the four fields the policy reads are looked at; the handler still owns
/// full validation. A non-object body passes here and fails in the handler.
fn check_envelope(row: &RouteRule, body: &[u8]) -> Result<(), PolicyDenial> {
    if body.iter().all(u8::is_ascii_whitespace) {
        return Ok(());
    }
    let envelope: Value = serde_json::from_slice(body).map_err(|_| PolicyDenial::BadEnvelope)?;
    let carries_dsn = ["/mount/inline_dsn", "/mount/replica_inline_dsn"]
        .iter()
        .any(|at| envelope.pointer(at).is_some_and(|v| !v.is_null()));
    if carries_dsn && !row.inline_dsn {
        return Err(PolicyDenial::InlineDsnRefused);
    }
    let identity = envelope.pointer("/identity/tenant_id");
    let mount = envelope.pointer("/mount/tenant_id");
    match (identity, mount) {
        (Some(claimed), Some(mounted)) if claimed != mounted => Err(PolicyDenial::TenantMismatch),
        _ => Ok(()),
    }
}

/// `Some(refusal)` under enforce; shadow logs `would_deny` and serves. Logs
/// carry the route template, the class and the reason, never a key or body.
pub(super) fn verdict(
    mode: CallerPolicyMode,
    route: &str,
    class: &Result<CallerClass, ServiceAuthDenial>,
    body: &[u8],
) -> Option<Response> {
    if mode == CallerPolicyMode::Off {
        return None;
    }
    let denial = decide(route, class, body).err()?;
    let class = class.as_ref().map_or("unsigned", |c| c.as_str());
    let reason = denial.as_str();
    if mode == CallerPolicyMode::Enforce {
        tracing::warn!(target: "caller_policy", route, class, outcome = "deny", reason);
        return Some(denial.response());
    }
    tracing::warn!(target: "caller_policy", route, class, outcome = "would_deny", reason);
    None
}
