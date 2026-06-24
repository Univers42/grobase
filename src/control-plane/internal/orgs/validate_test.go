/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   validate_test.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:51:38 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:51:40 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package orgs

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// ── CreateOrgRequest.Validate edge/table ──────────────────────────────────────

func TestCreateOrgRequestValidate_Edges(t *testing.T) {
	cases := []struct {
		name string
		slug string
		nm   string
		ok   bool
	}{
		{"min len 2", "ab", "n", true},
		{"len 1 rejected", "a", "n", false},
		{"exactly 63 ok", "a" + strings.Repeat("b", 62), "n", true},
		{"64 rejected", "a" + strings.Repeat("b", 63), "n", false},
		{"first char digit ok", "0x", "n", true},
		{"leading dash rejected", "-x", "n", false},
		{"leading underscore rejected", "_x", "n", false},
		{"trailing dash ok", "x-", "n", true},
		{"uppercase rejected", "Ab", "n", false},
		{"empty slug rejected", "", "n", false},
		{"valid slug empty name rejected", "ab", "", false},
		{"namespace colon rejected", "a:b", "n", false},
		{"star rejected", "a*b", "n", false},
		{"NUL rejected", "a\x00b", "n", false},
		{"unicode rejected", "abé", "n", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := CreateOrgRequest{Slug: c.slug, Name: c.nm}.Validate()
			if c.ok && err != nil {
				t.Fatalf("slug=%q name=%q: want accept, got %v", c.slug, c.nm, err)
			}
			if !c.ok && err == nil {
				t.Fatalf("slug=%q name=%q: want reject, got nil", c.slug, c.nm)
			}
		})
	}
}

// FuzzCreateOrgRequestValidate: never panics; parity with recompiling slugPattern
// (the exact pattern the validator uses) when the name is non-empty.
func FuzzCreateOrgRequestValidate(f *testing.F) {
	for _, s := range []string{
		"ab", "a", "", "0x", "-x", "_x", "x-", "Ab",
		"a:b", "a*b", "a\x00b", "abé", strings.Repeat("z", 63), strings.Repeat("z", 64), ":",
	} {
		f.Add(s)
	}
	re := regexp.MustCompile(slugPattern)
	f.Fuzz(func(t *testing.T, slug string) {
		err := CreateOrgRequest{Slug: slug, Name: "fixed"}.Validate()
		want := re.MatchString(slug)
		if want && err != nil {
			t.Fatalf("regex accepts %q but Validate rejected: %v", slug, err)
		}
		if !want && err == nil {
			t.Fatalf("regex rejects %q but Validate accepted", slug)
		}
	})
}

// ── InviteRequest.Validate fuzz + edges (email presence + role allowlist) ─────

func TestInviteRequestValidate_Edges(t *testing.T) {
	cases := []struct {
		name  string
		email string
		role  string
		ok    bool
	}{
		{"email + empty role ok (role optional)", "u@e.com", "", true},
		{"email + valid role", "u@e.com", "developer", true},
		{"empty email rejected", "", "viewer", false},
		{"unknown role rejected", "u@e.com", "superuser", false},
		{"all five roles ok: owner", "u@e.com", "owner", true},
		{"all five roles ok: admin", "u@e.com", "admin", true},
		{"all five roles ok: billing", "u@e.com", "billing", true},
		{"all five roles ok: viewer", "u@e.com", "viewer", true},
		{"role case-sensitive (Owner) rejected", "u@e.com", "Owner", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := InviteRequest{Email: c.email, Role: c.role}.Validate()
			if c.ok && err != nil {
				t.Fatalf("email=%q role=%q: want accept, got %v", c.email, c.role, err)
			}
			if !c.ok && err == nil {
				t.Fatalf("email=%q role=%q: want reject, got nil", c.email, c.role)
			}
		})
	}
}

func FuzzInviteRequestValidate(f *testing.F) {
	f.Add("u@e.com", "owner")
	f.Add("", "viewer")
	f.Add("u@e.com", "")
	f.Add("u@e.com", "nope")
	f.Add("\x00", "\n")
	f.Fuzz(func(t *testing.T, email, role string) {
		err := InviteRequest{Email: email, Role: role}.Validate()
		// Contract: accept IFF email non-empty AND (role empty OR validRole(role)).
		want := email != "" && (role == "" || validRole(role))
		if want && err != nil {
			t.Fatalf("email=%q role=%q: contract accepts but Validate rejected: %v", email, role, err)
		}
		if !want && err == nil {
			t.Fatalf("email=%q role=%q: contract rejects but Validate accepted", email, role)
		}
	})
}

