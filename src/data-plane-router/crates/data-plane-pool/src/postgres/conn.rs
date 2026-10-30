/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   conn.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:28:57 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 09:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! TLS posture + connection-pooler DSN repoint for the Postgres adapter.
//!
//! All pure (env reads aside): the pooler/TLS helpers take their inputs as
//! parameters so they unit-test without a DB. Used only by [`super::adapter`]'s
//! `open_pool`.

use super::sslmode;
use data_plane_core::{DataPlaneError, DataPlaneResult, TlsPosture};
use std::sync::Arc;

/// The TLS verification posture a mount's DSN opts into.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum TlsMode {
    /// `sslmode=require` — encrypt, do NOT verify the chain (libpq semantics).
    Require,
    /// `sslmode=verify-ca`/`verify-full` — verify the chain against the trust
    /// store (Phase 6). We always also check the hostname (stricter than bare
    /// verify-ca, which is a safe over-enforcement).
    Verify,
}

/// The TLS mode a mount connects with. Baseline follows the DSN: `require`
/// encrypts, `verify-*` verifies, anything else is `None` (the local NoTls
/// path). `SECURITY_MODE=max` verifies every mount (ADR 0017, T2): `require`,
/// `prefer` and no sslmode are upgraded, while `disable` and `allow` are refused.
/// `disable` states intent max forbids, and tokio-postgres rejects `allow` anyway.
pub(super) fn effective_tls_mode(
    dsn: &str,
    max_security: bool,
) -> DataPlaneResult<Option<TlsMode>> {
    let asked = sslmode::sslmode(dsn);
    let mode = match (asked.as_deref(), max_security) {
        (Some("verify-full" | "verify-ca"), _) => Some(TlsMode::Verify),
        (Some("require"), false) => Some(TlsMode::Require),
        (Some(refused @ ("disable" | "allow")), true) => {
            return Err(DataPlaneError::Backend {
                message: format!(
                    "SECURITY_MODE=max refuses a Postgres mount with sslmode={refused}"
                ),
            })
        }
        (_, true) => Some(TlsMode::Verify),
        (_, false) => None,
    };
    Ok(mode)
}

/// Make the handshake mandatory whenever a TLS connector is used (ADR 0017, T1).
/// tokio-postgres defaults to `Prefer`, which falls back to plaintext when the
/// server answers `N`, so a connector alone would label a plaintext channel
/// `Verified`. deadpool applies this after parsing the URL, so it also overrides
/// a DSN's `sslmode=prefer`.
pub(super) fn pin_tls(cfg: &mut deadpool_postgres::Config, mode: Option<TlsMode>) {
    if mode.is_some() {
        cfg.ssl_mode = Some(deadpool_postgres::SslMode::Require);
    }
}

/// The probe's TLS label for the mode `open_pool` connected with (devil G4 P4):
/// the connector's own choice, so the label can never drift from what actually
/// encrypted the channel. `None` (the NoTls path) is the honest `Plaintext`.
pub(super) fn tls_posture(mode: Option<TlsMode>) -> TlsPosture {
    match mode {
        Some(TlsMode::Verify) => TlsPosture::Verified,
        Some(TlsMode::Require) => TlsPosture::Encrypted,
        None => TlsPosture::Plaintext,
    }
}

/// The DSN tokio-postgres is handed: `sslmode=verify-full`/`verify-ca` become
/// `require`. tokio-postgres 0.7 knows only disable/prefer/require and refuses
/// the verify modes as "invalid connection string", so a mount asking for
/// verification could never open. Verification is the connector's job
/// ([`rustls_connector`] with [`TlsMode::Verify`], chosen from the ORIGINAL
/// DSN); `require` keeps the handshake mandatory, never a plaintext fallback.
pub(super) fn wire_dsn(dsn: &str) -> String {
    sslmode::rewrite_sslmode(
        dsn,
        |mode| mode == "verify-full" || mode == "verify-ca",
        "require",
    )
}

