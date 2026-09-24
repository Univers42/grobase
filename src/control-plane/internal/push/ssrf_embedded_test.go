/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ssrf_embedded_test.go                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/23 23:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/23 23:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package push

import (
	"net"
	"testing"
)

// TestIsBlockedIP_TranslationPrefixes proves 6to4 and NAT64 addresses are judged
// by the IPv4 they embed (private → blocked, public → allowed), that the
// local-use NAT64 /48 and class E are blocked outright, that the IPv4-mapped
// form of a private address is blocked, and that plain public IPv6 still passes.
func TestIsBlockedIP_TranslationPrefixes(t *testing.T) {
	cases := map[string]bool{
		"2002:a00:1::1":        true,
		"2002:a9fe:a9fe::1":    true,
		"2002:808:808::1":      false,
		"64:ff9b::a00:1":       true,
		"64:ff9b::7f00:1":      true,
		"64:ff9b::808:808":     false,
		"64:ff9b:1::808:808":   true,
		"240.0.0.1":            true,
		"::ffff:10.0.0.1":      true,
		"2606:4700:4700::1111": false,
	}
	for s, want := range cases {
		ip := net.ParseIP(s)
		if ip == nil {
			t.Fatalf("bad test IP %q", s)
		}
		if got := isBlockedIP(ip); got != want {
			t.Errorf("isBlockedIP(%s) = %v, want %v", s, got, want)
		}
	}
}
