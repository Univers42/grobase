package tenants

import (
	"net/http"
	"testing"
)

// D1 (ADR 0023): the relay still admits callers on the shared token, but signs
// the hop to the data plane with the key the DataPlane was built with, which
// is tenant-control's own key when DATA_PLANE_KEY_TENANT_CONTROL is set.
func TestAdminRelaySignsTheDataPlaneHopWithItsOwnKey(t *testing.T) {
	t.Setenv("SERVICE_TOKEN_MODE", "hmac")
	const tcKey = "tenant-control-own-key-0123456789abcdef"
	stub := &dataPlaneStub{key: tcKey, status: http.StatusOK, answer: `{"status":"applied"}`}
	mux := relayMux(NewDataPlane(stub.serve(t).URL, tcKey), relayKey)
	rec := post(mux, "/v1/admin/migrate", sdkBody, withServiceSignature(sdkBody))
	if rec.Code != http.StatusOK {
		t.Fatalf("relay signed with the tenant-control key = %d, want 200", rec.Code)
	}
	shared := &dataPlaneStub{key: tcKey, status: http.StatusOK}
	mux = relayMux(NewDataPlane(shared.serve(t).URL, relayToken), relayKey)
	rec = post(mux, "/v1/admin/migrate", sdkBody, withServiceSignature(sdkBody))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("relay signed with the shared token = %d, want the stub's 401", rec.Code)
	}
}