/// Track C / C1: the connection-pooler endpoint to dial, from
/// `DATA_PLANE_POOLER_URL`. `None` (unset/blank) is the default → the direct
/// path, byte-parity. A set value is a full DSN whose host:port is the pooler
/// (e.g. `postgres://…@supavisor:6543/…`); only its host:port is consumed (see
/// [`repoint_dsn_host`]). The env is fixed at process start, so reading it at
/// `open_pool` (per-pool, not per-request) is correct.
pub(super) fn pooler_url() -> Option<String> {
    match std::env::var("DATA_PLANE_POOLER_URL") {
        Ok(v) if !v.trim().is_empty() => Some(v),
        _ => None,
    }
}

/// Track C / C1: whether client-side prepared-statement/session reuse across
/// pooled checkouts is DISABLED (`DATA_PLANE_STATEMENT_CACHE=off`). Required
/// under a transaction-mode pooler. Default (unset / any non-`off` value, e.g.
/// `on`) → `false`, the direct path with no connection recycle query.
pub(super) fn statement_cache_off() -> bool {
    std::env::var("DATA_PLANE_STATEMENT_CACHE")
        .map(|v| v.trim().eq_ignore_ascii_case("off"))
        .unwrap_or(false)
}

/// Repoint a URL-form Postgres DSN's host:port to the pooler's, preserving the
/// original DSN's scheme, userinfo (user:password), database path and query
/// (`?sslmode=…&…`). The pooler authenticates the SAME role to the SAME upstream
/// database, so only the transport endpoint changes — the resolved credentials
/// and TLS posture are unchanged.
///
/// Conservative by construction:
/// * Only `postgres://` / `postgresql://` URL-form DSNs are rewritten. A keyword
///   DSN (`host=… port=… user=…`) or any unrecognized shape is returned
///   **unchanged** — never a silent half-rewrite that could point at the wrong
///   target. (The local stack + every gate use the URL form.)
/// * If the pooler URL has no parseable host:port, the original `dsn` is returned
///   unchanged (fail-safe: keep the proven direct target rather than dial a
///   malformed endpoint).
///
/// Pure (no env, no I/O) → unit-tested without a DB.
pub(super) fn repoint_dsn_host(dsn: &str, pooler_url: &str) -> String {
    let Some(authority) = pooler_authority(pooler_url) else {
        return dsn.to_string();
    };
    // Split the URL-form DSN into scheme://, the authority (userinfo@host:port),
    // and the remainder (/db?query). Only the host:port portion is replaced.
    for scheme in ["postgresql://", "postgres://"] {
        if let Some(rest) = dsn.strip_prefix(scheme) {
            // rest = [userinfo@]host[:port][/db][?query]. The authority ends at
            // the first '/' or '?'; everything from there is the tail.
            let tail_at = rest.find(['/', '?']).unwrap_or(rest.len());
            let (auth, tail) = rest.split_at(tail_at);
            // Preserve userinfo (user:password@) if present; replace only host:port.
            let userinfo = match auth.rfind('@') {
                Some(at) => &auth[..=at], // includes the trailing '@'
                None => "",
            };
            return format!("{scheme}{userinfo}{authority}{tail}");
        }
    }
    // Not a URL-form DSN (keyword form / unknown) → leave it exactly as resolved.
    dsn.to_string()
}

/// Extract `host:port` (the authority) from the pooler URL. Handles the URL form
/// (`postgres://[user:pass@]host:port/db?…`); returns `None` for anything without
/// a parseable host so the caller can fall back to the direct DSN.
fn pooler_authority(pooler_url: &str) -> Option<String> {
    let rest = pooler_url
        .strip_prefix("postgresql://")
        .or_else(|| pooler_url.strip_prefix("postgres://"))?;
    let auth_end = rest.find(['/', '?']).unwrap_or(rest.len());
    let auth = &rest[..auth_end];
    // Drop any userinfo from the pooler URL — only its host:port is used.
    let host_port = match auth.rfind('@') {
        Some(at) => &auth[at + 1..],
        None => auth,
    };
    if host_port.is_empty() {
        return None;
    }
    Some(host_port.to_string())
}

