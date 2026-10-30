/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   caller_policy_tests.rs                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 16:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 16:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! D1 (ADR 0023) — the policy table against `mod.rs`, and `decide` on every
//! denial class. The router-level arms live in `caller_policy_router_tests.rs`.

use std::sync::{Arc, Mutex};

use data_plane_pool::service_auth::ServiceAuthDenial;

use super::caller_keys::{CallerClass, CallerPolicyMode};
use super::caller_policy::{decide, verdict, PolicyDenial, ROUTE_POLICY};

const QR: CallerClass = CallerClass::QueryRouter;
const TC: CallerClass = CallerClass::TenantControl;
const LEGACY: CallerClass = CallerClass::Legacy;
const SAME_TENANT: &str =
    r#"{"identity":{"tenant_id":"t1","roles":["service_role"]},"mount":{"tenant_id":"t1"}}"#;
const INLINE: &str = r#"{"identity":{"tenant_id":"t1"},"mount":{"tenant_id":"t1","inline_dsn":"postgres://u@db/x"}}"#;
const REPLICA: &str = r#"{"mount":{"tenant_id":"t1","replica_inline_dsn":"postgres://u@db/x"}}"#;
const NULL_DSN: &str = r#"{"mount":{"tenant_id":"t1","inline_dsn":null}}"#;
const MISMATCH: &str = r#"{"identity":{"tenant_id":"t1"},"mount":{"tenant_id":"t2"}}"#;

/// The internal group of `mod.rs`: from `let mut internal` to the layer.
fn internal_routes() -> Vec<&'static str> {
    let source = include_str!("mod.rs");
    let start = source
        .find("let mut internal = Router::new()")
        .expect("internal group");
    let end = source[start..]
        .find("inbound_auth::require_service_auth")
        .expect("layer");
    source[start..start + end]
        .split('"')
        .skip(1)
        .step_by(2)
        .filter(|literal| literal.starts_with("/v1/"))
        .collect()
}

// Caveat: reads route literals from `mod.rs` source text. A route added through
// a helper or a `const` instead of a `"/v1/..."` literal in the internal group
// is not seen, so this under-reports; keep internal routes as literals there.
#[test]
fn k4_every_internal_route_has_exactly_one_policy_row() {
    let routes = internal_routes();
    assert!(routes.len() >= 13, "parsed only {routes:?}");
    for route in &routes {
        let rows = ROUTE_POLICY
            .iter()
            .filter(|row| row.route == *route)
            .count();
        assert_eq!(rows, 1, "{route} has {rows} policy rows");
    }
    for row in ROUTE_POLICY {
        assert!(
            routes.contains(&row.route),
            "{} is not an internal route",
            row.route
        );
    }
    assert_eq!(routes.len(), ROUTE_POLICY.len());
}

fn denial(route: &str, class: CallerClass, body: &str) -> Option<PolicyDenial> {
    decide(route, &Ok(class), body.as_bytes()).err()
}

#[test]
fn k4_each_route_admits_its_class_only() {
    for row in ROUTE_POLICY {
        assert_eq!(
            denial(row.route, row.class, SAME_TENANT),
            None,
            "{}",
            row.route
        );
        let other = if row.class == QR { TC } else { QR };
        let refused = denial(row.route, other, SAME_TENANT);
        assert_eq!(refused, Some(PolicyDenial::WrongClass), "{}", row.route);
    }
}

#[test]
fn k6_query_router_on_an_admin_route_is_refused_whatever_roles_it_claims() {
    for route in ["/v1/admin/raw", "/v1/admin/migrate", "/v1/admin/rotate"] {
        let refused = denial(route, QR, SAME_TENANT);
        assert_eq!(refused, Some(PolicyDenial::WrongClass), "{route}");
    }
    let refused = denial("/v1/query", QR, MISMATCH);
    assert_eq!(refused, Some(PolicyDenial::TenantMismatch));
    let refused = denial("/v1/admin/migrate", TC, MISMATCH);
    assert_eq!(refused, Some(PolicyDenial::TenantMismatch));
}

