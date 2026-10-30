//! MySQL mount TLS posture (G5b-C10).
//!
//! mysql_async verifies chain and hostname once a DSN asks for TLS
//! (`require_ssl=true`); its only bypasses are `verify_ca=false` and
//! `verify_identity=false`. The parsed options are checked, never the DSN text:
//! the URL parser percent-decodes keys, so `verify%5Fca=false` would slip past a
//! substring match. A DSN without `require_ssl` stays plaintext, as before.

use data_plane_core::TlsPosture;
use mysql_async::SslOpts;

use super::*;

/// The TLS options a mount connects with. Under `max_security` a mount that
/// disables verification is refused. `ca_pem` (`DATA_PLANE_TLS_CA_FILE`) is
/// trusted on top of the built-in roots and the DSN's own.
pub(super) fn mysql_ssl_opts(
    ssl: Option<&SslOpts>,
    max_security: bool,
    ca_pem: Option<Vec<u8>>,
) -> DataPlaneResult<Option<SslOpts>> {
    let Some(ssl) = ssl else {
        return Ok(None);
    };
    if max_security && (ssl.accept_invalid_certs() || ssl.skip_domain_validation()) {
        return Err(DataPlaneError::Backend {
            message: "SECURITY_MODE=max refuses a mount whose DSN disables TLS verification \
                      (verify_ca=false or verify_identity=false)"
                .to_string(),
        });
    }
    let Some(pem) = ca_pem else {
        return Ok(Some(ssl.clone()));
    };
    let mut roots = ssl.root_certs().to_vec();
    roots.push(pem.into());
    Ok(Some(ssl.clone().with_root_certs(roots)))
}

/// The probe's TLS label for the options `open_pool` connected with (devil G4 P4).
///
/// Read off the PARSED options, never the DSN text: the URL parser
/// percent-decodes keys, so `verify%5Fca=false` would slip past a substring
/// match. A mount that asked for no TLS is `Plaintext`; one that asked for TLS
/// but disabled verification (chain or host name) is `Encrypted`; the rest is
/// `Verified`. The server's own answer never moves this label.
pub(super) fn ssl_posture(ssl: Option<&SslOpts>) -> TlsPosture {
    let Some(ssl) = ssl else {
        return TlsPosture::Plaintext;
    };
    if ssl.accept_invalid_certs() || ssl.skip_domain_validation() {
        return TlsPosture::Encrypted;
    }
    TlsPosture::Verified
}

/// `DATA_PLANE_TLS_CA_FILE`, read now so a bad path fails the open, not the first query.
pub(super) fn tls_ca_pem() -> DataPlaneResult<Option<Vec<u8>>> {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn ssl_of(dsn: &str) -> Option<SslOpts> {
        Opts::from_url(dsn).unwrap().ssl_opts().cloned()
    }

    #[test]
    fn max_refuses_each_verification_bypass_even_percent_encoded() {
        for dsn in [
            "mysql://u:p@h/d?require_ssl=true&verify_ca=false",
            "mysql://u:p@h/d?require_ssl=true&verify_identity=false",
            "mysql://u:p@h/d?require_ssl=true&verify%5Fca=false",
        ] {
            let ssl = ssl_of(dsn);
            assert!(mysql_ssl_opts(ssl.as_ref(), true, None).is_err(), "{dsn}");
            assert!(mysql_ssl_opts(ssl.as_ref(), false, None).is_ok(), "{dsn}");
        }
    }

    #[test]
    fn verified_and_plaintext_mounts_open_under_max() {
        let ssl = ssl_of("mysql://u:p@h/d?require_ssl=true");
        assert!(mysql_ssl_opts(ssl.as_ref(), true, None).unwrap().is_some());
        assert!(mysql_ssl_opts(None, true, None).unwrap().is_none());
    }

    #[test]
    fn the_ca_file_is_added_to_the_roots_only_for_a_tls_mount() {
        let ssl = ssl_of("mysql://u:p@h/d?require_ssl=true");
        let pem = b"-----BEGIN CERTIFICATE-----\n".to_vec();
        let out = mysql_ssl_opts(ssl.as_ref(), true, Some(pem.clone())).unwrap();
        let expected = SslOpts::default().with_root_certs(vec![pem.clone().into()]);
        assert_eq!(out.unwrap().root_certs(), expected.root_certs());
        assert!(mysql_ssl_opts(None, true, Some(pem)).unwrap().is_none());
    }

    #[test]
    fn the_posture_follows_the_options_the_pool_opened_with() {
        // No `require_ssl` → the pool connects in the clear.
        let ssl = ssl_of("mysql://u:p@h/d");
        assert_eq!(ssl_posture(ssl.as_ref()), TlsPosture::Plaintext);
        assert_eq!(ssl_posture(None), TlsPosture::Plaintext);
        // `require_ssl` alone → the chain and the host name are verified.
        let ssl = ssl_of("mysql://u:p@h/d?require_ssl=true");
        assert_eq!(ssl_posture(ssl.as_ref()), TlsPosture::Verified);
        // Either bypass downgrades the label to encrypted-but-unverified.
        let ssl = ssl_of("mysql://u:p@h/d?require_ssl=true&verify_ca=false");
        assert_eq!(ssl_posture(ssl.as_ref()), TlsPosture::Encrypted);
        let ssl = ssl_of("mysql://u:p@h/d?require_ssl=true&verify_identity=false");
        assert_eq!(ssl_posture(ssl.as_ref()), TlsPosture::Encrypted);
    }
}
