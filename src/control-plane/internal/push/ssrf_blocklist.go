package push

import "net"

// extraBlockedV4 are reserved IPv4 ranges not flagged by the net.IP predicates
// (CGNAT 100.64.0.0/10, benchmarking 198.18.0.0/15, the three TEST-NET
// documentation ranges, and the broadcast address) — none is a valid public
// push endpoint.
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
		"255.255.255.255/32",
	)
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
