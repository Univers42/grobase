/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dynamodb_endpoint.rs                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 09:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 09:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Which endpoint a DynamoDB mount dials under `SECURITY_MODE=max` (ADR 0017,
//! T6/T7). aws-config gives a programmatic `endpoint_url` the `shared_config`
//! origin, so aws-sdk-dynamodb 1.104.0 lets `AWS_ENDPOINT_URL_DYNAMODB` (env or
//! profile) override even the DSN's `endpoint=` (`config.rs` `From<&SdkConfig>`).
//! Under max the endpoint is set on the service builder instead, which nothing
//! overrides: the dial is the DSN's `endpoint=`, or real AWS (https) when it has
//! none. The label is then exact, and the refusal can run before `loader.load()`.

use aws_config::SdkConfig;
use aws_sdk_dynamodb::config::Builder;
use data_plane_core::{DataPlaneError, DataPlaneResult, TlsPosture};

/// Refuse, under `max_security`, a mount whose posture is not `Verified`
/// (an `http://` or scheme-less endpoint). The message carries no DSN: it can
/// hold `access_key`/`secret_key`.
pub(crate) fn refuse_unverified(posture: TlsPosture, max_security: bool) -> DataPlaneResult<()> {
    if max_security && posture != TlsPosture::Verified {
        return Err(DataPlaneError::Backend {
            message: "SECURITY_MODE=max refuses a DynamoDB mount whose endpoint is not https://"
                .to_string(),
        });
    }
    Ok(())
}

/// The service config with the endpoint pinned to `endpoint` (the DSN's, or
/// `None` for real AWS), discarding whatever env or profile endpoint
/// `From<&SdkConfig>` resolved.
pub(crate) fn pinned_builder(conf: &SdkConfig, endpoint: Option<String>) -> Builder {
    let mut builder = Builder::from(conf);
    builder.set_endpoint_url(endpoint);
    builder
}

#[cfg(test)]
mod tests {
    use super::*;
    use aws_config::{BehaviorVersion, Region};
    use aws_sdk_dynamodb::config::Credentials;
    use std::net::TcpListener;
    use std::time::Duration;

    #[test]
    fn max_refuses_every_unverified_posture() {
        for posture in [TlsPosture::Plaintext, TlsPosture::Unknown] {
            let err = refuse_unverified(posture, true).unwrap_err().to_string();
            assert!(err.contains("SECURITY_MODE=max"), "{err}");
            assert!(refuse_unverified(posture, false).is_ok());
        }
        assert!(refuse_unverified(TlsPosture::Verified, true).is_ok());
    }

    fn listener() -> (TcpListener, String) {
        let l = TcpListener::bind("127.0.0.1:0").expect("bind");
        l.set_nonblocking(true).expect("nonblocking");
        let url = format!("http://{}", l.local_addr().expect("addr"));
        (l, url)
    }

    // The shared config resolves endpoint A, the way an env or profile endpoint
    // would; the pinned builder must send the request to B and never touch A.
    #[tokio::test]
    async fn pinned_builder_dials_the_dsn_endpoint_not_the_shared_one() {
        let (shared, shared_url) = listener();
        let (pinned, pinned_url) = listener();
        let conf = SdkConfig::builder()
            .behavior_version(BehaviorVersion::latest())
            .region(Region::new("us-east-1"))
            .endpoint_url(shared_url)
            .build();
        let config = pinned_builder(&conf, Some(pinned_url))
            .credentials_provider(Credentials::new("a", "b", None, None, "test"))
            .build();
        let client = aws_sdk_dynamodb::Client::from_conf(config);
        let _ = tokio::time::timeout(Duration::from_secs(2), client.list_tables().send()).await;
        assert!(
            pinned.accept().is_ok(),
            "the pinned endpoint got no connection"
        );
        assert!(shared.accept().is_err(), "the shared endpoint was dialled");
    }
}