#[test]
fn k5_inline_dsn_is_admitted_only_where_the_table_says() {
    assert_eq!(denial("/v1/query", QR, INLINE), None);
    assert_eq!(denial("/v1/transactions", QR, REPLICA), None);
    assert_eq!(denial("/v1/admin/migrate", TC, INLINE), None);
    assert_eq!(denial("/v1/admin/rotate", TC, REPLICA), None);
    let refused = Some(PolicyDenial::InlineDsnRefused);
    assert_eq!(denial("/v1/admin/raw", TC, INLINE), refused);
    assert_eq!(denial("/v1/admin/raw", TC, REPLICA), refused);
    assert_eq!(denial("/v1/admin/evict-verify", TC, INLINE), refused);
    assert_eq!(denial("/v1/permissions/decide", QR, REPLICA), refused);
    assert_eq!(
        denial("/v1/admin/raw", TC, NULL_DSN),
        None,
        "null is absent"
    );
}

#[test]
fn k7_legacy_unsigned_and_unlisted_are_refused() {
    let unsigned = Err(ServiceAuthDenial::Missing);
    let refused = decide("/v1/query", &unsigned, SAME_TENANT.as_bytes()).err();
    assert_eq!(refused, Some(PolicyDenial::Unsigned));
    for row in ROUTE_POLICY {
        let refused = denial(row.route, LEGACY, SAME_TENANT);
        assert_eq!(refused, Some(PolicyDenial::LegacyToken), "{}", row.route);
    }
    assert_eq!(
        denial("/v1/nope", QR, ""),
        Some(PolicyDenial::UnlistedRoute)
    );
}

#[test]
fn an_empty_body_passes_and_a_non_json_body_is_a_bad_envelope() {
    assert_eq!(denial("/v1/transactions/:tx_id/commit", QR, " \n"), None);
    assert_eq!(
        denial("/v1/query", QR, "not json"),
        Some(PolicyDenial::BadEnvelope)
    );
    assert_eq!(
        denial("/v1/query", QR, "[1]"),
        None,
        "the handler refuses it"
    );
}

#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for Captured {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().expect("lock").extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn logged(run: impl FnOnce()) -> String {
    let captured = Captured::default();
    let sink = captured.clone();
    let subscriber = tracing_subscriber::fmt()
        .with_writer(move || sink.clone())
        .with_ansi(false)
        .finish();
    tracing::subscriber::with_default(subscriber, run);
    let bytes = captured.0.lock().expect("lock").clone();
    String::from_utf8(bytes).expect("utf8")
}

#[test]
fn k7_shadow_logs_would_deny_with_route_and_class_only_and_serves() {
    let mut served = None;
    let log = logged(|| {
        served = Some(verdict(
            CallerPolicyMode::Shadow,
            "/v1/query",
            &Ok(LEGACY),
            INLINE.as_bytes(),
        ));
    });
    assert!(served.expect("ran").is_none(), "shadow refused a call");
    for want in ["would_deny", "/v1/query", "legacy", "legacy_token"] {
        assert!(log.contains(want), "missing {want}: {log}");
    }
    assert!(
        !log.contains("postgres://"),
        "a body field reached the log: {log}"
    );
}

#[test]
fn k7_enforce_answers_403_and_off_never_judges() {
    let body = SAME_TENANT.as_bytes();
    let refused = verdict(CallerPolicyMode::Enforce, "/v1/query", &Ok(LEGACY), body);
    assert_eq!(refused.map(|r| r.status().as_u16()), Some(403));
    let unsigned = Err(ServiceAuthDenial::Missing);
    let refused = verdict(CallerPolicyMode::Enforce, "/v1/query", &unsigned, body);
    assert_eq!(refused.map(|r| r.status().as_u16()), Some(401));
    assert!(verdict(CallerPolicyMode::Off, "/v1/query", &unsigned, body).is_none());
}
