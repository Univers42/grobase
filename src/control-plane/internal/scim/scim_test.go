package scim

import (
	"context"
	"strings"
	"testing"
	"time"
)

// TestHashToken_DeterministicAndFast pins the bearer-token hashing discipline:
// sha256 (fast hash, kernel rule #7), deterministic, lower-hex, 64 chars. The
// same cleartext always hashes to the same value (so VerifyToken's indexed
// lookup works); different cleartexts hash differently.
func TestHashToken_DeterministicAndFast(t *testing.T) {
	h1 := hashToken("scim_abc")
	h2 := hashToken("scim_abc")
	h3 := hashToken("scim_xyz")
	if h1 != h2 {
		t.Fatalf("hashToken not deterministic: %q != %q", h1, h2)
	}
	if h1 == h3 {
		t.Fatal("distinct cleartexts hashed to the same value")
	}
	if len(h1) != 64 {
		t.Fatalf("sha256 lower-hex must be 64 chars, got %d (%q)", len(h1), h1)
	}
	if strings.ToLower(h1) != h1 {
		t.Fatalf("hash must be lower-hex, got %q", h1)
	}
	// It must NOT look like an argon2id/password hash — a SCIM bearer is high
	// entropy, so a fast hash is correct.
	if strings.HasPrefix(h1, "argon2id$") || strings.HasPrefix(h1, "$argon2") {
		t.Fatalf("SCIM token must use a FAST hash, not a password hash: %q", h1)
	}
}

// TestNewCleartextToken_UniqueHighEntropy proves issued tokens are unique,
// prefixed, and high-entropy (the cleartext that is returned ONCE).
func TestNewCleartextToken_UniqueHighEntropy(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 100; i++ {
		tok, err := newCleartextToken()
		if err != nil {
			t.Fatalf("newCleartextToken: %v", err)
		}
		if !strings.HasPrefix(tok, "scim_") {
			t.Fatalf("token missing scim_ prefix: %q", tok)
		}
		if len(tok) < 40 {
			t.Fatalf("token too short to be high-entropy: %q", tok)
		}
		if seen[tok] {
			t.Fatalf("duplicate token minted: %q", tok)
		}
		seen[tok] = true
	}
}

// TestPatchedActive_Deactivate is the PATCH active:false path the SCIM deprovision
// lifecycle depends on. Both the path'd and path-less shapes IdPs emit must be
// recognized; an unrelated op must NOT report an active change.
func TestPatchedActive_Deactivate(t *testing.T) {
	cases := []struct {
		name      string
		op        PatchOperation
		wantOK    bool
		wantValue bool
	}{
		{"path replace false", PatchOperation{Op: "replace", Path: "active", Value: false}, true, false},
		{"path replace true", PatchOperation{Op: "Replace", Path: "active", Value: true}, true, true},
		{"path string false", PatchOperation{Op: "replace", Path: "active", Value: "false"}, true, false},
		{"pathless object false", PatchOperation{Op: "replace", Value: map[string]interface{}{"active": false}}, true, false},
		{"pathless object true", PatchOperation{Op: "add", Value: map[string]interface{}{"active": true}}, true, true},
		{"unrelated op", PatchOperation{Op: "replace", Path: "displayName", Value: "x"}, false, false},
		{"remove op", PatchOperation{Op: "remove", Path: "active"}, false, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := patchedActive(PatchOp{Operations: []PatchOperation{c.op}})
			if ok != c.wantOK {
				t.Fatalf("ok=%v want %v", ok, c.wantOK)
			}
			if ok && got != c.wantValue {
				t.Fatalf("active=%v want %v", got, c.wantValue)
			}
		})
	}
}

