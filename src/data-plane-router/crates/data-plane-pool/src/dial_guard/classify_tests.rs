/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   classify_tests.rs                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 10:57:31 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 10:57:31 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Classifier table + property tests (C6). The pre-G2 http classifier is kept
//! here as an oracle only, to prove the new one refuses everything it refused.

use super::classify::{classify, denied_name, embedded_ipv4, DenyClass};
use proptest::prelude::*;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

fn class_of(ip: &str) -> Option<DenyClass> {
    classify(ip.parse::<IpAddr>().expect("test ip"))
}

#[test]
fn classifier_table_covers_every_range() {
    use DenyClass::{LinkLocal, Loopback, Multicast, Private, Reserved, Unspecified};
    let table: &[(&str, Option<DenyClass>)] = &[
        ("0.0.0.0", Some(Unspecified)),
        ("0.1.2.3", Some(Reserved)),
        ("127.0.0.1", Some(Loopback)),
        ("127.255.255.254", Some(Loopback)),
        ("169.254.169.254", Some(LinkLocal)),
        ("10.0.0.5", Some(Private)),
        ("172.16.0.1", Some(Private)),
        ("172.31.255.255", Some(Private)),
        ("192.168.1.1", Some(Private)),
        ("100.64.0.1", Some(Private)),
        ("100.127.255.255", Some(Private)),
        ("224.0.0.1", Some(Multicast)),
        ("239.255.255.255", Some(Multicast)),
        ("240.0.0.1", Some(Reserved)),
        ("255.255.255.255", Some(Reserved)),
        ("198.18.0.1", Some(Reserved)),
        ("198.19.255.255", Some(Reserved)),
        ("192.0.0.8", Some(Reserved)),
        ("192.0.2.1", Some(Reserved)),
        ("198.51.100.7", Some(Reserved)),
        ("203.0.113.9", Some(Reserved)),
        ("::", Some(Unspecified)),
        ("::1", Some(Loopback)),
        ("::ffff:127.0.0.1", Some(Loopback)),
        ("::ffff:169.254.169.254", Some(LinkLocal)),
        ("::127.0.0.1", Some(Loopback)),
        ("::10.0.0.1", Some(Private)),
        ("64:ff9b::7f00:1", Some(Loopback)),
        ("64:ff9b::a9fe:a9fe", Some(LinkLocal)),
        ("2002:7f00:1::", Some(Loopback)),
        ("2002:a9fe:a9fe::1", Some(LinkLocal)),
        ("2002:c0a8:0101::", Some(Private)),
        ("fe80::1", Some(LinkLocal)),
        ("fc00::1", Some(Private)),
        ("fd12:3456::1", Some(Private)),
        ("ff02::1", Some(Multicast)),
        ("2001:db8::1", Some(Reserved)),
        ("2001:0:4136:e378::1", Some(Reserved)),
        ("3fff::1", Some(Reserved)),
        ("100::1", Some(Reserved)),
        ("64:ff9b:1::1", Some(Reserved)),
        ("fec0::1", Some(Reserved)),
        // Public: allowed.
        ("1.1.1.1", None),
        ("8.8.8.8", None),
        ("93.184.216.34", None),
        ("100.63.255.255", None),
        ("100.128.0.0", None),
        ("172.15.255.255", None),
        ("172.32.0.0", None),
        ("198.17.255.255", None),
        ("198.20.0.0", None),
        ("223.255.255.255", None),
        ("2606:4700:4700::1111", None),
        ("::ffff:8.8.8.8", None),
        ("::8.8.8.8", None),
        ("64:ff9b::808:808", None),
        ("2002:808:808::1", None),
        ("2001:200::1", None),
        ("3fff:1000::1", None),
    ];
    for (ip, want) in table {
        assert_eq!(class_of(ip), *want, "{ip}");
    }
}

#[test]
fn embedded_ipv4_decodes_the_four_forms_and_nothing_else() {
    let v4 = Ipv4Addr::new(10, 1, 2, 3);
    let forms = [
        "::ffff:10.1.2.3",
        "::10.1.2.3",
        "64:ff9b::10.1.2.3",
        "2002:a01:203::",
    ];
    for form in forms {
        let v6: Ipv6Addr = form.parse().expect("form");
        assert_eq!(embedded_ipv4(v6), Some(v4), "{form}");
    }
    for plain in ["::", "::1", "2606:4700::1", "fe80::1", "64:ff9b:1::a01:203"] {
        let v6: Ipv6Addr = plain.parse().expect("plain");
        assert_eq!(embedded_ipv4(v6), None, "{plain}");
    }
}

