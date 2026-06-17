//! Shared TLS-posture guards for the engine adapters.
//!
//! `mysql_async`, the `mongodb` driver and the `redis` crate verify the server
//! certificate BY DEFAULT; the only way to weaken that is a cert-bypass
//! parameter smuggled into a mount DSN (mongo `tlsInsecure=true`, redis
//! `rediss://…#insecure`, …). Under `SECURITY_MODE=max` such a mount must be
//! REFUSED, not silently downgraded — the max-mode guarantee the per-engine
//! `open_pool` paths call. Postgres/MSSQL have their own dedicated posture
//! (`postgres::effective_tls_mode`, `mssql::apply_mssql_tls`).

use data_plane_core::{DataPlaneError, DataPlaneResult};

/// `true` when the data plane runs under `SECURITY_MODE=max`.
#[cfg_attr(not(any(feature = "mongodb", feature = "redis")), allow(dead_code))]
pub(crate) fn max_security() -> bool {
    std::env::var("SECURITY_MODE")
        .map(|v| v.eq_ignore_ascii_case("max"))
        .unwrap_or(false)
}

/// Refuse a DSN that carries a known cert-bypass parameter when `max_security`.
/// Pure (mode is a parameter) so it unit-tests without env races. No-op outside
/// max, where baseline keeps libpq-style flexibility for self-signed dev mounts.
#[cfg_attr(not(any(feature = "mongodb", feature = "redis")), allow(dead_code))]
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

#[cfg(test)]
mod tests {
    use super::*;

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
        assert!(reject_insecure_tls("rediss://h/0", true, &["#insecure"]).is_ok());
    }

    #[test]
    fn max_rejects_redis_insecure_fragment() {
        assert!(reject_insecure_tls("rediss://h/0#insecure", true, &["#insecure"]).is_err());
    }
}
