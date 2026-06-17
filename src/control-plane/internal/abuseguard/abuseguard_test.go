package abuseguard

import (
	"log/slog"
	"testing"
)

func newTestGuard() *Guard {
	return &Guard{
		log:         slog.New(slog.NewTextHandler(discard{}, nil)),
		velocityMax: 20,
	}
}

// TestVerificationGate is the KYC-lite decision: a tier with NO requirement always
// passes (the parity default); a tier requiring email/phone/pay denies when the
// corresponding signal is missing and passes when present.
func TestVerificationGate(t *testing.T) {
	g := newTestGuard()
	g.tierReqs = map[string]requirement{
		"nano": {email: true},
		"pro":  {email: true, phone: true, payMethod: true},
	}

	// No requirement for an unknown tier → always ok (parity).
	if _, ok := g.verificationGate("essential", safetyRow{}); !ok {
		t.Fatal("tier with no requirement must pass")
	}

	// nano requires email.
	if reason, ok := g.verificationGate("nano", safetyRow{}); ok || reason != "email_unverified" {
		t.Fatalf("nano unverified: got (%q,%v), want (email_unverified,false)", reason, ok)
	}
	if _, ok := g.verificationGate("nano", safetyRow{emailVerified: true}); !ok {
		t.Fatal("nano with verified email must pass")
	}

	// pro requires all three; missing pay-method denies last.
	full := safetyRow{emailVerified: true, phoneVerified: true, payMethod: false}
	if reason, ok := g.verificationGate("pro", full); ok || reason != "pay_method_required" {
		t.Fatalf("pro missing pay: got (%q,%v), want (pay_method_required,false)", reason, ok)
	}
	full.payMethod = true
	if _, ok := g.verificationGate("pro", full); !ok {
		t.Fatal("pro fully verified must pass")
	}
}

// TestVelocityLimited: only project_create is velocity-tracked today.
func TestVelocityLimited(t *testing.T) {
	g := newTestGuard()
	if !g.velocityLimited(ActionProjectCreate) {
		t.Fatal("project_create must be velocity limited")
	}
	if g.velocityLimited("read_rows") {
		t.Fatal("non-sensitive action must not be velocity limited")
	}
}

// TestEnvBoolDefault: ABUSE_AUTO_SUSPEND defaults true (a velocity breach is a
// strong signal) but an explicit "0" turns it off.
func TestEnvBoolDefault(t *testing.T) {
	t.Setenv("X_TEST_AUTOSUSPEND", "")
	if !envBoolDefault("X_TEST_AUTOSUSPEND", true) {
		t.Fatal("unset must use the default (true)")
	}
	t.Setenv("X_TEST_AUTOSUSPEND", "0")
	if envBoolDefault("X_TEST_AUTOSUSPEND", true) {
		t.Fatal("explicit 0 must override the default")
	}
	t.Setenv("X_TEST_AUTOSUSPEND", "on")
	if !envBoolDefault("X_TEST_AUTOSUSPEND", false) {
		t.Fatal("explicit on must be true")
	}
}

// TestLoadTierRequirements: ABUSE_REQUIRE_<TIER> parses a comma list of signals;
// an absent tier requires nothing (parity).
func TestLoadTierRequirements(t *testing.T) {
	t.Setenv("ABUSE_REQUIRE_NANO", "email")
	t.Setenv("ABUSE_REQUIRE_FREE", "email,phone,pay")
	reqs := loadTierRequirements()
	if r := reqs["nano"]; !r.email || r.phone || r.payMethod {
		t.Fatalf("nano req = %+v, want {email}", r)
	}
	if r := reqs["free"]; !r.email || !r.phone || !r.payMethod {
		t.Fatalf("free req = %+v, want all", r)
	}
	if _, ok := reqs["pro"]; ok {
		t.Fatal("unset tier must have no requirement")
	}
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }
