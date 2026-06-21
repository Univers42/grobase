/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service_test.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:12 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:14 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package ipguard

import (
	"context"
	"testing"
)

// TestNormalizeCIDR proves the Go-side validator: a CIDR is canonicalized, a bare
// host becomes /32 (v4) or /128 (v6), and garbage is ErrBadCIDR — independent of
// any DB. This is the defence-in-depth atop the native CIDR column.
func TestNormalizeCIDR(t *testing.T) {
	cases := []struct {
		in, want string
		bad      bool
	}{
		{in: "10.0.0.0/8", want: "10.0.0.0/8"},
		{in: "10.0.0.5/8", want: "10.0.0.0/8"}, // re-emitted as the network address
		{in: "203.0.113.5", want: "203.0.113.5/32"},
		{in: "  192.168.1.0/24 ", want: "192.168.1.0/24"},
		{in: "2001:db8::/32", want: "2001:db8::/32"},
		{in: "2001:db8::1", want: "2001:db8::1/128"},
		{in: "", bad: true},
		{in: "not-an-ip", bad: true},
		{in: "10.0.0.0/99", bad: true},
		{in: "999.1.1.1", bad: true},
	}
	for _, c := range cases {
		got, err := normalizeCIDR(c.in)
		if c.bad {
			if err == nil {
				t.Fatalf("normalizeCIDR(%q) = %q, want error", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Fatalf("normalizeCIDR(%q) unexpected error: %v", c.in, err)
		}
		if got != c.want {
			t.Fatalf("normalizeCIDR(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// TestAllowedDecision is the CORE edge decision, exercised purely in Go via the
// Service.listFn test seam (no DB, no pgx):
//   - no rules  ⇒ allow, not restricted (OPT-IN default)
//   - in-range  ⇒ allow, restricted
//   - out-range ⇒ DENY, restricted (the load-bearing reject)
//   - bad IP    ⇒ error
func TestAllowedDecision(t *testing.T) {
	ctx := context.Background()

	// (a) no allowlist → unrestricted, allow=true even for any IP.
	open := &Service{db: nil}
	open.listFn = func(context.Context, string) ([]Rule, error) { return nil, nil }
	d, err := open.Allowed(ctx, "t1", "8.8.8.8")
	if err != nil {
		t.Fatalf("no-rule allow: %v", err)
	}
	if !d.Allow || d.Restricted {
		t.Fatalf("no-rule: got allow=%v restricted=%v, want allow=true restricted=false", d.Allow, d.Restricted)
	}

	// (b) one rule 10.0.0.0/8 → in-range allow, out-range DENY.
	scoped := &Service{db: nil}
	scoped.listFn = func(context.Context, string) ([]Rule, error) {
		return []Rule{{CIDR: "10.0.0.0/8"}}, nil
	}
	in, err := scoped.Allowed(ctx, "t1", "10.1.2.3")
	if err != nil {
		t.Fatalf("in-range: %v", err)
	}
	if !in.Allow || !in.Restricted {
		t.Fatalf("in-range: got allow=%v restricted=%v, want allow=true restricted=true", in.Allow, in.Restricted)
	}
	out, err := scoped.Allowed(ctx, "t1", "203.0.113.9")
	if err != nil {
		t.Fatalf("out-range: %v", err)
	}
	if out.Allow || !out.Restricted {
		t.Fatalf("out-range: got allow=%v restricted=%v, want allow=false restricted=true (LOAD-BEARING REJECT)", out.Allow, out.Restricted)
	}
	if out.Reason != "not_in_allowlist" {
		t.Fatalf("out-range reason = %q, want not_in_allowlist", out.Reason)
	}

	// (c) bad client IP → error (never a silent allow).
	if _, err := scoped.Allowed(ctx, "t1", "garbage"); err == nil {
		t.Fatal("bad IP must error, not silently allow")
	}

	// (d) empty tenant → error.
	if _, err := scoped.Allowed(ctx, "", "10.0.0.1"); err == nil {
		t.Fatal("empty tenant must error")
	}
}
