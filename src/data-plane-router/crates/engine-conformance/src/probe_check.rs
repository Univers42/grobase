//! Live-probe check for [`crate::run_suite`] (ADR 0013): a dialing engine names
//! its server version, the two that send no request (dynamodb, http) report
//! `unknown`, and the TLS label is the one the pool's construction fixes.

use data_plane_core::{EnginePool, EngineProbe, TlsPosture};

pub(crate) async fn check_probe(pool: &dyn EnginePool, engine: &str) -> Result<(), String> {
    let probe = pool.probe().await.map_err(|e| format!("probe: {e}"))?;
    probe_verdict(engine, &probe)
}

fn probe_verdict(engine: &str, probe: &EngineProbe) -> Result<(), String> {
    let version = probe.server_version.as_str();
    let sends_no_request = matches!(engine, "dynamodb" | "http");
    if sends_no_request && version != "unknown" {
        return Err(format!("{engine} sent a request: version {version}"));
    }
    if !sends_no_request && !is_numeric_version(version) {
        return Err(format!("{engine} named no server version: {version}"));
    }
    let fixed = match engine {
        "redis" => Some(TlsPosture::Plaintext),
        "sqlite" => Some(TlsPosture::NotApplicable),
        _ => None,
    };
    match fixed {
        Some(want) if probe.tls != want => {
            Err(format!("{engine} tls {:?}, want {want:?}", probe.tls))
        }
        _ => Ok(()),
    }
}

fn is_numeric_version(v: &str) -> bool {
    !v.is_empty()
        && v.split('.').count() <= 4
        && v.split('.')
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn probe(version: &str, tls: TlsPosture) -> EngineProbe {
        EngineProbe {
            server_version: version.into(),
            tls,
            tls_version: None,
        }
    }

    #[test]
    fn dialing_engines_must_name_a_numeric_version() {
        assert!(probe_verdict("postgresql", &probe("16.4", TlsPosture::Verified)).is_ok());
        assert!(probe_verdict("postgresql", &probe("unknown", TlsPosture::Verified)).is_err());
        assert!(probe_verdict("mysql", &probe("11.4.2-MariaDB", TlsPosture::Plaintext)).is_err());
        assert!(probe_verdict("mongodb", &probe("1.2.3.4.5", TlsPosture::Plaintext)).is_err());
    }

    #[test]
    fn engines_that_send_no_request_report_unknown() {
        assert!(probe_verdict("dynamodb", &probe("unknown", TlsPosture::Plaintext)).is_ok());
        assert!(probe_verdict("http", &probe("1.0", TlsPosture::Verified)).is_err());
    }

    #[test]
    fn fixed_labels_hold() {
        assert!(probe_verdict("redis", &probe("7.2.4", TlsPosture::Plaintext)).is_ok());
        assert!(probe_verdict("redis", &probe("7.2.4", TlsPosture::Verified)).is_err());
        assert!(probe_verdict("sqlite", &probe("3.45.1", TlsPosture::Plaintext)).is_err());
    }
}