// ── validRole / Can table (RBAC truth table is the source of truth) ───────────

func TestValidRole_Exhaustive(t *testing.T) {
	for _, r := range []string{"owner", "admin", "developer", "billing", "viewer"} {
		if !validRole(r) {
			t.Fatalf("validRole(%q) = false, want true", r)
		}
	}
	for _, r := range []string{"", "Owner", "OWNER", "root", "owner ", " owner", "owner\x00"} {
		if validRole(r) {
			t.Fatalf("validRole(%q) = true, want false", r)
		}
	}
}

func FuzzValidRole(f *testing.F) {
	for _, s := range []string{"owner", "admin", "", "root", "Owner", "\x00", "viewer\n"} {
		f.Add(s)
	}
	known := map[string]bool{"owner": true, "admin": true, "developer": true, "billing": true, "viewer": true}
	f.Fuzz(func(t *testing.T, s string) {
		if validRole(s) != known[s] {
			t.Fatalf("validRole(%q)=%v disagrees with allowlist=%v", s, validRole(s), known[s])
		}
		// Can() must never panic and must deny for any unknown role.
		if !known[s] && (Can(Role(s), CapOrgRead) || Can(Role(s), CapBillingManage)) {
			t.Fatalf("unknown role %q granted a capability", s)
		}
	})
}

// ── invite token crypto: hash is sha256-hex; generate is prefixed + roundtrips ─

func TestHashInviteToken_KnownVector(t *testing.T) {
	const tok = "mbi_deadbeef"
	sum := sha256.Sum256([]byte(tok))
	want := hex.EncodeToString(sum[:])
	if got := hashInviteToken(tok); got != want {
		t.Fatalf("hashInviteToken(%q) = %q, want %q", tok, got, want)
	}
}

func TestGenerateInviteToken_ShapeAndUniqueness(t *testing.T) {
	ct1, h1, err := generateInviteToken()
	if err != nil {
		t.Fatalf("generateInviteToken: %v", err)
	}
	ct2, h2, err := generateInviteToken()
	if err != nil {
		t.Fatalf("generateInviteToken: %v", err)
	}
	if !strings.HasPrefix(ct1, inviteTokenPrefix) {
		t.Fatalf("cleartext %q missing prefix %q", ct1, inviteTokenPrefix)
	}
	if h1 != hashInviteToken(ct1) {
		t.Fatal("returned hash must equal hashInviteToken(cleartext)")
	}
	if ct1 == ct2 || h1 == h2 {
		t.Fatal("two mints must differ (entropy)")
	}
	// 32 raw bytes → 64 hex chars; +prefix.
	if len(ct1) != len(inviteTokenPrefix)+inviteTokenBytes*2 {
		t.Fatalf("cleartext len %d, want %d", len(ct1), len(inviteTokenPrefix)+inviteTokenBytes*2)
	}
}

func FuzzHashInviteToken(f *testing.F) {
	for _, s := range []string{"", "mbi_x", "\x00", strings.Repeat("a", 4096), "a\nb"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, tok string) {
		h := hashInviteToken(tok)
		// Always 64 lower-hex chars, and deterministic.
		if len(h) != 64 {
			t.Fatalf("hash of %q has len %d, want 64", tok, len(h))
		}
		if _, err := hex.DecodeString(h); err != nil {
			t.Fatalf("hash %q is not hex: %v", h, err)
		}
		if h != hashInviteToken(tok) {
			t.Fatalf("hash of %q not deterministic", tok)
		}
	})
}

// ── const-error parity ────────────────────────────────────────────────────────

func TestOrgsConstErrorParity(t *testing.T) {
	cases := []struct {
		err error
		msg string
	}{
		{ErrNotFound, "org not found"},
		{ErrConflict, "org already exists"},
		{ErrForbidden, "forbidden"},
		{ErrLastOwner, "cannot remove the last owner"},
		{ErrInviteInvalid, "invite token invalid"},
		{ErrInviteExpired, "invite token expired"},
		{ErrInviteConsumed, "invite already consumed"},
	}
	for _, c := range cases {
		if c.err.Error() != c.msg {
			t.Fatalf("Error() = %q, want %q", c.err.Error(), c.msg)
		}
		if !errors.Is(fmt.Errorf("ctx: %w", c.err), c.err) {
			t.Fatalf("errors.Is(wrap(%q), sentinel) = false", c.msg)
		}
	}
	// Distinct sentinels do not alias.
	if errors.Is(ErrInviteExpired, ErrInviteConsumed) {
		t.Fatal("ErrInviteExpired must not match ErrInviteConsumed")
	}
}
