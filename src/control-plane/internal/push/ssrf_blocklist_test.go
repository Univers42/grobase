/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ssrf_blocklist_test.go                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:54:22 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:54:23 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package push

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"testing"
)

// TestExtraBlockedV4_ExactSet pins the EXACT reserved-IPv4 CIDR set the former
// package-level var (now built per call by extraBlockedV4) contained: the count,
// the precise CIDR strings, and that a representative IP inside each range is
// matched. A range dropped here re-opens an SSRF hole that the net.IP predicates
// do NOT cover.
func TestExtraBlockedV4_ExactSet(t *testing.T) {
	wantCIDRs := []string{
		"100.64.0.0/10",      // CGNAT
		"192.0.0.0/24",       // IETF protocol assignments
		"192.0.2.0/24",       // TEST-NET-1
		"198.18.0.0/15",      // benchmarking
		"198.51.100.0/24",    // TEST-NET-2
		"203.0.113.0/24",     // TEST-NET-3
		"255.255.255.255/32", // limited broadcast
	}
	got := extraBlockedV4()
	if len(got) != len(wantCIDRs) {
		t.Fatalf("extraBlockedV4() returned %d CIDRs, want %d", len(got), len(wantCIDRs))
	}
	// String-for-string equality, in order.
	for i, want := range wantCIDRs {
		if got[i].String() != want {
			t.Errorf("extraBlockedV4()[%d] = %q, want %q", i, got[i].String(), want)
		}
	}

	// A sample IP inside each range must be matched by the SSRF predicate.
	sampleInRange := map[string]string{
		"100.64.0.0/10":      "100.64.0.1",
		"192.0.0.0/24":       "192.0.0.5",
		"192.0.2.0/24":       "192.0.2.10",
		"198.18.0.0/15":      "198.19.0.1",
		"198.51.100.0/24":    "198.51.100.7",
		"203.0.113.0/24":     "203.0.113.42",
		"255.255.255.255/32": "255.255.255.255",
	}
	for cidr, sample := range sampleInRange {
		ip := net.ParseIP(sample)
		if ip == nil {
			t.Fatalf("bad sample IP %q", sample)
		}
		if !isBlockedIP(ip) {
			t.Errorf("isBlockedIP(%s) = false, want true (in reserved range %s)", sample, cidr)
		}
	}
}

// TestIsBlockedIP_StdlibRangesAndPublic confirms isBlockedIP covers the ranges
// the net.IP predicates flag (loopback / link-local incl. cloud metadata /
// RFC1918 / unspecified / IPv6 ULA+loopback) AND lets a clearly-public address
// through — so the guard is not a blanket deny that would make the allow-arm
// vacuous.
func TestIsBlockedIP_StdlibRangesAndPublic(t *testing.T) {
	blocked := []string{
		"127.0.0.1",       // loopback
		"169.254.169.254", // cloud metadata (link-local)
		"10.1.2.3",        // RFC1918
		"172.16.0.1",      // RFC1918
		"192.168.0.1",     // RFC1918
		"0.0.0.0",         // unspecified
		"::1",             // IPv6 loopback
		"fc00::1",         // IPv6 ULA (private)
		"fe80::1",         // IPv6 link-local
	}
	for _, s := range blocked {
		if ip := net.ParseIP(s); ip == nil || !isBlockedIP(ip) {
			t.Errorf("isBlockedIP(%s) = false, want true", s)
		}
	}
	public := []string{"8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"}
	for _, s := range public {
		if ip := net.ParseIP(s); ip == nil || isBlockedIP(ip) {
			t.Errorf("isBlockedIP(%s) = true, want false (public address blocked)", s)
		}
	}
}

// TestPushErr_ConstParity proves the sentinels survived the var→const-type
// conversion (pushErr). Each carries its documented message, %w-wrapping
// preserves errors.Is identity (the handler maps these to HTTP codes), direct
// equality holds, and the four sentinels are mutually distinct.
func TestPushErr_ConstParity(t *testing.T) {
	cases := []struct {
		err     error
		wantMsg string
	}{
		{ErrNotFound, "push subscription not found"},
		{ErrValidation, "push validation error"},
		{ErrBlockedTarget, "push target_url is not a permitted public endpoint (SSRF guard)"},
		{errNoKey, "push: PUSH_SECRET_KEY not configured (required to store a provider token)"},
	}
	for _, c := range cases {
		if c.err.Error() != c.wantMsg {
			t.Errorf("%v Error() = %q, want %q", c.err, c.err.Error(), c.wantMsg)
		}
		wrapped := fmt.Errorf("ctx: %w", c.err)
		if !errors.Is(wrapped, c.err) {
			t.Errorf("errors.Is(wrapped, %q) = false, want true", c.wantMsg)
		}
	}
	// Mutual distinctness: no sentinel matches another.
	sentinels := []error{ErrNotFound, ErrValidation, ErrBlockedTarget, errNoKey}
	for i := range sentinels {
		for j := range sentinels {
			if i != j && errors.Is(sentinels[i], sentinels[j]) {
				t.Errorf("sentinel %d matches sentinel %d — sentinels collide", i, j)
			}
		}
	}
}

// FuzzGuardTarget asserts the SSRF guard never panics for arbitrary input and
// never permits a literal loopback/private IP target (the load-bearing
// invariant). Hostnames are not exercised against real DNS — the fuzz focuses on
// the pure parse + literal-IP path, which needs no network.
func FuzzGuardTarget(f *testing.F) {
	f.Add("http://8.8.8.8/")
	f.Add("http://127.0.0.1/")
	f.Add("ftp://x/")
	f.Add("http:///nohost")
	f.Add("://")
	f.Add("")
	f.Fuzz(func(t *testing.T, raw string) {
		t.Setenv("PUSH_SSRF_ALLOW_HOSTS", "") // no allowlist escape hatch
		err := guardTarget(raw)               // must not panic
		// If the target is a literal blocked IP, the guard MUST reject it.
		if u := parseHostLiteral(raw); u != nil && isBlockedIP(u) && err == nil {
			t.Errorf("guardTarget(%q) = nil for a literal blocked IP %s — SSRF leak", raw, u)
		}
	})
}

// parseHostLiteral extracts a literal IP host from a URL if present, else nil
// (a test helper for the fuzz invariant; mirrors guardTarget's literal path).
func parseHostLiteral(raw string) net.IP {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return nil
	}
	return net.ParseIP(u.Hostname())
}

// FuzzRegisterValidate asserts RegisterRequest.Validate never panics and a
// passing request always has a known channel + a non-empty target_url.
func FuzzRegisterValidate(f *testing.F) {
	f.Add("webhook", "https://x.test/", "", "label")
	f.Add("fcm", "http://1.2.3.4/", "tok", "")
	f.Add("sms", "", "", "")
	f.Fuzz(func(t *testing.T, channel, url, token, label string) {
		r := RegisterRequest{Channel: channel, TargetURL: url, Token: token, Label: label}
		if err := r.Validate(); err == nil {
			if channel != channelWebhook && channel != channelFCM {
				t.Errorf("Validate accepted unknown channel %q", channel)
			}
			if url == "" {
				t.Errorf("Validate accepted empty target_url")
			}
		}
	})
}
