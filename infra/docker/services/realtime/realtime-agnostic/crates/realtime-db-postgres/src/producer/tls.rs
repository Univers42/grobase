/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   tls.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 07:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 07:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! TLS posture for the `PostgreSQL` producer, opted into by the DSN's `sslmode`.
//!
//! A copy of `src/data-plane-router/crates/data-plane-pool/src/postgres/conn.rs`
//! (`TlsMode`, `effective_tls_mode`, `wire_dsn`, `rustls_connector`): the
//! realtime workspace is its own Cargo workspace and Docker build context, so
//! it cannot depend on the pool crate. One deliberate difference: `sslmode` is
//! PARSED the way tokio-postgres parses it, never found with `contains`. A
//! substring match reads a password holding `sslmode=verify-full` as the mode.

use std::ops::Range;
use std::sync::Arc;

use realtime_core::{RealtimeError, Result};
use tokio_postgres_rustls::MakeRustlsConnect;

/// The TLS verification posture a DSN opts into.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TlsMode {
    /// `sslmode=require`: encrypt, do NOT verify the chain (libpq semantics).
    Require,
    /// `sslmode=verify-ca` / `verify-full`: verify the chain and the hostname.
    Verify,
}

/// The DSN's `sslmode` value, decoded; `None` when it carries none.
pub fn sslmode(dsn: &str) -> Option<String> {
    find_sslmode(dsn).map(|(mode, _)| mode)
}

/// `None` keeps today's plaintext path. `prefer` is `None` on purpose: handing
/// a prefer DSN a connector would silently upgrade it to unverified TLS.
pub fn effective_tls_mode(dsn: &str, max_security: bool) -> Option<TlsMode> {
    match sslmode(dsn).as_deref() {
        Some("verify-full" | "verify-ca") => Some(TlsMode::Verify),
        Some("require") if max_security => Some(TlsMode::Verify),
        Some("require") => Some(TlsMode::Require),
        _ => None,
    }
}

/// `SECURITY_MODE=max`, as the data plane reads it.
pub fn max_security() -> bool {
    std::env::var("SECURITY_MODE").is_ok_and(|v| v.trim().eq_ignore_ascii_case("max"))
}

/// The DSN tokio-postgres is handed. tokio-postgres 0.7 refuses
/// `sslmode=verify-*` as an invalid connection string, so that value is
/// rewritten to `require` and verification is the connector's job. Only the
/// value's bytes change; the password and every other parameter are untouched.
pub fn wire_dsn(dsn: &str) -> String {
    let mut wired = dsn.to_owned();
    if let Some((mode, span)) = find_sslmode(dsn) {
        if mode == "verify-full" || mode == "verify-ca" {
            wired.replace_range(span, "require");
        }
    }
    wired
}

/// Where the effective `sslmode` sits: its decoded value and the byte span of
/// its raw text. The LAST occurrence wins, as tokio-postgres applies them in order.
fn find_sslmode(dsn: &str) -> Option<(String, Range<usize>)> {
    let Some(rest) = ["postgres://", "postgresql://"]
        .iter()
        .find_map(|scheme| dsn.strip_prefix(scheme))
    else {
        return find_in_key_values(dsn);
    };
    // tokio-postgres: credentials end at the FIRST '@', the query starts at
    // the first '?' after them. A '?' or '@' inside the password must be
    // percent-encoded, or tokio-postgres itself would split there.
    let authority = dsn.len() - rest.len() + rest.find('@').map_or(0, |at| at + 1);
    let query = authority + dsn[authority..].find('?')? + 1;
    let mut found = None;
    let mut pos = query;
    for pair in dsn[query..].split('&') {
        if let Some((key, value)) = pair.split_once('=') {
            if percent_decode(key) == "sslmode" {
                let start = pos + key.len() + 1;
                found = Some((percent_decode(value), start..start + value.len()));
            }
        }
        pos += pair.len() + 1;
    }
    found
}

/// The libpq `key = value` form: whitespace separates pairs, values may be
/// single-quoted, a backslash escapes the next character.
fn find_in_key_values(dsn: &str) -> Option<(String, Range<usize>)> {
    let bytes = dsn.as_bytes();
    let skip_space = |mut i: usize| {
        while bytes.get(i).is_some_and(u8::is_ascii_whitespace) {
            i += 1;
        }
        i
    };
    let mut found = None;
    let mut i = skip_space(0);
    while i < bytes.len() {
        let key_start = i;
        while bytes
            .get(i)
            .is_some_and(|b| !b.is_ascii_whitespace() && *b != b'=')
        {
            i += 1;
        }
        let key = &dsn[key_start..i];
        i = skip_space(i);
        if bytes.get(i) != Some(&b'=') {
            // Malformed; tokio-postgres refuses this DSN before any socket opens.
            return found;
        }
        let value_start = skip_space(i + 1);
        let (value, value_end) = read_value(bytes, value_start);
        if key == "sslmode" {
            found = Some((value, value_start..value_end));
        }
        i = skip_space(value_end);
    }
    found
}

