/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   identity_fuzz_test.go                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:42 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:43 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package identity

import (
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// FuzzVerifyIdentitySignature feeds an arbitrary X-Baas-Identity-Auth header and
// asserts the verifier never panics and never accepts a malformed/forged header:
// the ONLY way it may return true is when the header byte-equals a freshly
// computed signature over the asserted (userID, tenantID) tuple.
func FuzzVerifyIdentitySignature(f *testing.F) {
	for _, s := range []string{
		"", "v1.x.y", "v1", "v2.100.abc", "v1.0.", ".", "::*",
		"v1.9999999999.deadbeef", "\x00", "v1.\n.\n",
	} {
		f.Add(s, "user-1", "tenant-1")
	}
	const token = "fuzz-token"
	f.Fuzz(func(t *testing.T, hdr, userID, tenantID string) {
		r := httptest.NewRequest("GET", "/v1/tenants/x/usage", nil)
		r.Header.Set(IdentityAuthHeader, hdr)
		got := VerifyIdentitySignature(r, token, userID, tenantID) // must not panic
		if !got {
			return
		}
		// If it accepted, the header MUST be a v1.<ts>.<sig> whose signature is the
		// HMAC over the asserted identity tuple keyed by `token` at that very ts.
		// (A forged/arbitrary header cannot reach here without a SHA-256 collision.)
		parts := strings.Split(hdr, ".")
		if len(parts) != 3 || parts[0] != "v1" {
			t.Fatalf("accepted malformed header %q", hdr)
		}
		ts, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil {
			t.Fatalf("accepted header %q with non-numeric ts", hdr)
		}
		want := serviceauth.ComputeServiceSignature(token, serviceauth.SignedRequest{Method: "IDENTITY", Path: CanonicalIdentity(userID, tenantID), TS: ts})
		if hdr != want {
			t.Fatalf("accepted header %q for (%q,%q) not matching recomputed signature", hdr, userID, tenantID)
		}
	})
}

// FuzzVerifyIdentitySignature_EmptyTokenFailsClosed: an empty service token must
// NEVER verify, for any header — fail-closed contract.
func FuzzVerifyIdentitySignature_EmptyTokenFailsClosed(f *testing.F) {
	for _, s := range []string{"", "v1.100.abc", "v1." + "x", "\x00"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, hdr string) {
		r := httptest.NewRequest("GET", "/x", nil)
		r.Header.Set(IdentityAuthHeader, hdr)
		if VerifyIdentitySignature(r, "", "u", "tenant") {
			t.Fatalf("empty service token verified header %q (must fail closed)", hdr)
		}
	})
}

// FuzzTenantSelfMatch_FlagOff (default): byte-parity with `header == id`. For any
// header/id pair, TenantSelfMatch returns true IFF id != "" and a present tenant
// header equals it.
func FuzzTenantSelfMatch_FlagOff(f *testing.F) {
	for _, pair := range [][2]string{{"T", "T"}, {"T", "T2"}, {"", ""}, {"T", ""}, {"", "T"}, {"\x00", "\x00"}} {
		f.Add(pair[0], pair[1])
	}
	f.Fuzz(func(t *testing.T, hdrTenant, id string) {
		t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "")
		r := httptest.NewRequest("GET", "/x", nil)
		if hdrTenant != "" {
			r.Header.Set("X-Baas-Tenant-Id", hdrTenant)
		}
		got := TenantSelfMatch(r, "tok", id) // must not panic
		want := id != "" && hdrTenant == id
		if got != want {
			t.Fatalf("flag OFF: TenantSelfMatch(hdr=%q,id=%q)=%v, want %v (parity with header==id)", hdrTenant, id, got, want)
		}
	})
}