/// Build the rustls connector for the given TLS mode.
///
/// * [`TlsMode::Require`] keeps libpq `require` SEMANTICS: encrypt the channel,
///   do not verify the chain (a Supabase project cert chains to its project CA,
///   not a public root; `require` is what their own connection strings specify).
/// * [`TlsMode::Verify`] (Phase 6) does REAL verification: chain + hostname
///   against the Mozilla webpki roots PLUS an optional custom CA bundle
///   (`ca_file`, from `DATA_PLANE_TLS_CA_FILE`) for private/self-signed CAs.
pub(super) fn rustls_connector(
    mode: TlsMode,
    ca_file: &str,
) -> DataPlaneResult<tokio_postgres_rustls::MakeRustlsConnect> {
    let provider = rustls::crypto::ring::default_provider();
    let config = match mode {
        TlsMode::Verify => {
            let mut roots = rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            if !ca_file.is_empty() {
                let pem = std::fs::read(ca_file).map_err(|e| DataPlaneError::Backend {
                    message: format!("DATA_PLANE_TLS_CA_FILE read failed: {e}"),
                })?;
                let mut cursor = &pem[..];
                for cert in rustls_pemfile::certs(&mut cursor) {
                    let cert = cert.map_err(|e| DataPlaneError::Backend {
                        message: format!("custom CA parse failed: {e}"),
                    })?;
                    roots.add(cert).map_err(|e| DataPlaneError::Backend {
                        message: format!("custom CA add failed: {e}"),
                    })?;
                }
            }
            rustls::ClientConfig::builder_with_provider(provider.into())
                .with_safe_default_protocol_versions()
                .expect("ring provider supports the default TLS protocol versions")
                .with_root_certificates(roots)
                .with_no_client_auth()
        }
        TlsMode::Require => no_verify_config(provider),
    };
    Ok(tokio_postgres_rustls::MakeRustlsConnect::new(config))
}