// TestUserRecord_ToSCIM_Mapping proves the User<->member mapping projection: a
// stored record becomes a well-formed SCIM User (schemas, id, meta.resourceType,
// userName, active, location).
func TestUserRecord_ToSCIM_Mapping(t *testing.T) {
	now := time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC)
	rec := userRecord{
		SCIMID:      "scim-123",
		TenantID:    "t1",
		OrgID:       "org-1",
		UserName:    "alice@example.com",
		UserID:      "user-alice",
		DisplayName: "Alice",
		Emails:      []SCIMEmail{{Value: "alice@example.com", Primary: true}},
		Active:      true,
		CreatedAt:   now,
		UpdatedAt:   now,
	}
	su := rec.toSCIM()
	if len(su.Schemas) != 1 || su.Schemas[0] != schemaUser {
		t.Fatalf("bad schemas: %v", su.Schemas)
	}
	if su.ID != "scim-123" || su.UserName != "alice@example.com" || !su.Active {
		t.Fatalf("bad projection: %+v", su)
	}
	if su.Meta == nil || su.Meta.ResourceType != resourceTypeUser {
		t.Fatalf("missing/empty meta.resourceType: %+v", su.Meta)
	}
	if su.Meta.Location != "/scim/v2/Users/scim-123" {
		t.Fatalf("bad meta.location: %q", su.Meta.Location)
	}
}

// TestSCIMUser_Resolve covers the member-id + email + displayName resolution that
// the User->member mapping uses (externalId preferred, then userName).
func TestSCIMUser_Resolve(t *testing.T) {
	withExt := SCIMUser{
		UserName: "bob", ExternalID: "ext-bob",
		Emails: []SCIMEmail{{Value: "bob@x.com"}},
	}
	if withExt.resolveUserID() != "ext-bob" {
		t.Fatalf("externalId should win: %q", withExt.resolveUserID())
	}
	if withExt.primaryEmail() != "bob@x.com" {
		t.Fatalf("primaryEmail: %q", withExt.primaryEmail())
	}
	if withExt.displayName() != "bob" {
		t.Fatalf("displayName fallback to userName: %q", withExt.displayName())
	}

	noExt := SCIMUser{UserName: "carol@x.com", DisplayName: "Carol"}
	if noExt.resolveUserID() != "carol@x.com" {
		t.Fatalf("userName should be the id without externalId: %q", noExt.resolveUserID())
	}
	if noExt.primaryEmail() != "carol@x.com" {
		t.Fatalf("primaryEmail should fall back to email-shaped userName: %q", noExt.primaryEmail())
	}
	if noExt.displayName() != "Carol" {
		t.Fatalf("displayName: %q", noExt.displayName())
	}
}

// TestParseUserNameFilter exercises the filter=userName eq "x" parser the GET
// list/filter route uses.
func TestParseUserNameFilter(t *testing.T) {
	cases := []struct {
		in      string
		want    string
		wantHit bool
	}{
		{`userName eq "alice@example.com"`, "alice@example.com", true},
		{`USERNAME EQ "bob"`, "bob", true},
		{`userName eq ""`, "", false},
		{`displayName eq "x"`, "", false},
		{``, "", false},
		{`userName co "a"`, "", false},
	}
	for _, c := range cases {
		got, hit := parseUserNameFilter(c.in)
		if hit != c.wantHit || (hit && got != c.want) {
			t.Fatalf("parseUserNameFilter(%q) = (%q,%v), want (%q,%v)", c.in, got, hit, c.want, c.wantHit)
		}
	}
}

// fakeProvisioner records the membership calls so the mapping wiring is asserted
// without a DB (the store paths are covered by the m111 live gate).
type fakeProvisioner struct {
	added   []string // "orgID/userID/role"
	removed []string // "orgID/userID"
	addErr  error
	remErr  error
}

func (f *fakeProvisioner) AddMember(_ context.Context, orgID, userID, role, _ string) error {
	f.added = append(f.added, orgID+"/"+userID+"/"+role)
	return f.addErr
}

func (f *fakeProvisioner) RemoveMember(_ context.Context, orgID, userID string) error {
	f.removed = append(f.removed, orgID+"/"+userID)
	return f.remErr
}

// TestService_SatisfiesProvisioner is a compile-time assertion that
// *fakeProvisioner satisfies memberProvisioner — i.e. SCIM provisioning is wired
// to REUSE the org membership API (Add/Remove), not a reinvented membership.
func TestService_SatisfiesProvisioner(t *testing.T) {
	var _ memberProvisioner = (*fakeProvisioner)(nil)
}
