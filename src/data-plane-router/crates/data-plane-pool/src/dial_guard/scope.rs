/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   scope.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 10:57:31 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 10:57:31 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The per-pool dial scope: who is dialling (engine, mount, tenant, provenance),
//! how names resolve, and how a refusal is reported. Every pinned engine dial
//! goes through `vet_host` / `vet_ip`; the engine then connects only to the
//! addresses returned.
//!
//! The log line carries engine, mount_id, tenant_id, provenance, class, ip,
//! port and host — host, mount_id and tenant_id Debug-escaped and capped at
//! 253 bytes. Never userinfo, query or password: callers pass the host the
//! driver parsed, never the DSN.

use super::classify::{classify, denied_name, DenyClass};
use super::DialGuardMode;
use crate::resolver::Provenance;
use data_plane_core::{DataPlaneError, DatabaseMount};
use futures::future::BoxFuture;
use std::net::IpAddr;

/// Longest DNS name (RFC 1035); also the cap on every caller-chosen field.
const FIELD_CAP: usize = 253;

/// Name resolution, swappable so tests can change the answer between dials.
pub(crate) type Lookup = fn(String, u16) -> BoxFuture<'static, std::io::Result<Vec<IpAddr>>>;

/// Caveat: the answer is whatever the system resolver returns at this moment.
/// A record that changes after this call is not seen until the next vet, but
/// the engine dials only the addresses returned here, so a rebind cannot
/// redirect a vetted dial — it can only leave a stale (still vetted) address.
fn system_lookup(host: String, port: u16) -> BoxFuture<'static, std::io::Result<Vec<IpAddr>>> {
    Box::pin(async move {
        let addrs = tokio::net::lookup_host((host.as_str(), port)).await?;
        Ok(addrs.map(|sa| sa.ip()).collect())
    })
}

/// One refused destination.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Refusal {
    pub(crate) class: DenyClass,
    pub(crate) ip: Option<IpAddr>,
    pub(crate) host: String,
    pub(crate) port: u16,
}

impl Refusal {
    pub(crate) fn new(class: DenyClass, ip: Option<IpAddr>, host: &str, port: u16) -> Self {
        Self {
            class,
            ip,
            host: host.to_string(),
            port,
        }
    }
}

#[cfg(test)]
pub(crate) static RECORDED: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// Every line reported for `mount_id` so far (tests only).
#[cfg(test)]
pub(crate) fn recorded_for(mount_id: &str) -> Vec<String> {
    let needle = format!("mount_id={mount_id:?} ");
    let lines = RECORDED.lock().expect("recorded lines");
    lines
        .iter()
        .filter(|l| l.contains(&needle))
        .cloned()
        .collect()
}

/// A fake resolver for engine tests: fixed answers, an unknown name resolves
/// to nothing (tests only).
#[cfg(test)]
pub(crate) fn fixed_lookup(
    host: String,
    _port: u16,
) -> BoxFuture<'static, std::io::Result<Vec<IpAddr>>> {
    let ips: &[&str] = match host.as_str() {
        "db.example" => &["93.184.216.34"],
        "evil.example" => &["127.0.0.1"],
        "meta.example" => &["169.254.169.254"],
        "split.example" => &["93.184.216.34", "10.0.0.9"],
        "supavisor" => &["172.18.0.5"],
        _ => &[],
    };
    let ips: Vec<IpAddr> = ips.iter().map(|s| s.parse().expect("ip")).collect();
    Box::pin(async move { Ok(ips) })
}

/// Accepts on `listener`, reports `label` per connection, drops the socket
/// (tests only).
#[cfg(all(test, any(feature = "postgres", feature = "mysql")))]
pub(crate) fn count_accepts(
    listener: tokio::net::TcpListener,
    label: &'static str,
    tx: tokio::sync::mpsc::UnboundedSender<&'static str>,
) {
    tokio::spawn(async move {
        while let Ok((socket, _)) = listener.accept().await {
            let _ = tx.send(label);
            drop(socket);
        }
    });
}

pub(crate) struct DialScope {
    mode: DialGuardMode,
    engine: &'static str,
    mount_id: String,
    tenant_id: String,
    provenance: Provenance,
    lookup: Lookup,
}

impl DialScope {
    /// `None` when nothing is checked: the guard is off, or the DSN is the
    /// operator's own (`Platform`). The caller then dials exactly as before.
    pub(crate) fn for_mount(
        mode: DialGuardMode,
        engine: &'static str,
        mount: &DatabaseMount,
        provenance: Provenance,
    ) -> Option<Self> {
        if mode == DialGuardMode::Off || provenance == Provenance::Platform {
            return None;
        }
        Some(Self {
            mode,
            engine,
            mount_id: mount.id.clone(),
            tenant_id: mount.tenant_id.clone(),
            provenance,
            lookup: system_lookup,
        })
    }

