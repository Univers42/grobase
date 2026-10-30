package main

import "testing"

// D1 (ADR 0023): tenant-control signs data-plane calls with its own key when
// one is set, and with the shared token otherwise, so an unset key changes
// nothing.
func TestDataPlaneSigningKeyPrefersTheTenantControlKey(t *testing.T) {
	t.Setenv("DATA_PLANE_KEY_TENANT_CONTROL", "")
	if got := dataPlaneSigningKey("shared"); got != "shared" {
		t.Fatalf("unset key: got %q, want the shared token", got)
	}
	t.Setenv("DATA_PLANE_KEY_TENANT_CONTROL", "tc-own-key")
	if got := dataPlaneSigningKey("shared"); got != "tc-own-key" {
		t.Fatalf("set key: got %q, want the tenant-control key", got)
	}
}
