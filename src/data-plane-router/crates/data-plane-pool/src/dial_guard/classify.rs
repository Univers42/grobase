/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   classify.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 10:57:31 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 10:57:31 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The dial-guard classifier: which addresses and host names a Tenant dial must
//! not reach. Pure, no I/O. IPv6 forms that carry an IPv4 address (mapped,
//! compatible, NAT64 `64:ff9b::/96`, 6to4 `2002::/16`) are judged by that IPv4
//! address, so `64:ff9b::7f00:1` is loopback and `64:ff9b::808:808` is public.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Why a destination is refused. `as_str` is the `class=` value in the log.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DenyClass {
    Loopback,
    LinkLocal,
    Unspecified,
    Multicast,
    Reserved,
    Private,
    // Only the engine dials (scope.rs) refuse by name, socket or lookup;
    // http reports its own messages for those.
    #[cfg(any(
        feature = "mssql",
        feature = "mysql",
        feature = "postgres",
        feature = "redis"
    ))]
    InternalName,
    #[cfg(any(feature = "mysql", feature = "postgres", feature = "redis"))]
    UnixSocket,
    #[cfg(feature = "redis")]
    Tls,
    #[cfg(any(
        feature = "mssql",
        feature = "mysql",
        feature = "postgres",
        feature = "redis"
    ))]
    Unresolved,
    // A SQL Server `host\instance` needs SQL Browser to find its port.
    #[cfg(feature = "mssql")]
    NamedInstance,
}

#[cfg(any(
    feature = "mssql",
    feature = "mysql",
    feature = "postgres",
    feature = "redis"
))]
impl DenyClass {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Loopback => "loopback",
            Self::LinkLocal => "link_local",
            Self::Unspecified => "unspecified",
            Self::Multicast => "multicast",
            Self::Reserved => "reserved",
            Self::Private => "private",
            Self::InternalName => "internal_name",
            #[cfg(any(feature = "mysql", feature = "postgres", feature = "redis"))]
            Self::UnixSocket => "unix_socket",
            #[cfg(feature = "redis")]
            Self::Tls => "tls",
            Self::Unresolved => "unresolved",
            #[cfg(feature = "mssql")]
            Self::NamedInstance => "named_instance",
        }
    }
}

/// `Some(class)` for an address a Tenant dial must not reach: loopback,
/// link-local (169.254.169.254 metadata included), unspecified, multicast,
/// reserved/documentation/benchmarking, and RFC 1918 / CGNAT / ULA.
#[must_use]
pub(crate) fn classify(ip: IpAddr) -> Option<DenyClass> {
    match ip {
        IpAddr::V4(v4) => classify_v4(v4),
        IpAddr::V6(v6) => classify_v6(v6),
    }
}

fn classify_v4(v4: Ipv4Addr) -> Option<DenyClass> {
    let [a, b, c, _] = v4.octets();
    if v4.is_unspecified() {
        Some(DenyClass::Unspecified)
    } else if a == 0 || a >= 240 {
        // 0/8 "this network"; 240/4 reserved, broadcast included.
        Some(DenyClass::Reserved)
    } else if v4.is_loopback() {
        Some(DenyClass::Loopback)
    } else if v4.is_link_local() {
        Some(DenyClass::LinkLocal)
    } else if v4.is_private() || (a == 100 && (b & 0xc0) == 64) {
        Some(DenyClass::Private)
    } else if v4.is_multicast() {
        Some(DenyClass::Multicast)
    } else if v4.is_documentation()
        || (a == 192 && b == 0 && c == 0)
        || (a == 198 && (b & 0xfe) == 18)
    {
        // TEST-NETs, 192.0.0/24 IETF assignments, 198.18/15 benchmarking.
        Some(DenyClass::Reserved)
    } else {
        None
    }
}

fn classify_v6(v6: Ipv6Addr) -> Option<DenyClass> {
    if v6.is_unspecified() {
        return Some(DenyClass::Unspecified);
    }
    if v6.is_loopback() {
        return Some(DenyClass::Loopback);
    }
    if let Some(v4) = embedded_ipv4(v6) {
        return classify_v4(v4);
    }
    let s = v6.segments();
    if (s[0] & 0xff00) == 0xff00 {
        Some(DenyClass::Multicast)
    } else if (s[0] & 0xffc0) == 0xfe80 {
        Some(DenyClass::LinkLocal)
    } else if (s[0] & 0xfe00) == 0xfc00 {
        Some(DenyClass::Private)
    } else if (s[0] & 0xe000) != 0x2000
        || (s[0] == 0x2001 && s[1] < 0x0200)
        || (s[0] == 0x2001 && s[1] == 0x0db8)
        || (s[0] == 0x3fff && (s[1] & 0xf000) == 0)
    {
        // Outside global unicast 2000::/3, 2001::/23 IETF (Teredo included),
        // and the documentation blocks 2001:db8::/32 and 3fff::/20.
        Some(DenyClass::Reserved)
    } else {
        None
    }
}

/// The IPv4 address an IPv6 form carries: `::ffff:a.b.c.d` (mapped),
/// `::a.b.c.d` (compatible), `64:ff9b::a.b.c.d` (NAT64) and `2002:AABB:CCDD::`
/// (6to4). `::` and `::1` are not compatible forms; the caller handles them.
#[must_use]
pub(crate) fn embedded_ipv4(v6: Ipv6Addr) -> Option<Ipv4Addr> {
    if let Some(v4) = v6.to_ipv4_mapped() {
        return Some(v4);
    }
    let s = v6.segments();
    let pair = |hi: u16, lo: u16| {
        let [a, b] = hi.to_be_bytes();
        let [c, d] = lo.to_be_bytes();
        Ipv4Addr::new(a, b, c, d)
    };
    let compatible = s[..6] == [0; 6] && !v6.is_unspecified() && !v6.is_loopback();
    let nat64 = s[0] == 0x0064 && s[1] == 0xff9b && s[2..6] == [0; 4];
    if compatible || nat64 {
        Some(pair(s[6], s[7]))
    } else if s[0] == 0x2002 {
        Some(pair(s[1], s[2]))
    } else {
        None
    }
}

/// Host names refused before any lookup: `localhost` and `*.localhost`
/// (RFC 6761), the cloud metadata aliases, and the `*.local` / `*.internal`
/// suffixes. One trailing dot is ignored, so `localhost.` is refused too.
#[must_use]
pub(crate) fn denied_name(host: &str) -> bool {
    let lower = host.to_ascii_lowercase();
    let name = lower.strip_suffix('.').unwrap_or(&lower);
    matches!(name, "localhost" | "metadata" | "instance-data")
        || name.ends_with(".localhost")
        || name.ends_with(".local")
        || name.ends_with(".internal")
}
