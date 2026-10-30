/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   redis_tls.rs                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 14:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 14:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! D3 (ADR 0024): the one `redis::Client` constructor for every Rust Redis dial
//! (the pool engine and the server's limiter / quota / metering link), so the
//! `rediss://` trust rules exist once. `rediss://` is the opt-in; a `redis://`
//! URL is built exactly as before and reads no TLS setting.

use ::redis::{
    Client, ConnectionAddr, ErrorKind, IntoConnectionInfo, RedisError, RedisResult, TlsCertificates,
};

/// A client for `url`. For `rediss://`: `#insecure` is refused (R6), the crypto
/// provider is installed (R5), and `DATA_PLANE_TLS_CA_FILE` is ADDED to the system
/// store, because redis replaces its store with any `root_cert` it is handed.
pub fn redis_client(url: &str) -> RedisResult<Client> {
    let info = url.into_connection_info()?;
    let ConnectionAddr::TcpTls { insecure, .. } = &info.addr else {
        return Client::open(info);
    };
    refuse_insecure(*insecure, crate::tls::max_security(), insecure_opt_in())?;
    crate::tls::ensure_crypto_provider();
    let Some(ca) = crate::tls::tls_ca_pem().map_err(setup_error)? else {
        return Client::open(info);
    };
    let roots = crate::tls::root_bundle(crate::tls::native_roots(), &ca).map_err(setup_error)?;
    let certificates = TlsCertificates {
        client_tls: None,
        root_cert: Some(roots),
    };
    Client::build_with_tls(info, certificates)
}

/// `#insecure` skips certificate verification. Never under `SECURITY_MODE=max`;
/// elsewhere only with `DATA_PLANE_TLS_INSECURE=1`, the mssql opt-in. Even then the
/// crate refuses at connect: `tls-rustls-insecure` is not compiled in.
fn refuse_insecure(insecure: bool, max_security: bool, opted_in: bool) -> RedisResult<()> {
    if !insecure {
        return Ok(());
    }
    let why = if max_security {
        "SECURITY_MODE=max refuses it"
    } else if !opted_in {
        "set DATA_PLANE_TLS_INSECURE=1 to allow it outside SECURITY_MODE=max"
    } else {
        return Ok(());
    };
    Err(RedisError::from((
        ErrorKind::InvalidClientConfig,
        "rediss:// #insecure disables certificate verification",
        why.to_string(),
    )))
}

fn insecure_opt_in() -> bool {
    std::env::var("DATA_PLANE_TLS_INSECURE").is_ok_and(|v| v == "1")
}

fn setup_error(e: data_plane_core::DataPlaneError) -> RedisError {
    RedisError::from((
        ErrorKind::InvalidClientConfig,
        "rediss:// TLS setup failed",
        e.to_string(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insecure_is_refused_unless_opted_in_and_never_under_max() {
        assert!(
            refuse_insecure(false, true, false).is_ok(),
            "verified TLS passes"
        );
        assert!(refuse_insecure(true, false, false).is_err(), "no opt-in");
        assert!(
            refuse_insecure(true, true, true).is_err(),
            "max wins over the opt-in"
        );
        assert!(
            refuse_insecure(true, false, true).is_ok(),
            "opted in, baseline"
        );
    }

    #[test]
    fn a_plain_url_stays_plain_tcp() {
        let client = redis_client("redis://127.0.0.1:6379/0").expect("client");
        let ConnectionAddr::Tcp(host, 6379) = &client.get_connection_info().addr else {
            panic!("plain tcp expected");
        };
        assert_eq!(host, "127.0.0.1");
    }

    #[test]
    fn a_rediss_url_is_tls() {
        let client = redis_client("rediss://redis:6380/0").expect("client");
        let addr = &client.get_connection_info().addr;
        assert!(
            matches!(
                addr,
                ConnectionAddr::TcpTls {
                    insecure: false,
                    ..
                }
            ),
            "{addr:?}"
        );
    }

    #[test]
    fn an_insecure_fragment_is_refused_by_default() {
        let err = redis_client("rediss://redis:6380/0#insecure").expect_err("refused");
        assert!(
            err.to_string()
                .contains("#insecure disables certificate verification"),
            "{err}"
        );
    }
}