#[test]
fn internal_names_are_denied_before_any_lookup() {
    for name in [
        "localhost",
        "LOCALHOST.",
        "api.localhost",
        "metadata",
        "instance-data",
        "printer.local",
        "metadata.google.internal",
        "host.docker.internal",
    ] {
        assert!(denied_name(name), "{name}");
    }
    for name in [
        "postgres",
        "db.example.com",
        "localhost.example.com",
        "internal",
    ] {
        assert!(!denied_name(name), "{name}");
    }
}

/// The http classifier as it was before G2, kept only as the oracle.
fn pre_g2_blocked(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_unspecified()
                || v4.is_documentation()
                || o[0] == 0
                || (o[0] == 100 && (o[1] & 0xc0) == 64)
        }
        IpAddr::V6(v6) => {
            if let Some(mapped) = v6.to_ipv4_mapped() {
                return pre_g2_blocked(IpAddr::V4(mapped));
            }
            let s0 = v6.segments()[0];
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || (s0 & 0xfe00) == 0xfc00
                || (s0 & 0xffc0) == 0xfe80
        }
    }
}

fn v4_in(base: [u8; 4], prefix: u32, host: u32) -> Ipv4Addr {
    let mask = if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    };
    Ipv4Addr::from((u32::from_be_bytes(base) & mask) | (host & !mask))
}

proptest! {
    #[test]
    fn every_embedding_is_judged_by_its_ipv4(raw in any::<u32>()) {
        let v4 = Ipv4Addr::from(raw);
        let want = classify(IpAddr::V4(v4));
        let [a, b, c, d] = v4.octets();
        let hi = u16::from_be_bytes([a, b]);
        let lo = u16::from_be_bytes([c, d]);
        prop_assert_eq!(classify(IpAddr::V6(v4.to_ipv6_mapped())), want);
        let nat64 = Ipv6Addr::new(0x64, 0xff9b, 0, 0, 0, 0, hi, lo);
        prop_assert_eq!(classify(IpAddr::V6(nat64)), want);
        let six_to_four = Ipv6Addr::new(0x2002, hi, lo, 0, 0, 0, 0, 1);
        prop_assert_eq!(classify(IpAddr::V6(six_to_four)), want);
        if raw > 1 {
            prop_assert_eq!(classify(IpAddr::V6(v4.to_ipv6_compatible())), want);
        }
    }

    #[test]
    fn nothing_the_pre_g2_classifier_refused_is_now_allowed(
        v4 in any::<u32>(),
        v6 in any::<u128>(),
    ) {
        for ip in [IpAddr::V4(Ipv4Addr::from(v4)), IpAddr::V6(Ipv6Addr::from(v6))] {
            if pre_g2_blocked(ip) {
                prop_assert!(classify(ip).is_some(), "{} now allowed", ip);
            }
        }
    }

    #[test]
    fn whole_ranges_land_in_their_class(host in any::<u32>()) {
        let cases: [([u8; 4], u32, DenyClass); 9] = [
            ([127, 0, 0, 0], 8, DenyClass::Loopback),
            ([169, 254, 0, 0], 16, DenyClass::LinkLocal),
            ([10, 0, 0, 0], 8, DenyClass::Private),
            ([172, 16, 0, 0], 12, DenyClass::Private),
            ([192, 168, 0, 0], 16, DenyClass::Private),
            ([100, 64, 0, 0], 10, DenyClass::Private),
            ([224, 0, 0, 0], 4, DenyClass::Multicast),
            ([240, 0, 0, 0], 4, DenyClass::Reserved),
            ([198, 18, 0, 0], 15, DenyClass::Reserved),
        ];
        for (base, prefix, class) in cases {
            let ip = v4_in(base, prefix, host);
            prop_assert_eq!(classify(IpAddr::V4(ip)), Some(class), "{}", ip);
        }
    }

    #[test]
    fn ula_link_local_and_multicast_v6_are_refused(low in any::<u128>()) {
        let ula = Ipv6Addr::from((0xfc00_u128 << 112) | (low >> 7));
        let link = Ipv6Addr::from((0xfe80_u128 << 112) | (low >> 10));
        let multi = Ipv6Addr::from((0xff00_u128 << 112) | (low >> 8));
        prop_assert_eq!(classify(IpAddr::V6(ula)), Some(DenyClass::Private));
        prop_assert_eq!(classify(IpAddr::V6(link)), Some(DenyClass::LinkLocal));
        prop_assert_eq!(classify(IpAddr::V6(multi)), Some(DenyClass::Multicast));
    }
}