    #[cfg(test)]
    pub(crate) fn with_lookup(mut self, lookup: Lookup) -> Self {
        self.lookup = lookup;
        self
    }

    pub(crate) fn enforcing(&self) -> bool {
        self.mode == DialGuardMode::Enforce
    }

    /// Classify one literal address.
    pub(crate) fn vet_ip(&self, ip: IpAddr, host: &str, port: u16) -> Result<(), Refusal> {
        match classify(ip) {
            Some(class) => Err(Refusal::new(class, Some(ip), host, port)),
            None => Ok(()),
        }
    }

    /// Resolve `host` without classifying (the exact pooler endpoint only).
    pub(crate) async fn resolve(&self, host: &str, port: u16) -> Result<Vec<IpAddr>, Refusal> {
        let bare = host.trim_start_matches('[').trim_end_matches(']');
        if let Ok(ip) = bare.parse::<IpAddr>() {
            return Ok(vec![ip]);
        }
        match (self.lookup)(bare.to_string(), port).await {
            Ok(ips) if !ips.is_empty() => Ok(ips),
            _ => Err(Refusal::new(DenyClass::Unresolved, None, host, port)),
        }
    }

    /// Resolve `host` and classify EVERY record; one denied record refuses the
    /// host. `Ok` holds the vetted addresses, never empty.
    pub(crate) async fn vet_host(&self, host: &str, port: u16) -> Result<Vec<IpAddr>, Refusal> {
        if denied_name(host) {
            return Err(Refusal::new(DenyClass::InternalName, None, host, port));
        }
        let ips = self.resolve(host, port).await?;
        for ip in &ips {
            self.vet_ip(*ip, host, port)?;
        }
        Ok(ips)
    }

    /// Log one refusal: `dial_guard deny` under enforce, `would_deny` under shadow.
    pub(crate) fn report(&self, refusal: &Refusal) {
        let line = self.line(refusal);
        tracing::warn!(target: "dial_guard", "{line}");
        #[cfg(test)]
        RECORDED.lock().expect("recorded lines").push(line);
    }

    /// The error an enforced refusal returns. Carries the class only.
    pub(crate) fn refused(&self, refusal: &Refusal) -> DataPlaneError {
        DataPlaneError::Backend {
            message: format!(
                "{} dial refused by the dial guard: destination class {}",
                self.engine,
                refusal.class.as_str()
            ),
        }
    }

    fn line(&self, r: &Refusal) -> String {
        let verdict = if self.enforcing() {
            "deny"
        } else {
            "would_deny"
        };
        let ip = r.ip.map_or_else(|| "-".to_string(), |ip| ip.to_string());
        format!(
            "dial_guard {verdict} engine={} mount_id={:?} tenant_id={:?} provenance={} class={} ip={ip} port={} host={:?}",
            self.engine,
            capped(&self.mount_id),
            capped(&self.tenant_id),
            self.provenance.as_str(),
            r.class.as_str(),
            r.port,
            capped(&r.host),
        )
    }
}

/// `text` cut to at most `FIELD_CAP` bytes on a char boundary.
fn capped(text: &str) -> &str {
    if text.len() <= FIELD_CAP {
        return text;
    }
    let mut end = FIELD_CAP;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capped_cuts_on_a_char_boundary() {
        assert_eq!(capped("db"), "db");
        let long = "é".repeat(200);
        let cut = capped(&long);
        assert!(cut.len() <= FIELD_CAP && cut.len() >= FIELD_CAP - 1);
        assert!(cut.chars().all(|c| c == 'é'));
    }

    #[test]
    fn line_escapes_and_caps_caller_fields() {
        let mut mount: DatabaseMount = serde_json::from_value(serde_json::json!({
            "id": "m\"1\n", "tenant_id": "t", "engine": "postgresql", "name": "n",
            "credential_ref": {"provider": "inline", "reference": "r", "version": "1"}
        }))
        .expect("mount");
        mount.tenant_id = "x".repeat(400);
        let scope = DialScope::for_mount(
            DialGuardMode::Shadow,
            "postgresql",
            &mount,
            Provenance::Tenant,
        )
        .expect("tenant scope");
        let host = format!("evil\u{1b}[31m{}", "h".repeat(300));
        let line = scope.line(&Refusal::new(DenyClass::Loopback, None, &host, 5432));
        assert!(line.starts_with("dial_guard would_deny engine=postgresql "));
        assert!(line.contains(r#"mount_id="m\"1\n""#), "{line}");
        assert!(!line.contains('\u{1b}') && !line.contains('\n'), "{line}");
        assert!(line.contains("class=loopback ip=- port=5432"), "{line}");
        assert!(line.len() < 3 * FIELD_CAP + 200, "{}", line.len());
    }
}
