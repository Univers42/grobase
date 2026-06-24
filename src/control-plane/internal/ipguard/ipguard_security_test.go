/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ipguard_security_test.go                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:01 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package ipguard

import (
	"context"
	"testing"
)

// TestNormalizeCIDR_WeirdInputs is a large hardening table for the Go-side CIDR
// validator: injection-shaped, malformed, boundary, unicode, and IPv6 inputs.
// Each vector is a subtest so it counts individually. A "bad" vector MUST return
// ErrBadCIDR (never a silent accept that would widen an allowlist).
func TestNormalizeCIDR_WeirdInputs(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string // "" when bad
		bad  bool
	}{
		// valid v4
		{name: "v4_host", in: "203.0.113.5", want: "203.0.113.5/32"},
		{name: "v4_cidr_exact", in: "10.0.0.0/8", want: "10.0.0.0/8"},
		{name: "v4_cidr_normalized", in: "10.1.2.3/8", want: "10.0.0.0/8"},
		{name: "v4_slash32", in: "192.168.1.1/32", want: "192.168.1.1/32"},
		{name: "v4_slash0", in: "0.0.0.0/0", want: "0.0.0.0/0"},
		{name: "v4_trim_spaces", in: "  192.168.1.0/24 ", want: "192.168.1.0/24"},
		// valid v6
		{name: "v6_host", in: "2001:db8::1", want: "2001:db8::1/128"},
		{name: "v6_cidr", in: "2001:db8::/32", want: "2001:db8::/32"},
		{name: "v6_loopback", in: "::1", want: "::1/128"},
		{name: "v6_slash0", in: "::/0", want: "::/0"},
		// malformed / boundary / injection
		{name: "empty", in: "", bad: true},
		{name: "only_spaces", in: "    ", bad: true},
		{name: "not_an_ip", in: "not-an-ip", bad: true},
		{name: "v4_octet_overflow", in: "999.1.1.1", bad: true},
		{name: "v4_octet_256", in: "256.1.1.1", bad: true},
		{name: "v4_mask_overflow", in: "10.0.0.0/99", bad: true},
		{name: "v4_mask_33", in: "10.0.0.0/33", bad: true},
		{name: "v4_negative_mask", in: "10.0.0.0/-1", bad: true},
		{name: "v6_mask_overflow", in: "2001:db8::/129", bad: true},
		{name: "double_slash", in: "10.0.0.0//8", bad: true},
		{name: "trailing_slash", in: "10.0.0.0/", bad: true},
		{name: "leading_slash", in: "/8", bad: true},
		{name: "letters_in_octet", in: "10.0.0.x", bad: true},
		{name: "too_few_octets", in: "10.0.0", bad: true},
		{name: "too_many_octets", in: "10.0.0.0.0", bad: true},
		{name: "hostname", in: "evil.example.com", bad: true},
		{name: "hostname_cidr", in: "evil.example.com/24", bad: true},
		{name: "sql_injection", in: "10.0.0.0/8; DROP TABLE tenant_ip_allowlist;--", bad: true},
		{name: "comma_list", in: "10.0.0.0/8,0.0.0.0/0", bad: true},
		{name: "space_in_cidr", in: "10.0.0.0 /8", bad: true},
		{name: "unicode_digit", in: "１0.0.0.0/8", bad: true},
		{name: "embedded_nul", in: "10.0.0.0\x00/8", bad: true},
		{name: "newline", in: "10.0.0.0/8\n0.0.0.0/0", bad: true},
		{name: "mask_with_letters", in: "10.0.0.0/8a", bad: true},
		{name: "hex_octet", in: "0x0a.0.0.0", bad: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := normalizeCIDR(c.in)
			if c.bad {
				if err == nil {
					t.Fatalf("normalizeCIDR(%q) = %q, want ErrBadCIDR", c.in, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("normalizeCIDR(%q) unexpected error: %v", c.in, err)
			}
			if got != c.want {
				t.Fatalf("normalizeCIDR(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

// TestParseIP_WeirdInputs hardens the single-IP parser (the edge-check client
// IP). It must reject hostnames, ranges, and garbage while tolerating IPv6 zones
// and brackets. A garbage client IP that parsed would be a silent allow risk.
func TestParseIP_WeirdInputs(t *testing.T) {
	cases := []struct {
		name string
		in   string
		ok   bool
	}{
		{name: "v4", in: "8.8.8.8", ok: true},
		{name: "v6", in: "2001:db8::1", ok: true},
		{name: "v6_zone", in: "fe80::1%eth0", ok: true},
		{name: "v6_bracketed", in: "[2001:db8::1]", ok: true},
		{name: "v6_loopback", in: "::1", ok: true},
		{name: "trim_spaces", in: "  8.8.8.8  ", ok: true},
		{name: "empty", in: "", ok: false},
		{name: "hostname", in: "example.com", ok: false},
		{name: "with_port", in: "8.8.8.8:80", ok: false},
		{name: "cidr", in: "10.0.0.0/8", ok: false},
		{name: "octet_overflow", in: "300.1.1.1", ok: false},
		{name: "garbage", in: "garbage", ok: false},
		{name: "sql", in: "8.8.8.8' OR '1'='1", ok: false},
		{name: "nul", in: "8.8.8.8\x00", ok: false},
		{name: "unicode", in: "８.8.8.8", ok: false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := parseIP(c.in)
			if c.ok && got == nil {
				t.Fatalf("parseIP(%q) = nil, want a parsed IP", c.in)
			}
			if !c.ok && got != nil {
				t.Fatalf("parseIP(%q) = %v, want nil", c.in, got)
			}
		})
	}
}

// TestAllowed_ContainmentMatrix exercises the LOAD-BEARING edge decision over a
// matrix of (rule set × client IP) — the per-tenant allow/deny that protects an
// API edge. Uses the listFn seam (no DB). The reject path (out-of-allowlist) is
// the security-critical one.
func TestAllowed_ContainmentMatrix(t *testing.T) {
	ctx := context.Background()
	mk := func(cidrs ...string) *Service {
		s := &Service{}
		s.listFn = func(context.Context, string) ([]Rule, error) {
			out := make([]Rule, len(cidrs))
			for i, c := range cidrs {
				out[i] = Rule{CIDR: c}
			}
			return out, nil
		}
		return s
	}
	cases := []struct {
		name      string
		rules     []string
		ip        string
		wantAllow bool
		wantRestr bool
	}{
		{name: "single_v4_in", rules: []string{"10.0.0.0/8"}, ip: "10.1.2.3", wantAllow: true, wantRestr: true},
		{name: "single_v4_out", rules: []string{"10.0.0.0/8"}, ip: "11.0.0.1", wantAllow: false, wantRestr: true},
		{name: "edge_of_range_in", rules: []string{"10.0.0.0/8"}, ip: "10.255.255.255", wantAllow: true, wantRestr: true},
		{name: "just_outside_range", rules: []string{"10.0.0.0/8"}, ip: "9.255.255.255", wantAllow: false, wantRestr: true},
		{name: "host32_match", rules: []string{"203.0.113.5/32"}, ip: "203.0.113.5", wantAllow: true, wantRestr: true},
		{name: "host32_miss", rules: []string{"203.0.113.5/32"}, ip: "203.0.113.6", wantAllow: false, wantRestr: true},
		{name: "multi_rule_second_matches", rules: []string{"10.0.0.0/8", "192.168.0.0/16"}, ip: "192.168.1.1", wantAllow: true, wantRestr: true},
		{name: "multi_rule_none_match", rules: []string{"10.0.0.0/8", "192.168.0.0/16"}, ip: "172.16.0.1", wantAllow: false, wantRestr: true},
		{name: "v6_in", rules: []string{"2001:db8::/32"}, ip: "2001:db8::dead", wantAllow: true, wantRestr: true},
		{name: "v6_out", rules: []string{"2001:db8::/32"}, ip: "2001:dead::1", wantAllow: false, wantRestr: true},
		{name: "v4_rule_v6_ip_no_match", rules: []string{"10.0.0.0/8"}, ip: "2001:db8::1", wantAllow: false, wantRestr: true},
		{name: "v6_rule_v4_ip_no_match", rules: []string{"2001:db8::/32"}, ip: "10.1.2.3", wantAllow: false, wantRestr: true},
		// a stored rule that no longer parses is SKIPPED, never a silent allow
		{name: "garbage_rule_skipped_out", rules: []string{"not-a-cidr"}, ip: "10.0.0.1", wantAllow: false, wantRestr: true},
		{name: "garbage_plus_match", rules: []string{"not-a-cidr", "10.0.0.0/8"}, ip: "10.0.0.1", wantAllow: true, wantRestr: true},
		// catch-all rule allows everything
		{name: "catchall_v4", rules: []string{"0.0.0.0/0"}, ip: "1.2.3.4", wantAllow: true, wantRestr: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d, err := mk(c.rules...).Allowed(ctx, "tenant-1", c.ip)
			if err != nil {
				t.Fatalf("Allowed(%q) unexpected error: %v", c.ip, err)
			}
			if d.Allow != c.wantAllow {
				t.Fatalf("Allowed(%q rules=%v) allow=%v, want %v", c.ip, c.rules, d.Allow, c.wantAllow)
			}
			if d.Restricted != c.wantRestr {
				t.Fatalf("Allowed(%q) restricted=%v, want %v", c.ip, d.Restricted, c.wantRestr)
			}
		})
	}
}

// TestAllowed_NoRulesOptInDefault proves the opt-in default: a tenant with NO
// rules is unrestricted (allow=true) for ANY IP, byte-parity with no feature.
func TestAllowed_NoRulesOptInDefault(t *testing.T) {
	ctx := context.Background()
	s := &Service{}
	s.listFn = func(context.Context, string) ([]Rule, error) { return nil, nil }
	for _, ip := range []string{"8.8.8.8", "2001:db8::1", "0.0.0.0", "255.255.255.255"} {
		d, err := s.Allowed(ctx, "t", ip)
		if err != nil {
			t.Fatalf("Allowed(%q): %v", ip, err)
		}
		if !d.Allow || d.Restricted {
			t.Fatalf("no-rule tenant for %q: allow=%v restricted=%v, want allow=true restricted=false", ip, d.Allow, d.Restricted)
		}
	}
}

// TestAllowed_GuardErrors proves the guard rejects (errors, never silently
// allows) on empty tenant and unparseable client IP — both across whitespace and
// injection-shaped inputs.
func TestAllowed_GuardErrors(t *testing.T) {
	ctx := context.Background()
	s := &Service{}
	s.listFn = func(context.Context, string) ([]Rule, error) { return []Rule{{CIDR: "10.0.0.0/8"}}, nil }

	t.Run("empty_tenant", func(t *testing.T) {
		if _, err := s.Allowed(ctx, "", "10.0.0.1"); err != ErrEmptyTenant {
			t.Fatalf("empty tenant: got %v, want ErrEmptyTenant", err)
		}
	})
	t.Run("whitespace_tenant", func(t *testing.T) {
		if _, err := s.Allowed(ctx, "   ", "10.0.0.1"); err != ErrEmptyTenant {
			t.Fatalf("whitespace tenant: got %v, want ErrEmptyTenant", err)
		}
	})
	for _, badIP := range []string{"", "garbage", "10.0.0.0/8", "8.8.8.8:80", "x'; DROP--", "999.1.1.1"} {
		t.Run("bad_ip_"+badIP, func(t *testing.T) {
			if _, err := s.Allowed(ctx, "t", badIP); err != ErrBadIP {
				t.Fatalf("Allowed bad ip %q: got %v, want ErrBadIP", badIP, err)
			}
		})
	}
}
