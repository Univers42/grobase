/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   validate_fuzz_test.go                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:00:08 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:00:10 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// The documented tenant-slug charset (mirror of the DB CHECK + idRe()):
//
//	^[a-z0-9][a-z0-9_-]{1,62}$
//
// i.e. 2..63 chars, first char alnum-lowercase, rest [a-z0-9_-].
const slugPatternMirror = `^[a-z0-9][a-z0-9_-]{1,62}$`

// uuidPatternMirror is the same pattern isUUID compiles.
const uuidPatternMirror = `^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`

// ── CreateTenantRequest.Validate edge/table ──────────────────────────────────

func TestCreateTenantRequestValidate_Edges(t *testing.T) {
	cases := []struct {
		name string
		id   string
		nm   string
		ok   bool
	}{
		{"min len 2", "ab", "n", true},
		{"len 1 rejected (needs >=2)", "a", "n", false},
		{"exactly 63 ok", "a" + strings.Repeat("b", 62), "n", true},
		{"64 rejected", "a" + strings.Repeat("b", 63), "n", false},
		{"first char digit ok", "0a", "n", true},
		{"first char dash rejected", "-a", "n", false},
		{"first char underscore rejected", "_a", "n", false},
		{"trailing dash ok", "a-", "n", true},
		{"trailing underscore ok", "a_", "n", true},
		{"uppercase rejected", "Ab", "n", false},
		{"empty id rejected", "", "n", false},
		{"valid id empty name rejected", "ab", "", false},
		{"dot rejected", "a.b", "n", false},
		{"space rejected", "a b", "n", false},
		{"embedded NUL rejected", "a\x00b", "n", false},
		{"newline rejected", "a\nb", "n", false},
		{"unicode rejected", "aé", "n", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := CreateTenantRequest{ID: c.id, Name: c.nm}.Validate()
			if c.ok && err != nil {
				t.Fatalf("id=%q name=%q: want accept, got %v", c.id, c.nm, err)
			}
			if !c.ok && err == nil {
				t.Fatalf("id=%q name=%q: want reject, got nil", c.id, c.nm)
			}
		})
	}
}

// FuzzCreateTenantRequestValidate: never panics; and when the name is non-empty,
// Validate's accept/reject decision matches recompiling the SAME slug regex.
func FuzzCreateTenantRequestValidate(f *testing.F) {
	for _, s := range []string{
		"ab", "a", "", "0a", "-a", "_a", "a-", "A", "a.b",
		"a b", "a\x00b", "a\nb", "aé", strings.Repeat("z", 63), strings.Repeat("z", 64), "::*",
	} {
		f.Add(s)
	}
	re := regexp.MustCompile(slugPatternMirror)
	f.Fuzz(func(t *testing.T, id string) {
		// Name fixed non-empty so the only variable is the slug decision.
		err := CreateTenantRequest{ID: id, Name: "fixed"}.Validate()
		want := re.MatchString(id)
		if want && err != nil {
			t.Fatalf("regex accepts %q but Validate rejected: %v", id, err)
		}
		if !want && err == nil {
			t.Fatalf("regex rejects %q but Validate accepted", id)
		}
	})
}

// ── ProvisionRequest.Validate fuzz (slug + mount shape) ───────────────────────

func TestProvisionRequestValidate_Edges(t *testing.T) {
	good := ProvisionRequest{Tenant: "ab"}
	if err := good.Validate(); err != nil {
		t.Fatalf("bare valid slug, no mounts: want accept, got %v", err)
	}
	// A valid slug but a mount missing a required field is rejected.
	bad := ProvisionRequest{Tenant: "ab", Mounts: []MountSpec{{Engine: "postgres", Name: ""}}}
	if err := bad.Validate(); err == nil {
		t.Fatal("mount missing name/dsn: want reject, got nil")
	}
	// Fully-formed mount + slug is accepted.
	full := ProvisionRequest{Tenant: "ab", Mounts: []MountSpec{
		{Engine: "postgres", Name: "main", ConnectionString: "postgres://x"},
	}}
	if err := full.Validate(); err != nil {
		t.Fatalf("complete mount: want accept, got %v", err)
	}
}

func FuzzProvisionRequestValidate(f *testing.F) {
	for _, s := range []string{"ab", "a", "", "-x", "A", "x\x00", "::"} {
		f.Add(s)
	}
	re := regexp.MustCompile(slugPatternMirror)
	f.Fuzz(func(t *testing.T, tenant string) {
		// No mounts → the only gate is the slug; parity with the regex.
		err := ProvisionRequest{Tenant: tenant}.Validate()
		want := re.MatchString(tenant)
		if want && err != nil {
			t.Fatalf("regex accepts %q but Validate rejected: %v", tenant, err)
		}
		if !want && err == nil {
			t.Fatalf("regex rejects %q but Validate accepted", tenant)
		}
	})
}

// ── isUUID fuzz + edges ───────────────────────────────────────────────────────