/// The accept-any-cert config — encrypt only, no chain verification. ONLY used
/// for `sslmode=require` outside max mode (libpq parity).
fn no_verify_config(provider: rustls::crypto::CryptoProvider) -> rustls::ClientConfig {
    #[derive(Debug)]
    struct NoCertVerification(rustls::crypto::CryptoProvider);
    impl rustls::client::danger::ServerCertVerifier for NoCertVerification {
        fn verify_server_cert(
            &self,
            _end_entity: &rustls::pki_types::CertificateDer<'_>,
            _intermediates: &[rustls::pki_types::CertificateDer<'_>],
            _server_name: &rustls::pki_types::ServerName<'_>,
            _ocsp_response: &[u8],
            _now: rustls::pki_types::UnixTime,
        ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        }
        fn verify_tls12_signature(
            &self,
            message: &[u8],
            cert: &rustls::pki_types::CertificateDer<'_>,
            dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls12_signature(
                message,
                cert,
                dss,
                &self.0.signature_verification_algorithms,
            )
        }
        fn verify_tls13_signature(
            &self,
            message: &[u8],
            cert: &rustls::pki_types::CertificateDer<'_>,
            dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls13_signature(
                message,
                cert,
                dss,
                &self.0.signature_verification_algorithms,
            )
        }
        fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
            self.0.signature_verification_algorithms.supported_schemes()
        }
    }

    rustls::ClientConfig::builder_with_provider(provider.clone().into())
        .with_safe_default_protocol_versions()
        .expect("ring provider supports the default TLS protocol versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertVerification(provider)))
        .with_no_client_auth()
}

#[cfg(test)]
mod tests {
    // Each test imports the exact symbol it exercises via `use super::…` below.

    // ── Track C / C1: pooler DSN repoint (pure) ──────────────────────────────
    #[test]
    fn repoint_dsn_host_replaces_only_host_port() {
        use super::repoint_dsn_host;
        // Direct DSN's db/user/password/sslmode are preserved; only host:port moves.
        assert_eq!(
            repoint_dsn_host(
                "postgres://postgres:pw@postgres:5432/commerce?sslmode=require",
                "postgres://ignored:ignored@supavisor:6543/postgres"
            ),
            "postgres://postgres:pw@supavisor:6543/commerce?sslmode=require"
        );
        // postgresql:// scheme + no userinfo on the source DSN.
        assert_eq!(
            repoint_dsn_host("postgresql://db:5432/app", "postgres://pooler:6543/x"),
            "postgresql://pooler:6543/app"
        );
        // No path/query on the source DSN.
        assert_eq!(
            repoint_dsn_host("postgres://u:p@h:5432", "postgres://pgbouncer:6432/db"),
            "postgres://u:p@pgbouncer:6432"
        );
    }

    #[test]
    fn repoint_dsn_host_leaves_keyword_and_malformed_unchanged() {
        use super::repoint_dsn_host;
        // Keyword-form DSN is NOT URL-form → returned unchanged (never a half-rewrite).
        let kw = "host=db.x.supabase.co port=5432 user=u password=p sslmode=verify-full";
        assert_eq!(repoint_dsn_host(kw, "postgres://supavisor:6543/db"), kw);
        // A pooler URL with no parseable host → fall back to the direct DSN.
        let direct = "postgres://u:p@h:5432/db";
        assert_eq!(repoint_dsn_host(direct, "postgres:///onlydb"), direct);
        assert_eq!(repoint_dsn_host(direct, "not-a-url"), direct);
    }

    #[test]
    fn pooler_authority_extracts_host_port() {
        use super::pooler_authority;
        assert_eq!(
            pooler_authority("postgres://u:p@supavisor:6543/db?x=1").as_deref(),
            Some("supavisor:6543")
        );
        assert_eq!(
            pooler_authority("postgresql://pgbouncer:6432").as_deref(),
            Some("pgbouncer:6432")
        );
        assert_eq!(pooler_authority("postgres:///db").as_deref(), None);
        assert_eq!(pooler_authority("redis://x:6379").as_deref(), None);
    }

    #[test]
    fn verify_modes_reach_tokio_postgres_as_require() {
        use super::{effective_tls_mode, wire_dsn, TlsMode};
        use std::str::FromStr;
        for dsn in [
            "postgres://u:p@postgres:5432/db?sslmode=verify-full",
            "postgres://u:p@postgres:5432/db?sslmode=verify-ca&application_name=x",
            "host=postgres user=u sslmode=verify-full",
        ] {
            assert!(
                tokio_postgres::Config::from_str(dsn).is_err(),
                "{dsn} parses as-is"
            );
            let cfg = tokio_postgres::Config::from_str(&wire_dsn(dsn)).expect(dsn);
            assert_eq!(cfg.get_ssl_mode(), tokio_postgres::config::SslMode::Require);
            assert_eq!(
                effective_tls_mode(dsn, false).unwrap(),
                Some(TlsMode::Verify)
            );
        }
        let plain = "postgres://u:p@postgres:5432/db?sslmode=prefer";
        assert_eq!(wire_dsn(plain), plain);
    }

    #[test]
    fn baseline_tls_mode_follows_the_dsn() {
        use super::{effective_tls_mode, TlsMode};
        for (dsn, want) in [
            (
                "postgres://u:p@db.x.supabase.co:5432/db?sslmode=require",
                Some(TlsMode::Require),
            ),
            (
                "host=db.x.supabase.co sslmode=verify-full user=u",
                Some(TlsMode::Verify),
            ),
            ("postgres://postgres:pw@postgres:5432/commerce", None),
            ("postgres://u:p@h:5432/db?sslmode=prefer", None),
            ("postgres://u:p@h:5432/db?sslmode=disable", None),
            ("postgres://u:p@h:5432/db?sslmode=allow", None),
        ] {
            assert_eq!(effective_tls_mode(dsn, false).unwrap(), want, "{dsn}");
        }
    }

    // ADR 0017 T2/T5: max verifies every mount or refuses it; a CockroachDB DSN
    // (same adapter, often `--insecure`) gets the same decision.
    #[test]
    fn max_tls_mode_verifies_or_refuses() {
        use super::{effective_tls_mode, TlsMode};
        for dsn in [
            "postgres://u:p@h:5432/db?sslmode=require",
            "postgres://u:p@h:5432/db?sslmode=prefer",
            "postgres://postgres:pw@postgres:5432/commerce",
            "host=h user=u sslmode=verify-ca",
            "postgresql://root@crdb:26257/defaultdb",
        ] {
            assert_eq!(
                effective_tls_mode(dsn, true).unwrap(),
                Some(TlsMode::Verify),
                "{dsn}"
            );
        }
        for (dsn, mode) in [
            ("postgres://u:secret@h:5432/db?sslmode=disable", "disable"),
            ("host=h user=u password=secret sslmode=allow", "allow"),
            (
                "postgresql://root@crdb:26257/defaultdb?sslmode=disable",
                "disable",
            ),
        ] {
            let err = effective_tls_mode(dsn, true).unwrap_err().to_string();
            assert!(err.contains(&format!("sslmode={mode}")), "{err}");
            assert!(err.contains("SECURITY_MODE=max"), "{err}");
            assert!(
                !err.contains("secret") && !err.contains("@h"),
                "error leaks the DSN: {err}"
            );
        }
    }

    // ADR 0017 T1: every TLS mode reaches tokio-postgres as `Require`, so a server
    // answering `N` fails the dial instead of falling back to plaintext.
    #[test]
    fn tls_modes_pin_the_handshake() {
        use super::{effective_tls_mode, pin_tls, wire_dsn};
        use tokio_postgres::config::SslMode;
        for (dsn, max) in [
            ("postgres://u:p@h:5432/db", true),
            ("postgres://u:p@h:5432/db?sslmode=prefer", true),
            ("postgres://u:p@h:5432/db?sslmode=require", true),
            ("postgres://u:p@h:5432/db?sslmode=verify-full", true),
            ("postgres://u:p@h:5432/db?sslmode=require", false),
            ("postgres://u:p@h:5432/db?sslmode=verify-ca", false),
        ] {
            let mode = effective_tls_mode(dsn, max).unwrap();
            let mut cfg = deadpool_postgres::Config::new();
            cfg.url = Some(wire_dsn(dsn));
            pin_tls(&mut cfg, mode);
            let got = cfg.get_pg_config().expect(dsn).get_ssl_mode();
            assert_eq!(got, SslMode::Require, "{dsn} max={max}");
        }
        // Baseline NoTls stays untouched (T3).
        let mut cfg = deadpool_postgres::Config::new();
        pin_tls(&mut cfg, None);
        assert!(cfg.ssl_mode.is_none());
    }

    #[test]
    fn tls_posture_labels_each_mode() {
        use super::{tls_posture, TlsMode};
        use data_plane_core::TlsPosture;
        assert_eq!(tls_posture(Some(TlsMode::Verify)), TlsPosture::Verified);
        assert_eq!(tls_posture(Some(TlsMode::Require)), TlsPosture::Encrypted);
        assert_eq!(tls_posture(None), TlsPosture::Plaintext);
    }

    #[test]
    fn tls_posture_follows_the_effective_mode_not_the_dsn() {
        use super::{effective_tls_mode, tls_posture};
        use data_plane_core::TlsPosture;
        // The label composes with the mode open_pool would connect with:
        // SECURITY_MODE=max upgrades `require` → the probe says Verified.
        assert_eq!(
            tls_posture(effective_tls_mode("postgres://h/d?sslmode=require", true).unwrap()),
            TlsPosture::Verified
        );
        // Max upgrades a bare DSN too → Verified (T11).
        assert_eq!(
            tls_posture(effective_tls_mode("postgres://h/d", true).unwrap()),
            TlsPosture::Verified
        );
        // Baseline `require` encrypts without verifying → Encrypted.
        assert_eq!(
            tls_posture(effective_tls_mode("postgres://h/d?sslmode=require", false).unwrap()),
            TlsPosture::Encrypted
        );
    }
}
