/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   keyring.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 16:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 16:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Which of several keys signed a request (D1, ADR 0023). The wire format is
//! the v1 scheme unchanged; a receiver that gives each caller its own key
//! learns the caller from the key that verifies.

use super::{compute_service_auth_at, ct_eq, ServiceAuthDenial, SignedRequest};

/// A receiver's keys, in the order the caller wants them reported. An empty
/// key never matches, so an unset `_PREV` cannot be signed with the empty key.
/// At most 64 keys are compared; a 65th and later never match.
pub struct KeyRing<'a> {
    pub keys: &'a [&'a str],
    pub hmac: bool,
    pub skew_secs: i64,
}

impl KeyRing<'_> {
    /// The index of the first key that verifies. Every key is compared before
    /// the answer is picked, so timing does not say which key matched.
    ///
    /// # Errors
    /// `NoTokenConfigured` when every key is empty; otherwise the
    /// [`ServiceAuthDenial`] that names why no key verified.
    pub fn identify<'h>(
        &self,
        header: impl Fn(&str) -> Option<&'h str>,
        request: &SignedRequest<'_>,
        now: i64,
    ) -> Result<usize, ServiceAuthDenial> {
        if self.keys.iter().all(|k| k.is_empty()) {
            return Err(ServiceAuthDenial::NoTokenConfigured);
        }
        let matched = if self.hmac {
            let presented = header("x-service-auth").ok_or(ServiceAuthDenial::Missing)?;
            self.signed_matches(presented, request, now)?
        } else {
            let presented = header("x-service-token").ok_or(ServiceAuthDenial::Missing)?;
            self.mask(|key| ct_eq(presented, key))
        };
        if matched == 0 {
            return Err(ServiceAuthDenial::Mismatch);
        }
        Ok(matched.trailing_zeros() as usize)
    }

    fn signed_matches(
        &self,
        presented: &str,
        request: &SignedRequest<'_>,
        now: i64,
    ) -> Result<u64, ServiceAuthDenial> {
        let ts = signature_ts(presented)?;
        if ts < now - self.skew_secs || ts > now + self.skew_secs {
            return Err(ServiceAuthDenial::Stale);
        }
        let SignedRequest { method, path, body } = *request;
        Ok(self.mask(|key| {
            ct_eq(
                presented,
                &compute_service_auth_at(key, method, path, body, ts),
            )
        }))
    }

    /// Bit `i` set when key `i` is non-empty and `matches` it. `&` instead of
    /// `&&` so no comparison is skipped.
    fn mask(&self, matches: impl Fn(&str) -> bool) -> u64 {
        self.keys
            .iter()
            .take(64)
            .enumerate()
            .fold(0u64, |acc, (i, key)| {
                acc | (u64::from(matches(key) & !key.is_empty()) << i)
            })
    }
}

/// The timestamp of a `v1.<ts>.<hex>` value.
fn signature_ts(presented: &str) -> Result<i64, ServiceAuthDenial> {
    match presented.split('.').collect::<Vec<_>>().as_slice() {
        ["v1", ts, _] => ts.parse::<i64>().map_err(|_| ServiceAuthDenial::Malformed),
        _ => Err(ServiceAuthDenial::Malformed),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_700_000_000;
    const BODY: &[u8] = b"{\"a\":1}";

    fn request() -> SignedRequest<'static> {
        SignedRequest {
            method: "POST",
            path: "/v1/query",
            body: BODY,
        }
    }

    fn ring<'a>(keys: &'a [&'a str], hmac: bool) -> KeyRing<'a> {
        KeyRing {
            keys,
            hmac,
            skew_secs: 120,
        }
    }

    fn signed_by(key: &str) -> String {
        compute_service_auth_at(key, "POST", "/v1/query", BODY, NOW)
    }

    #[test]
    fn the_key_that_verifies_is_the_one_reported() {
        let keys = ["legacy", "", "qr-key", "qr-prev", "tc-key", ""];
        for (key, want) in [("legacy", 0), ("qr-key", 2), ("qr-prev", 3), ("tc-key", 4)] {
            let sig = signed_by(key);
            let header = |name: &str| (name == "x-service-auth").then_some(sig.as_str());
            assert_eq!(
                ring(&keys, true).identify(header, &request(), NOW),
                Ok(want)
            );
        }
    }

    #[test]
    fn an_empty_key_never_matches_even_signed_with_the_empty_key() {
        let sig = signed_by("");
        let header = |name: &str| (name == "x-service-auth").then_some(sig.as_str());
        let keys = ["legacy", ""];
        assert_eq!(
            ring(&keys, true).identify(header, &request(), NOW),
            Err(ServiceAuthDenial::Mismatch)
        );
        let plain = |name: &str| (name == "x-service-token").then_some("");
        assert_eq!(
            ring(&keys, false).identify(plain, &request(), NOW),
            Err(ServiceAuthDenial::Mismatch)
        );
    }

    #[test]
    fn denials_keep_their_order_and_names() {
        let keys = ["k1", "k2"];
        let r = ring(&keys, true);
        assert_eq!(
            r.identify(|_| None, &request(), NOW),
            Err(ServiceAuthDenial::Missing)
        );
        let bad = |name: &str| (name == "x-service-auth").then_some("v1.x.y");
        assert_eq!(
            r.identify(bad, &request(), NOW),
            Err(ServiceAuthDenial::Malformed)
        );
        let sig = signed_by("k2");
        let late = |name: &str| (name == "x-service-auth").then_some(sig.as_str());
        assert_eq!(
            r.identify(late, &request(), NOW + 121),
            Err(ServiceAuthDenial::Stale)
        );
        assert_eq!(
            ring(&["", ""], true).identify(late, &request(), NOW),
            Err(ServiceAuthDenial::NoTokenConfigured)
        );
    }

    #[test]
    fn static_mode_compares_the_plain_token_against_every_key() {
        let keys = ["legacy", "qr-key"];
        let plain = |name: &str| (name == "x-service-token").then_some("qr-key");
        assert_eq!(ring(&keys, false).identify(plain, &request(), NOW), Ok(1));
        let other = |name: &str| (name == "x-service-token").then_some("qr-ke");
        assert_eq!(
            ring(&keys, false).identify(other, &request(), NOW),
            Err(ServiceAuthDenial::Mismatch)
        );
    }
}