func TestIsUUID_Edges(t *testing.T) {
	cases := map[string]bool{
		"00000000-0000-0000-0000-000000000000":  true,
		"DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF":  true, // uppercase hex ok
		"deadbeef-dead-beef-dead-beefdeadbeef":  true,
		"":                                      false,
		"not-a-uuid":                            false,
		"00000000-0000-0000-0000-00000000000":   false, // one short
		"00000000-0000-0000-0000-0000000000000": false, // one long
		"gggggggg-0000-0000-0000-000000000000":  false, // non-hex
		"00000000_0000_0000_0000_000000000000":  false, // wrong separator
	}
	for in, want := range cases {
		if got := isUUID(in); got != want {
			t.Fatalf("isUUID(%q) = %v, want %v", in, got, want)
		}
	}
}

func FuzzIsUUID(f *testing.F) {
	for _, s := range []string{
		"00000000-0000-0000-0000-000000000000",
		"DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF",
		"", "x", "\x00", "g-g-g-g-g",
		"00000000-0000-0000-0000-00000000000",
	} {
		f.Add(s)
	}
	re := regexp.MustCompile(uuidPatternMirror)
	f.Fuzz(func(t *testing.T, s string) {
		if isUUID(s) != re.MatchString(s) {
			t.Fatalf("isUUID(%q)=%v disagrees with regexp.MatchString=%v", s, isUUID(s), re.MatchString(s))
		}
	})
}

// ── parseKey fuzz + edges (untrusted credential parser) ───────────────────────

func TestParseKey_Boundaries(t *testing.T) {
	pfx := strings.Repeat("a", prefixLen) // 12 chars
	cases := []struct {
		name string
		key  string
		ok   bool
	}{
		{"valid min payload 16", keyHeader + pfx + "_" + strings.Repeat("p", 16), true},
		{"valid max payload 64", keyHeader + pfx + "_" + strings.Repeat("p", 64), true},
		{"payload 15 too short", keyHeader + pfx + "_" + strings.Repeat("p", 15), false},
		{"payload 65 too long", keyHeader + pfx + "_" + strings.Repeat("p", 65), false},
		{"missing header", pfx + "_" + strings.Repeat("p", 32), false},
		{"prefix 11 too short", keyHeader + strings.Repeat("a", 11) + "_" + strings.Repeat("p", 32), false},
		{"prefix 13 too long", keyHeader + strings.Repeat("a", 13) + "_" + strings.Repeat("p", 32), false},
		{"no underscore", keyHeader + pfx + strings.Repeat("p", 32), false},
		{"empty", "", false},
		{"header only", keyHeader, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, _, err := parseKey(c.key)
			if c.ok && err != nil {
				t.Fatalf("key %q: want accept, got %v", c.key, err)
			}
			if !c.ok && err == nil {
				t.Fatalf("key %q: want reject (errInvalidFormat), got nil", c.key)
			}
			if !c.ok && err != nil && !errors.Is(err, errInvalidFormat) {
				t.Fatalf("key %q: rejected with %v, want errInvalidFormat", c.key, err)
			}
		})
	}
}

// FuzzParseKey: never panics; and any successful parse satisfies the documented
// structural contract (mbk_ header, 12-char prefix, 16..64 payload, roundtrips).
func FuzzParseKey(f *testing.F) {
	for _, s := range []string{
		"mbk_aaaaaaaaaaaa_pppppppppppppppp",
		"mbk_", "", "mbk__", "mbk_short_x", "\x00", "mbk_aaaaaaaaaaaa_",
		"MBK_aaaaaaaaaaaa_pppppppppppppppp", "mbk_aaaaaaaaaaaa_p_p_p_p_p_p_p_p",
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, full string) {
		prefix, payload, err := parseKey(full)
		if err != nil {
			if !errors.Is(err, errInvalidFormat) {
				t.Fatalf("parseKey(%q) error %v, want errInvalidFormat", full, err)
			}
			return
		}
		// Accepted: every documented invariant must hold.
		if !strings.HasPrefix(full, keyHeader) {
			t.Fatalf("accepted %q without %q header", full, keyHeader)
		}
		if len(prefix) != prefixLen {
			t.Fatalf("accepted %q with prefix len %d, want %d", full, len(prefix), prefixLen)
		}
		if len(payload) < 16 || len(payload) > 64 {
			t.Fatalf("accepted %q with payload len %d, want 16..64", full, len(payload))
		}
		// Roundtrip: the parsed pieces reconstruct the input.
		if got := keyHeader + prefix + "_" + payload; got != full {
			t.Fatalf("roundtrip mismatch: parseKey(%q) -> %q", full, got)
		}
	})
}

// ── const-error parity (var→const error refactor preserved semantics) ─────────

func TestTenantsConstErrorParity(t *testing.T) {
	cases := []struct {
		err error
		msg string
	}{
		{ErrNotFound, "tenant not found"},
		{ErrConflict, "tenant already exists"},
		{errInvalidFormat, "api key has invalid format"},
	}
	for _, c := range cases {
		if c.err.Error() != c.msg {
			t.Fatalf("Error() = %q, want %q", c.err.Error(), c.msg)
		}
		wrapped := fmt.Errorf("ctx: %w", c.err)
		if !errors.Is(wrapped, c.err) {
			t.Fatalf("errors.Is(wrap(%q), sentinel) = false, want true", c.msg)
		}
	}
	// Distinct sentinels must not alias each other.
	if errors.Is(ErrNotFound, ErrConflict) {
		t.Fatal("ErrNotFound must not match ErrConflict")
	}
}
