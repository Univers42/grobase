/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   tls.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:31:58 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 14:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Shared TLS-posture guards for the engine adapters.
//!
//! `mysql_async` and the `mongodb` driver verify the server certificate BY
//! DEFAULT (both built on rustls); the only way to weaken that is a cert-bypass
//! parameter smuggled into a mount DSN (mongo `tlsInsecure=true`, mysql
//! `verify_ca=false`; mysql checks its parsed options, `mysql::tls`). Under
//! `SECURITY_MODE=max` such a mount must be REFUSED, not silently downgraded —
//! the max-mode guarantee the per-engine `open_pool` paths call. Postgres, MSSQL
//! and DynamoDB have their own dedicated posture (`postgres::effective_tls_mode`,
//! `mssql::apply_mssql_tls`, `dynamodb::endpoint_posture`; ADR 0017).
//!
//! Redis (ADR 0024) dials `rediss://` through rustls with the system store, and
//! `DATA_PLANE_TLS_CA_FILE` ADDED to it by `root_bundle`: the crate replaces its
//! store with any `root_cert` it is given. `#insecure` is refused in
//! `crate::redis_tls`, before the crate sees it.

use data_plane_core::{DataPlaneError, DataPlaneResult};

/// `true` when the data plane runs under `SECURITY_MODE=max`.
#[cfg_attr(
    not(any(
        feature = "mongodb",
        feature = "redis-tls",
        feature = "mysql",
        feature = "postgres",
        feature = "dynamodb"
    )),
    allow(dead_code)
)]
pub(crate) fn max_security() -> bool {
    std::env::var("SECURITY_MODE")
        .map(|v| v.eq_ignore_ascii_case("max"))
        .unwrap_or(false)
}

/// Refuse a DSN that carries a known cert-bypass parameter when `max_security`.
/// Pure (mode is a parameter) so it unit-tests without env races. No-op outside
/// max, where baseline keeps libpq-style flexibility for self-signed dev mounts.
#[cfg_attr(not(feature = "mongodb"), allow(dead_code))]
pub(crate) fn reject_insecure_tls(
    dsn: &str,
    max_security: bool,
    bad_params: &[&str],
) -> DataPlaneResult<()> {
    if !max_security {
        return Ok(());
    }
    let lower = dsn.to_ascii_lowercase();
    if let Some(bad) = bad_params.iter().find(|b| lower.contains(*b)) {
        return Err(DataPlaneError::Backend {
            message: format!(
                "SECURITY_MODE=max refuses a mount whose DSN disables TLS verification ('{bad}')"
            ),
        });
    }
    Ok(())
}

/// `DATA_PLANE_TLS_CA_FILE`, read now so a bad path fails the open, not the first query.
#[cfg(any(feature = "mysql", feature = "redis-tls"))]
pub(crate) fn tls_ca_pem() -> DataPlaneResult<Option<Vec<u8>>> {
    let path = std::env::var("DATA_PLANE_TLS_CA_FILE").unwrap_or_default();
    if path.is_empty() {
        return Ok(None);
    }
    std::fs::read(&path)
        .map(Some)
        .map_err(|e| DataPlaneError::Backend {
            message: format!("DATA_PLANE_TLS_CA_FILE read failed: {e}"),
        })
}

/// Install ring as rustls's process-wide crypto provider (idempotent: `Err` means one is
/// already installed). A build linking both ring and aws-lc-rs (`--features dynamodb`)
/// leaves rustls no default, so a driver calling `ClientConfig::builder()` (mysql_async
/// 0.37, redis 0.27 on `rediss://`) panics on connect. Public so the server installs it
/// at startup; each such driver path also calls it, for library callers.
pub fn ensure_crypto_provider() {
    #[cfg(any(feature = "postgres", feature = "mysql", feature = "redis-tls"))]
    let _ = rustls::crypto::ring::default_provider().install_default();
}

/// The system store, for `root_bundle`.
///
/// Caveat: a scratch image has no store (Dockerfile.nano/.one; neither links redis
/// today), so this is empty and only the CA is trusted: a public `rediss://` host
/// is refused, fail closed. An unreadable store is logged and treated the same way,
/// never as "trust anything". `SSL_CERT_FILE` / `SSL_CERT_DIR` override the probe.
#[cfg(feature = "redis-tls")]
pub(crate) fn native_roots() -> Vec<rustls::pki_types::CertificateDer<'static>> {
    rustls_native_certs::load_native_certs().unwrap_or_else(|e| {
        tracing::warn!(error = %e, "system trust store unreadable: only DATA_PLANE_TLS_CA_FILE is trusted");
        Vec::new()
    })
}

/// `native` plus every certificate of `ca_pem`, as one PEM bundle. Adding, not
/// replacing, so a CA mount keeps public hosts verifiable. A CA file that holds no
/// certificate, or one rustls refuses as an anchor, is an error naming the file.
#[cfg(feature = "redis-tls")]
pub(crate) fn root_bundle(
    native: Vec<rustls::pki_types::CertificateDer<'static>>,
    ca_pem: &[u8],
) -> DataPlaneResult<Vec<u8>> {
    let mut anchors = native;
    anchors.extend(ca_anchors(ca_pem)?);
    Ok(pem_encode(&anchors))
}

