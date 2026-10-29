/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service_auth.rs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:31:53 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 21:11:50 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! v1 HMAC service-to-service auth (audit O1) — the Rust caller half of the Go
//! `shared.VerifyServiceRequest`. Under `SERVICE_TOKEN_MODE=hmac` the shared
//! token never transits the wire: each request carries
//!
//! `X-Service-Auth: v1.<ts>.<hex hmac-sha256(token, "<ts>\n<METHOD>\n<PATH>\n<sha256hex(body)>")>`
//!
//! binding time, method, path and body (replay against another endpoint or
//! payload fails). PATH is the URL path only — internal base URLs are
//! origin-only and these routes take no query strings. Default mode is
//! `static` (the plain `X-Service-Token` header), byte-identical to before.

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

/// True when `SERVICE_TOKEN_MODE=hmac` (case-insensitive).
#[must_use]
pub fn hmac_mode() -> bool {
    std::env::var("SERVICE_TOKEN_MODE")
        .map(|v| v.trim().eq_ignore_ascii_case("hmac"))
        .unwrap_or(false)
}

/// Optional rotation-window previous token (`INTERNAL_SERVICE_TOKEN_PREV`).
/// Empty (the default) means single-key behavior — byte-identical to before.
/// Mirrors the Go `prevServiceToken()` so a dual-key verify is symmetric across
/// the planes (G-Rotate, in-repo half).
#[must_use]
pub fn prev_service_token() -> String {
    std::env::var("INTERNAL_SERVICE_TOKEN_PREV").unwrap_or_default()
}

/// Constant-time compare (no early-out on the first mismatch) so verify timing
/// does not leak how many bytes matched.
fn ct_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Dual-key verify of a presented `X-Service-Auth` value against the current
/// token and, if a rotation window is open (`prev` non-empty), the previous one.
/// `ts` is the timestamp parsed from the header. Returns true if EITHER arm
/// matches. With `prev` empty the second arm is never taken — single-key parity.
#[must_use]
pub fn verify_service_auth_at(
    header_value: &str,
    current: &str,
    prev: &str,
    method: &str,
    path: &str,
    body: &[u8],
    ts: i64,
) -> bool {
    let want_cur = compute_service_auth_at(current, method, path, body, ts);
    let cur_ok = ct_eq(header_value, &want_cur);
    let prev_ok = if prev.is_empty() {
        false
    } else {
        let want_prev = compute_service_auth_at(prev, method, path, body, ts);
        ct_eq(header_value, &want_prev)
    };
    cur_ok || prev_ok
}

/// Accepted clock skew in seconds (`SERVICE_AUTH_SKEW_SECS`, default 120); a
/// non-positive or unparseable value keeps the default. Mirrors the Go
/// `serviceAuthSkew()`.
#[must_use]
pub fn service_auth_skew() -> i64 {
    std::env::var("SERVICE_AUTH_SKEW_SECS")
        .ok()
        .and_then(|v| v.trim().parse::<i64>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(120)
}

/// Why an inbound service request did not authenticate. Carries no value from
/// the request, so logging it can never leak a token or a signature.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceAuthDenial {
    /// The receiver has no token configured: nothing can verify (fail closed).
    NoTokenConfigured,
    /// The header the active mode reads is absent.
    Missing,
    /// `X-Service-Auth` is not `v1.<ts>.<hex>`.
    Malformed,
    /// The signature's timestamp is outside the accepted skew.
    Stale,
    /// Wrong token, or a signature over another method, path or body.
    Mismatch,
}

impl ServiceAuthDenial {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NoTokenConfigured => "no_token_configured",
            Self::Missing => "missing",
            Self::Malformed => "malformed",
            Self::Stale => "stale",
            Self::Mismatch => "mismatch",
        }
    }
}

/// The parts of a request the v1 signature binds.
pub struct SignedRequest<'a> {
    pub method: &'a str,
    pub path: &'a str,
    pub body: &'a [u8],
}

/// The receiver half of the scheme: the Rust mirror of Go `serviceauth.Verify`.
/// `hmac` true reads `X-Service-Auth`, false the static `X-Service-Token`; both
/// keys are always compared so timing does not say which one matched.
pub struct ServiceAuthVerifier<'a> {
    pub current: &'a str,
    pub prev: &'a str,
    pub hmac: bool,
    pub skew_secs: i64,
}

