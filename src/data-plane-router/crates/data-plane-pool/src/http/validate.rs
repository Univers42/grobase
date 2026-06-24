/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   validate.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:28:27 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:28:28 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Connection parsing, resource validation, and the SSRF guard.
//!
//! The SSRF classifier + `guard_and_resolve` are kept together here: a mount's
//! base URL is parsed, its host classified against every reserved IP range, and
//! the validated public IP(s) are returned so the caller can PIN them (defeating
//! a later DNS rebind).

use data_plane_core::{DataPlaneError, DataPlaneResult};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};

pub(super) const MAX_RESOURCE_LEN: usize = 128;

#[derive(Debug, Deserialize, Default)]
pub(super) struct HttpConnection {
    #[serde(rename = "baseUrl")]
    pub(super) base_url: String,
    #[serde(default)]
    pub(super) headers: Option<BTreeMap<String, String>>,
    #[serde(default)]
    pub(super) routes: Option<BTreeMap<String, String>>,
}

pub(super) fn validate_resource(resource: &str) -> DataPlaneResult<()> {
    if resource.is_empty() || resource.len() > MAX_RESOURCE_LEN {
        return Err(DataPlaneError::InvalidIdentifier {
            value: resource.to_string(),
        });
    }
    for b in resource.bytes() {
        if !(b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.' | b'/')) {
            return Err(DataPlaneError::InvalidIdentifier {
                value: resource.to_string(),
            });
        }
    }
    Ok(())
}

pub(super) fn parse_connection(raw: &str) -> DataPlaneResult<HttpConnection> {
    // Try JSON first.
    if let Ok(parsed) = serde_json::from_str::<HttpConnection>(raw) {
        if !is_http_url(&parsed.base_url) {
            return Err(DataPlaneError::Backend {
                message: "http baseUrl must be a fully qualified http(s) URL".to_string(),
            });
        }
        return Ok(parsed);
    }
    // Bare URL shorthand.
    if is_http_url(raw) {
        return Ok(HttpConnection {
            base_url: raw.to_string(),
            headers: None,
            routes: None,
        });
    }
    Err(DataPlaneError::Backend {
        message: "http connection_string must be JSON { baseUrl, ... } or a bare http(s) URL"
            .to_string(),
    })
}

pub(super) fn is_http_url(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://")
}

/// SSRF classifier: `true` for any address an outbound HTTP mount must NOT reach
/// — loopback, RFC-1918 private, link-local (incl. 169.254.169.254 cloud
/// metadata), CGNAT, unspecified/broadcast/documentation, IPv6 ULA + link-local,
/// and IPv4-mapped forms of all the above.
pub(super) fn is_blocked_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_unspecified()
                || v4.is_documentation()
                || v4.octets()[0] == 0
                || (v4.octets()[0] == 100 && (v4.octets()[1] & 0xc0) == 64) // 100.64/10 CGNAT
        }
        IpAddr::V6(v6) => {
            if let Some(mapped) = v6.to_ipv4_mapped() {
                return is_blocked_ip(IpAddr::V4(mapped));
            }
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || (v6.segments()[0] & 0xfe00) == 0xfc00 // fc00::/7 unique-local
                || (v6.segments()[0] & 0xffc0) == 0xfe80 // fe80::/10 link-local
        }
    }
}

fn ssrf_blocked(host: &str) -> DataPlaneError {
    DataPlaneError::Backend {
        message: format!(
            "http mount blocked: '{host}' resolves to an internal/reserved address (SSRF guard). \
             Set DATA_PLANE_HTTP_ALLOW_INTERNAL=1 only for trusted dev mocks."
        ),
    }
}

/// Validate an http mount's base URL against the SSRF guard and return the host
/// and its validated socket addresses to PIN (so a later DNS rebind cannot point
/// the client inward). `Ok(None)` when the dev escape is set (no check, no pin).
// ponytail: 51-line SSRF guard kept whole — escape/parse/host-deny/literal-IP/
// DNS-resolve are one security-critical sequence; splitting would scatter the
// classification and invite a bypass. Extract a helper only if a step grows.
pub async fn guard_and_resolve(
    base_url: &str,
) -> DataPlaneResult<Option<(String, Vec<SocketAddr>)>> {
    if std::env::var("DATA_PLANE_HTTP_ALLOW_INTERNAL")
        .ok()
        .as_deref()
        == Some("1")
    {
        return Ok(None);
    }
    let url = reqwest::Url::parse(base_url).map_err(|e| DataPlaneError::Backend {
        message: format!("http baseUrl parse: {e}"),
    })?;
    let host = url
        .host_str()
        .ok_or_else(|| DataPlaneError::Backend {
            message: "http baseUrl has no host".to_string(),
        })?
        .to_string();
    let lower = host.to_ascii_lowercase();
    if lower == "localhost"
        || lower == "metadata"
        || lower == "instance-data"
        || lower.ends_with(".local")
        || lower.ends_with(".internal")
    {
        return Err(ssrf_blocked(&host));
    }
    let port = url.port_or_known_default().unwrap_or(80);
    // Literal IP host → classify directly (no DNS).
    if let Ok(ip) = host.parse::<IpAddr>() {
        if is_blocked_ip(ip) {
            return Err(ssrf_blocked(&host));
        }
        return Ok(Some((host, vec![SocketAddr::new(ip, port)])));
    }
    // Hostname → resolve off the async runtime, validate EVERY A/AAAA record.
    let h = host.clone();
    let addrs: Vec<SocketAddr> = tokio::task::spawn_blocking(move || {
        (h.as_str(), port)
            .to_socket_addrs()
            .map(|it| it.collect::<Vec<_>>())
    })
    .await
    .map_err(|e| DataPlaneError::Backend {
        message: format!("ssrf resolve join: {e}"),
    })?
    .map_err(|e| DataPlaneError::Backend {
        message: format!("http host '{host}' did not resolve: {e}"),
    })?;
    if addrs.is_empty() {
        return Err(DataPlaneError::Backend {
            message: format!("http host '{host}' did not resolve"),
        });
    }
    for sa in &addrs {
        if is_blocked_ip(sa.ip()) {
            return Err(ssrf_blocked(&host));
        }
    }
    Ok(Some((host, addrs)))
}