/// One key=value value starting at `start`: its unescaped text and the index
/// just past it (past the closing quote when quoted).
fn read_value(bytes: &[u8], start: usize) -> (String, usize) {
    let quoted = bytes.get(start) == Some(&b'\'');
    let mut i = start + usize::from(quoted);
    let mut out = Vec::new();
    while let Some(&b) = bytes.get(i) {
        match b {
            b'\\' if i + 1 < bytes.len() => {
                out.push(bytes[i + 1]);
                i += 2;
            }
            b'\'' if quoted => return (String::from_utf8_lossy(&out).into_owned(), i + 1),
            b if !quoted && b.is_ascii_whitespace() => break,
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    (String::from_utf8_lossy(&out).into_owned(), i)
}

fn percent_decode(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = raw
            .get(i + 1..i + 3)
            .filter(|_| bytes[i] == b'%')
            .and_then(|h| u8::from_str_radix(h, 16).ok());
        if let Some(byte) = hex {
            out.push(byte);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The rustls connector for `mode` (ring provider, no aws-lc-rs). Verify trusts
/// the webpki roots plus every certificate in `ca_file` when it is set; a set
/// `ca_file` that cannot be read or holds no certificate is an error naming
/// it, never a silent fallback to roots-only or to plaintext.
pub fn rustls_connector(mode: TlsMode, ca_file: &str) -> Result<MakeRustlsConnect> {
    let provider = rustls::crypto::ring::default_provider();
    let config = match mode {
        TlsMode::Verify => {
            let mut roots = rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            if !ca_file.is_empty() {
                add_ca_file(&mut roots, ca_file)?;
            }
            rustls::ClientConfig::builder_with_provider(provider.into())
                .with_safe_default_protocol_versions()
                .map_err(|e| RealtimeError::Internal(format!("TLS protocol setup failed: {e}")))?
                .with_root_certificates(roots)
                .with_no_client_auth()
        }
        // Caveat: accepts ANY certificate (libpq sslmode=require semantics) — encryption without
        // authentication; SECURITY_MODE=max upgrades it to verification.
        TlsMode::Require => no_verify_config(provider)?,
    };
    Ok(MakeRustlsConnect::new(config))
}

fn add_ca_file(roots: &mut rustls::RootCertStore, ca_file: &str) -> Result<()> {
    let fail =
        |what: &str| RealtimeError::Internal(format!("REALTIME_PG_TLS_CA_FILE {ca_file}: {what}"));
    let pem = std::fs::read(ca_file).map_err(|e| fail(&format!("read failed: {e}")))?;
    let mut added = 0usize;
    for cert in rustls_pemfile::certs(&mut pem.as_slice()) {
        let cert = cert.map_err(|e| fail(&format!("parse failed: {e}")))?;
        roots
            .add(cert)
            .map_err(|e| fail(&format!("add failed: {e}")))?;
        added += 1;
    }
    if added == 0 {
        return Err(fail("holds no PEM certificate"));
    }
    Ok(())
}

/// The accept-any-cert config — encrypt only, no chain verification. Only for
/// `sslmode=require` outside max mode (libpq parity).
fn no_verify_config(provider: rustls::crypto::CryptoProvider) -> Result<rustls::ClientConfig> {
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
        ) -> std::result::Result<rustls::client::danger::ServerCertVerified, rustls::Error>
        {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        }
        fn verify_tls12_signature(
            &self,
            message: &[u8],
            cert: &rustls::pki_types::CertificateDer<'_>,
            dss: &rustls::DigitallySignedStruct,
        ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error>
        {
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
        ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error>
        {
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

    Ok(
        rustls::ClientConfig::builder_with_provider(provider.clone().into())
            .with_safe_default_protocol_versions()
            .map_err(|e| RealtimeError::Internal(format!("TLS protocol setup failed: {e}")))?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertVerification(provider)))
            .with_no_client_auth(),
    )
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use std::str::FromStr;

    use super::*;

    #[test]
    fn sslmode_is_parsed_not_matched() {
        let cases: &[(&str, Option<&str>)] = &[
            ("postgres://u:p@h/db?sslmode=require", Some("require")),
            (
                "postgresql://u:p@h/db?a=1&sslmode=verify-full&b=2",
                Some("verify-full"),
            ),
            ("host=h sslmode=require", Some("require")),
            ("host=h sslmode = require", Some("require")),
            ("host=h sslmode='verify-ca'", Some("verify-ca")),
            ("postgres://u:p%40ss@h/db?sslmode=require", Some("require")),
            ("postgres://u:p@h/db?ssl%6Dode=re%71uire", Some("require")),
            (
                "postgres://u:p@h/db?sslmode=disable&sslmode=require",
                Some("require"),
            ),
            ("postgres://u:p%3Fsslmode%3Dverify-full@h/db", None),
            ("host=h password='a sslmode=verify-full'", None),
            ("host=h password=a\\ sslmode=verify-full", None),
            ("postgres://u:p@h/db?application_name=sslmode", None),
            ("postgres://u:p@h/db", None),
            ("host=h dbname=d", None),
        ];
        for (dsn, want) in cases {
            assert_eq!(sslmode(dsn).as_deref(), *want, "{dsn}");
        }
    }

    #[test]
    fn only_require_and_verify_get_a_connector() {
        let cases: &[(&str, bool, Option<TlsMode>)] = &[
            ("host=h sslmode=verify-full", false, Some(TlsMode::Verify)),
            ("host=h sslmode=verify-ca", false, Some(TlsMode::Verify)),
            ("host=h sslmode=require", false, Some(TlsMode::Require)),
            ("host=h sslmode=require", true, Some(TlsMode::Verify)),
            ("host=h sslmode=prefer", false, None),
            ("host=h sslmode=prefer", true, None),
            ("host=h sslmode=allow", false, None),
            ("host=h sslmode=disable", true, None),
            ("host=h", true, None),
            ("host=h password='x sslmode=require'", false, None),
        ];
        for (dsn, max, want) in cases {
            assert_eq!(effective_tls_mode(dsn, *max), *want, "{dsn} max={max}");
        }
    }

    #[test]
    fn wire_dsn_rewrites_only_the_verify_value() {
        let cases: &[(&str, &str)] = &[
            (
                "postgres://u:p@h/db?a=1&sslmode=verify-full&b=2",
                "postgres://u:p@h/db?a=1&sslmode=require&b=2",
            ),
            (
                "host=h sslmode = 'verify-ca' user=u",
                "host=h sslmode = require user=u",
            ),
            ("host=h sslmode=require", "host=h sslmode=require"),
            (
                "postgres://u:p%3Fsslmode%3Dverify-full@h/db",
                "postgres://u:p%3Fsslmode%3Dverify-full@h/db",
            ),
            (
                "host=h password='a sslmode=verify-full'",
                "host=h password='a sslmode=verify-full'",
            ),
        ];
        for (dsn, want) in cases {
            assert_eq!(wire_dsn(dsn), *want, "{dsn}");
        }
    }

    #[test]
    fn tokio_postgres_refuses_verify_until_rewritten() {
        for dsn in [
            "postgres://u:p@h/db?sslmode=verify-full",
            "host=h user=u sslmode=verify-ca",
        ] {
            assert!(tokio_postgres::Config::from_str(dsn).is_err(), "{dsn}");
            let wired = tokio_postgres::Config::from_str(&wire_dsn(dsn)).expect("wired DSN parses");
            assert_eq!(
                wired.get_ssl_mode(),
                tokio_postgres::config::SslMode::Require
            );
        }
    }

    #[test]
    fn a_bad_ca_file_is_an_error_naming_it() {
        let missing = "/nonexistent/realtime-ca.pem";
        let err = rustls_connector(TlsMode::Verify, missing)
            .err()
            .expect("missing file");
        assert!(err.to_string().contains(missing), "{err}");

        let empty =
            std::env::temp_dir().join(format!("realtime-empty-ca-{}.pem", std::process::id()));
        std::fs::write(&empty, "# no certificate here\n").unwrap();
        let path = empty.to_str().unwrap().to_owned();
        let err = rustls_connector(TlsMode::Verify, &path)
            .err()
            .expect("empty PEM");
        std::fs::remove_file(&empty).unwrap();
        assert!(err.to_string().contains(&path), "{err}");
    }

    #[test]
    fn both_modes_build_without_a_ca_file() {
        assert!(rustls_connector(TlsMode::Verify, "").is_ok());
        assert!(rustls_connector(TlsMode::Require, "").is_ok());
    }
}