impl ServiceAuthVerifier<'_> {
    /// `header` returns the named request header's value, if present.
    ///
    /// # Errors
    /// The [`ServiceAuthDenial`] that names why the request is not a service call.
    pub fn verify<'h>(
        &self,
        header: impl Fn(&str) -> Option<&'h str>,
        request: &SignedRequest<'_>,
        now: i64,
    ) -> Result<(), ServiceAuthDenial> {
        if self.current.is_empty() {
            return Err(ServiceAuthDenial::NoTokenConfigured);
        }
        if !self.hmac {
            let presented = header("x-service-token").ok_or(ServiceAuthDenial::Missing)?;
            let cur_ok = ct_eq(presented, self.current);
            let prev_ok = !self.prev.is_empty() && ct_eq(presented, self.prev);
            return if cur_ok || prev_ok {
                Ok(())
            } else {
                Err(ServiceAuthDenial::Mismatch)
            };
        }
        let presented = header("x-service-auth").ok_or(ServiceAuthDenial::Missing)?;
        let ts = match presented.split('.').collect::<Vec<_>>().as_slice() {
            ["v1", ts, _] => ts
                .parse::<i64>()
                .map_err(|_| ServiceAuthDenial::Malformed)?,
            _ => return Err(ServiceAuthDenial::Malformed),
        };
        if ts < now - self.skew_secs || ts > now + self.skew_secs {
            return Err(ServiceAuthDenial::Stale);
        }
        let SignedRequest { method, path, body } = *request;
        if verify_service_auth_at(presented, self.current, self.prev, method, path, body, ts) {
            Ok(())
        } else {
            Err(ServiceAuthDenial::Mismatch)
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Signature for a fixed timestamp (the testable core).
#[must_use]
pub fn compute_service_auth_at(
    token: &str,
    method: &str,
    path: &str,
    body: &[u8],
    ts: i64,
) -> String {
    let body_hex = hex(&Sha256::digest(body));
    let msg = format!("{ts}\n{}\n{path}\n{body_hex}", method.to_uppercase());
    let mut mac =
        Hmac::<Sha256>::new_from_slice(token.as_bytes()).expect("hmac accepts any key length");
    mac.update(msg.as_bytes());
    format!("v1.{ts}.{}", hex(&mac.finalize().into_bytes()))
}

/// Signature for "now" — the value to send as `X-Service-Auth`.
#[must_use]
pub fn compute_service_auth(token: &str, method: &str, path: &str, body: &[u8]) -> String {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0) as i64;
    compute_service_auth_at(token, method, path, body, ts)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Golden vectors shared with the Go (`shared/token_test.go`) and TS
    /// implementations — all three languages must sign byte-identically.
    #[test]
    fn golden_vectors_match_go() {
        assert_eq!(
            compute_service_auth_at(
                "test-token",
                "POST",
                "/v1/keys/verify",
                br#"{"key":"abc"}"#,
                1_700_000_000
            ),
            "v1.1700000000.b2e684210cc7e80998388c89afe88d2fbd4fd9a7492289724f7fd3f15075189e"
        );
        assert_eq!(
            compute_service_auth_at(
                "test-token",
                "GET",
                "/databases/db1/connect",
                b"",
                1_700_000_000
            ),
            "v1.1700000000.d53d261c30ba227cb3ab770a0a3c936e0fc0cd7385855339ba60b1a172b21b6b"
        );
    }

    /// G-Rotate dual-key verify (Rust mirror of the Go test): during a window
    /// both the current and previous tokens verify; an unrelated key is
    /// rejected; with no window (prev empty) only the current key verifies.
    #[test]
    fn dual_key_rotation_window() {
        let (ts, method, path, body) = (1_700_000_000, "POST", "/v1/keys/verify", b"{}".as_slice());
        let sig_a = compute_service_auth_at("key-A-old", method, path, body, ts);
        let sig_b = compute_service_auth_at("key-B-new", method, path, body, ts);
        let sig_c = compute_service_auth_at("key-C-other", method, path, body, ts);

        // Window open: primary=B, prev=A → both A and B verify, C rejected.
        assert!(verify_service_auth_at(
            &sig_b,
            "key-B-new",
            "key-A-old",
            method,
            path,
            body,
            ts
        ));
        assert!(verify_service_auth_at(
            &sig_a,
            "key-B-new",
            "key-A-old",
            method,
            path,
            body,
            ts
        ));
        assert!(!verify_service_auth_at(
            &sig_c,
            "key-B-new",
            "key-A-old",
            method,
            path,
            body,
            ts
        ));

        // Window closed (prev empty): only B verifies, A rejected (load-bearing).
        assert!(verify_service_auth_at(
            &sig_b,
            "key-B-new",
            "",
            method,
            path,
            body,
            ts
        ));
        assert!(!verify_service_auth_at(
            &sig_a,
            "key-B-new",
            "",
            method,
            path,
            body,
            ts
        ));
    }

    const NOW: i64 = 1_700_000_000;
    const GOLDEN: &str =
        "v1.1700000000.b2e684210cc7e80998388c89afe88d2fbd4fd9a7492289724f7fd3f15075189e";

    fn hmac_verifier<'a>(current: &'a str, prev: &'a str) -> ServiceAuthVerifier<'a> {
        ServiceAuthVerifier {
            current,
            prev,
            hmac: true,
            skew_secs: 120,
        }
    }

    fn signed<'a>(path: &'a str, body: &'a [u8]) -> SignedRequest<'a> {
        SignedRequest {
            method: "POST",
            path,
            body,
        }
    }

    fn auth_header<'a>(value: &'a str) -> impl Fn(&str) -> Option<&'a str> + 'a {
        move |name| (name == "x-service-auth").then_some(value)
    }

    #[test]
    fn verifier_accepts_the_golden_vector() {
        let request = signed("/v1/keys/verify", br#"{"key":"abc"}"#);
        let verdict = hmac_verifier("test-token", "").verify(auth_header(GOLDEN), &request, NOW);
        assert_eq!(verdict, Ok(()));
    }

    #[test]
    fn verifier_names_each_denial() {
        let v = hmac_verifier("test-token", "");
        let body = br#"{"key":"abc"}"#;
        let ok_path = signed("/v1/keys/verify", body);
        let deny = |header: &str, request: &SignedRequest<'_>, now| {
            v.verify(auth_header(header), request, now).unwrap_err()
        };
        assert_eq!(
            deny(GOLDEN, &signed("/v1/admin/raw", body), NOW),
            ServiceAuthDenial::Mismatch
        );
        assert_eq!(
            deny(GOLDEN, &signed("/v1/keys/verify", b"{}"), NOW),
            ServiceAuthDenial::Mismatch
        );
        assert_eq!(deny(GOLDEN, &ok_path, NOW + 121), ServiceAuthDenial::Stale);
        assert_eq!(deny(GOLDEN, &ok_path, NOW - 121), ServiceAuthDenial::Stale);
        assert_eq!(
            deny("v1.notanumber.ab", &ok_path, NOW),
            ServiceAuthDenial::Malformed
        );
        assert_eq!(deny("v2.1.ab", &ok_path, NOW), ServiceAuthDenial::Malformed);
        assert_eq!(
            v.verify(|_| None, &ok_path, NOW),
            Err(ServiceAuthDenial::Missing)
        );
        assert_eq!(
            hmac_verifier("", "").verify(auth_header(GOLDEN), &ok_path, NOW),
            Err(ServiceAuthDenial::NoTokenConfigured),
            "an empty receiver token fails closed, even for an empty-key signature"
        );
    }

    #[test]
    fn verifier_honours_the_rotation_window() {
        let request = signed("/v1/keys/verify", br#"{"key":"abc"}"#);
        let header = auth_header(GOLDEN);
        assert_eq!(
            hmac_verifier("new-token", "test-token").verify(&header, &request, NOW),
            Ok(())
        );
        assert_eq!(
            hmac_verifier("new-token", "").verify(&header, &request, NOW),
            Err(ServiceAuthDenial::Mismatch)
        );
    }

    #[test]
    fn static_verifier_compares_the_plain_token() {
        let v = ServiceAuthVerifier {
            current: "cur",
            prev: "old",
            hmac: false,
            skew_secs: 120,
        };
        let request = signed("/v1/query", b"");
        let token =
            |value: &'static str| move |name: &str| (name == "x-service-token").then_some(value);
        assert_eq!(v.verify(token("cur"), &request, NOW), Ok(()));
        assert_eq!(v.verify(token("old"), &request, NOW), Ok(()));
        assert_eq!(
            v.verify(token("other"), &request, NOW),
            Err(ServiceAuthDenial::Mismatch)
        );
        assert_eq!(
            v.verify(auth_header(GOLDEN), &request, NOW),
            Err(ServiceAuthDenial::Missing),
            "static mode does not read X-Service-Auth"
        );
    }
}