#[cfg(feature = "redis-tls")]
fn ca_anchors(pem: &[u8]) -> DataPlaneResult<Vec<rustls::pki_types::CertificateDer<'static>>> {
    let ca_error = |why: String| DataPlaneError::Backend {
        message: format!("DATA_PLANE_TLS_CA_FILE {why}"),
    };
    let certs = rustls_pemfile::certs(&mut &pem[..])
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| ca_error(format!("is not PEM: {e}")))?;
    if certs.is_empty() {
        return Err(ca_error("holds no certificate".into()));
    }
    let mut store = rustls::RootCertStore::empty();
    for cert in &certs {
        store.add(cert.clone()).map_err(|e| {
            ca_error(format!(
                "holds a certificate that is not a trust anchor: {e}"
            ))
        })?;
    }
    Ok(certs)
}

#[cfg(feature = "redis-tls")]
fn pem_encode(certs: &[rustls::pki_types::CertificateDer<'_>]) -> Vec<u8> {
    use base64::Engine as _;
    let mut out = String::with_capacity(certs.iter().map(|c| c.len() * 4 / 3 + 80).sum());
    for cert in certs {
        let body = base64::engine::general_purpose::STANDARD.encode(cert.as_ref());
        out.push_str("-----BEGIN CERTIFICATE-----\n");
        let mut rest = body.as_str();
        while !rest.is_empty() {
            let (line, tail) = rest.split_at(rest.len().min(64));
            out.push_str(line);
            out.push('\n');
            rest = tail;
        }
        out.push_str("-----END CERTIFICATE-----\n");
    }
    out.into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The exact call mysql_async makes for a TLS mount. Only a `--features dynamodb`
    /// build (ring + aws-lc-rs) panics without `ensure_crypto_provider`.
    #[cfg(feature = "mysql")]
    #[test]
    fn tls_client_config_builds_once_provider_is_installed() {
        ensure_crypto_provider();
        let _ = rustls::ClientConfig::builder()
            .with_root_certificates(rustls::RootCertStore::empty())
            .with_no_client_auth();
    }

    const MONGO_BAD: &[&str] = &["tlsinsecure=true", "tlsallowinvalidcertificates=true"];

    #[test]
    fn baseline_allows_insecure() {
        assert!(reject_insecure_tls("mongodb://h/?tlsInsecure=true", false, MONGO_BAD).is_ok());
    }

    #[test]
    fn max_rejects_insecure() {
        assert!(reject_insecure_tls("mongodb://h/?tlsInsecure=true", true, MONGO_BAD).is_err());
    }

    #[test]
    fn max_allows_clean() {
        assert!(reject_insecure_tls("mongodb://h/?tls=true", true, MONGO_BAD).is_ok());
    }

    #[cfg(feature = "redis-tls")]
    mod bundle {
        use super::super::root_bundle;
        use rustls::pki_types::CertificateDer;

        const PUBLIC: &[u8] = include_bytes!("testdata/public-root.pem");
        const PRIVATE_CA: &[u8] = include_bytes!("testdata/private-ca.pem");

        fn certs(pem: &[u8]) -> Vec<CertificateDer<'static>> {
            rustls_pemfile::certs(&mut &pem[..])
                .map(|c| c.expect("pem"))
                .collect()
        }

        /// Exactly what redis does with `root_cert` (redis 0.27.6 tls.rs:93-105).
        fn redis_store(bundle: &[u8]) -> rustls::RootCertStore {
            let mut store = rustls::RootCertStore::empty();
            for cert in certs(bundle) {
                store.add(cert).expect("anchor");
            }
            store
        }

        #[test]
        fn public_roots_stay_in_the_store_when_the_ca_is_set() {
            let bundle = root_bundle(certs(PUBLIC), PRIVATE_CA).expect("bundle");
            assert_eq!(redis_store(&bundle).len(), 2);
            let inside = certs(&bundle);
            assert!(inside.contains(&certs(PUBLIC)[0]), "public root kept");
            assert!(inside.contains(&certs(PRIVATE_CA)[0]), "CA added");
        }

        #[test]
        fn an_empty_system_store_trusts_only_the_ca() {
            let bundle = root_bundle(Vec::new(), PRIVATE_CA).expect("bundle");
            assert_eq!(certs(&bundle), certs(PRIVATE_CA));
        }

        #[test]
        fn a_ca_file_without_a_certificate_is_refused() {
            let err = root_bundle(certs(PUBLIC), b"not a pem file").expect_err("refused");
            assert!(err.to_string().contains("holds no certificate"), "{err}");
        }

        #[test]
        fn a_ca_file_with_a_broken_certificate_is_refused() {
            let junk = b"-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n";
            let err = root_bundle(Vec::new(), junk).expect_err("refused");
            assert!(err.to_string().contains("not a trust anchor"), "{err}");
        }
    }
}
