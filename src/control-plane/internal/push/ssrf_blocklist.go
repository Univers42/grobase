/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ssrf_blocklist.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:54:24 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:54:25 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package push

import "net"

// extraBlockedV4 are reserved IPv4 ranges not flagged by the net.IP predicates
// (CGNAT 100.64.0.0/10, benchmarking 198.18.0.0/15, the three TEST-NET
// documentation ranges, and class E 240.0.0.0/4, which holds the broadcast
// address) — none is a valid public push endpoint.
//
// perf: built per call — the SSRF check runs at register/send (API-rate), not
// per-query, so rebuilding this tiny fixed list each call is fine and keeps the
// package free of any package-level var.
func extraBlockedV4() []*net.IPNet {
	return mustCIDRs(
		"100.64.0.0/10",
		"192.0.0.0/24",
		"192.0.2.0/24",
		"198.18.0.0/15",
		"198.51.100.0/24",
		"203.0.113.0/24",
		"240.0.0.0/4",
	)
}

// extraBlockedV6 are IPv6 ranges blocked outright: the local-use NAT64 prefix
// 64:ff9b:1::/48 (RFC 8215) translates to operator-internal IPv4 space.
func extraBlockedV6() []*net.IPNet {
	return mustCIDRs("64:ff9b:1::/48")
}

// embeddedV4 returns the IPv4 address a translation prefix carries — 6to4
// 2002:WWXX:YYZZ::/48 (bytes 2-5) or well-known NAT64 64:ff9b::/96 (bytes
// 12-15) — so the SSRF wall judges the real target, not its wrapper. It returns
// nil for a plain IPv4 (or IPv4-mapped) address and for any other IPv6 address.
func embeddedV4(ip net.IP) net.IP {
	ip16 := ip.To16()
	if ip16 == nil || ip.To4() != nil {
		return nil
	}
	if ip16[0] == 0x20 && ip16[1] == 0x02 {
		return net.IPv4(ip16[2], ip16[3], ip16[4], ip16[5])
	}
	if mustCIDRs("64:ff9b::/96")[0].Contains(ip16) {
		return net.IPv4(ip16[12], ip16[13], ip16[14], ip16[15])
	}
	return nil
}

func mustCIDRs(cidrs ...string) []*net.IPNet {
	out := make([]*net.IPNet, 0, len(cidrs))
	for _, c := range cidrs {
		_, n, err := net.ParseCIDR(c)
		if err != nil {
			panic("push: bad CIDR constant " + c)
		}
		out = append(out, n)
	}
	return out
}
