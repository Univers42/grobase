/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mod.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 10:57:31 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 10:57:31 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! G2 dial guard (ADR 0019): the one place that decides whether the data plane
//! may open a connection to an address on a tenant's behalf.
//!
//! - [`classify`] — the address and host-name classifier. The http SSRF guard
//!   and every pinned engine dial call it; no other copy exists.
//! - [`scope`] — the per-pool dial scope: resolve, classify every record,
//!   report a refusal (shadow logs, enforce refuses), hand back the vetted IPs.
//!
//! Only a DSN the operator wrote into `DATA_PLANE_MOUNTS` is
//! [`crate::Provenance::Platform`]; everything else is `Tenant` and guarded.

#[cfg(any(
    feature = "dynamodb",
    feature = "http",
    feature = "mssql",
    feature = "mysql",
    feature = "postgres",
    feature = "redis"
))]
pub(crate) mod classify;
#[cfg(test)]
#[cfg(any(feature = "http", feature = "postgres", feature = "mysql"))]
mod classify_tests;
#[cfg(any(
    feature = "dynamodb",
    feature = "mssql",
    feature = "mysql",
    feature = "postgres",
    feature = "redis"
))]
pub(crate) mod scope;

/// The env key holding the mode, read once at startup by the server.
pub const DIAL_GUARD_KEY: &str = "DATA_PLANE_DIAL_GUARD";

/// What the guard does with a Tenant dial to a denied address.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DialGuardMode {
    /// No check, no pin: the driver dials exactly as before G2.
    #[default]
    Off,
    /// Classify and log `dial_guard would_deny`, then dial unchanged.
    Shadow,
    /// Refuse the dial and connect only to vetted addresses.
    Enforce,
}

impl DialGuardMode {
    /// Parse a raw `DATA_PLANE_DIAL_GUARD` value. Empty means `Off`; anything
    /// outside `off|shadow|enforce` is `None` so startup can refuse a typo
    /// instead of reading it as `Off`.
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "" | "off" => Some(Self::Off),
            "shadow" => Some(Self::Shadow),
            "enforce" => Some(Self::Enforce),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::DialGuardMode;

    #[test]
    fn mode_parses_the_three_values_and_refuses_the_rest() {
        assert_eq!(DialGuardMode::parse(""), Some(DialGuardMode::Off));
        assert_eq!(DialGuardMode::parse(" OFF "), Some(DialGuardMode::Off));
        assert_eq!(DialGuardMode::parse("shadow"), Some(DialGuardMode::Shadow));
        assert_eq!(
            DialGuardMode::parse("Enforce"),
            Some(DialGuardMode::Enforce)
        );
        assert_eq!(DialGuardMode::parse("enforced"), None);
        assert_eq!(DialGuardMode::parse("1"), None);
        assert_eq!(DialGuardMode::default(), DialGuardMode::Off);
    }
}
