package tenants

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// devil D2 N6: the relay in front of the real adapter-registry handler under
// ADAPTER_REGISTRY_REQUIRE_SERVICE_AUTH=enforce. The registry has no store, so a
// call that passes its gate stops at 400 on the invalid body; 401 is the gate.
// Caveat: Kong is not in this loop; its routing to the relay is m229's job.
func enforcedRegistry(t *testing.T) (relay *http.ServeMux, registryURL string) {
	t.Helper()
	t.Setenv("SERVICE_TOKEN_MODE", "hmac")
	t.Setenv("ADAPTER_REGISTRY_REQUIRE_SERVICE_AUTH", "enforce")
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "")
	regMux := http.NewServeMux()
	adapterregistry.Mount(regMux, nil, relayToken, nil)
	reg := httptest.NewServer(regMux)
	t.Cleanup(reg.Close)
	svc := &Service{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	svc.adapter = NewAdapterRegistry(reg.URL, relayToken)
	relay = http.NewServeMux()
	Mount(relay, Deps{Svc: svc, ServiceToken: relayToken, KongServiceKey: relayKey})
	return relay, reg.URL
}

func TestEnforcedRegistryRefusesUnsignedRegister(t *testing.T) {
	_, url := enforcedRegistry(t)
	req, _ := http.NewRequest(http.MethodPost, url+"/databases", strings.NewReader("{"))
	req.Header.Set("X-Baas-Tenant-Id", "t-acme")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unsigned register under enforce: %d, want 401", resp.StatusCode)
	}
}

func TestEnforcedRegistryAcceptsRelaySignedRegister(t *testing.T) {
	relay, _ := enforcedRegistry(t)
	req := httptest.NewRequest(http.MethodPost, registryRelayPrefix+"/databases", strings.NewReader("{"))
	req.Header.Set("apikey", relayKey)
	req.Header.Set("X-Baas-Tenant-Id", "t-acme")
	w := httptest.NewRecorder()
	relay.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("relay-signed register under enforce: %d %s, want 400 past the gate", w.Code, w.Body.String())
	}
}

// A script's own signature over the upstream path survives the relay.
func TestEnforcedRegistryAcceptsCallerSignedRegister(t *testing.T) {
	relay, _ := enforcedRegistry(t)
	signer := httptest.NewRequest(http.MethodPost, "/databases", nil)
	serviceauth.SignRequest(signer, relayToken, []byte("{"))
	req := httptest.NewRequest(http.MethodPost, registryRelayPrefix+"/databases", strings.NewReader("{"))
	req.Header.Set("X-Service-Auth", signer.Header.Get("X-Service-Auth"))
	req.Header.Set("X-Baas-Tenant-Id", "t-acme")
	w := httptest.NewRecorder()
	relay.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("caller-signed register under enforce: %d %s, want 400 past the gate", w.Code, w.Body.String())
	}
}
