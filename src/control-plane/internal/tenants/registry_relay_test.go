package tenants

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// registrySeen is what the registry stub observed on its last call.
type registrySeen struct {
	path   string
	signed bool
	apikey string
	tenant string
}

// registryStub stands in for adapter-registry-go: it records the call and answers
// 201 when signed with relayToken, 401 otherwise, echoing a DSN the relay must redact.
func registryStub(t *testing.T, seen *registrySeen) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*seen = registrySeen{
			path:   r.URL.Path,
			signed: serviceauth.VerifyServiceRequest(r, relayToken),
			apikey: r.Header.Get("apikey"),
			tenant: r.Header.Get("X-Baas-Tenant-Id"),
		}
		if !seen.signed {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"dsn":"postgres://u:secret@db:5432/x"}`)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func registryRelayMux(t *testing.T, seen *registrySeen) *http.ServeMux {
	t.Helper()
	t.Setenv("SERVICE_TOKEN_MODE", "hmac")
	svc := &Service{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	svc.adapter = NewAdapterRegistry(registryStub(t, seen).URL, relayToken)
	mux := http.NewServeMux()
	Mount(mux, Deps{Svc: svc, ServiceToken: relayToken, KongServiceKey: relayKey})
	return mux
}

func relayCall(mux http.Handler, method, path, apikey string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, registryRelayPrefix+path, strings.NewReader(`{"name":"db"}`))
	req.Header.Set("X-Baas-Tenant-Id", "t-acme")
	if apikey != "" {
		req.Header.Set("apikey", apikey)
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	return w
}

func TestRegistryRelaySignsOpenRoutesForKongKey(t *testing.T) {
	var seen registrySeen
	mux := registryRelayMux(t, &seen)
	for _, c := range []struct{ method, path string }{
		{http.MethodPost, "/databases"},
		{http.MethodGet, "/databases"},
		{http.MethodGet, "/databases/m1"},
		{http.MethodGet, "/databases/m1/descriptor"},
	} {
		w := relayCall(mux, c.method, c.path, relayKey)
		if w.Code != http.StatusCreated || !seen.signed || seen.path != c.path {
			t.Errorf("%s %s: status %d signed=%v path=%q", c.method, c.path, w.Code, seen.signed, seen.path)
		}
		if seen.apikey != "" || seen.tenant != "t-acme" {
			t.Errorf("%s %s: apikey forwarded=%q tenant=%q", c.method, c.path, seen.apikey, seen.tenant)
		}
		if strings.Contains(w.Body.String(), "secret") {
			t.Errorf("%s %s: DSN credentials relayed: %s", c.method, c.path, w.Body.String())
		}
	}
}

// connect, PATCH and DELETE never gain a signature from the Kong key alone.
func TestRegistryRelayKeepsCallerOnlyRoutesUnsigned(t *testing.T) {
	var seen registrySeen
	mux := registryRelayMux(t, &seen)
	for _, c := range []struct{ method, path string }{
		{http.MethodGet, "/databases/m1/connect"},
		{http.MethodPatch, "/databases/m1"},
		{http.MethodDelete, "/databases/m1"},
		{http.MethodDelete, "/databases/m1/self"},
	} {
		if w := relayCall(mux, c.method, c.path, relayKey); w.Code != http.StatusUnauthorized || seen.signed {
			t.Errorf("%s %s: status %d signed=%v, want 401 unsigned", c.method, c.path, w.Code, seen.signed)
		}
	}
}

// A script signs the upstream path itself; the relay forwards that signature as is.
func TestRegistryRelayPassesCallerSignatureThrough(t *testing.T) {
	var seen registrySeen
	mux := registryRelayMux(t, &seen)
	signer := httptest.NewRequest(http.MethodDelete, "/databases/m1", nil)
	serviceauth.SignRequest(signer, relayToken, nil)
	req := httptest.NewRequest(http.MethodDelete, registryRelayPrefix+"/databases/m1", nil)
	req.Header.Set("X-Service-Auth", signer.Header.Get("X-Service-Auth"))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusCreated || !seen.signed {
		t.Fatalf("caller-signed DELETE: status %d signed=%v", w.Code, seen.signed)
	}
}

func TestRegistryRelayRefusesWithoutCredentials(t *testing.T) {
	var seen registrySeen
	mux := registryRelayMux(t, &seen)
	for _, key := range []string{"", "wrong-key"} {
		if w := relayCall(mux, http.MethodPost, "/databases", key); w.Code != http.StatusUnauthorized || seen.path != "" {
			t.Errorf("apikey %q: status %d, registry reached=%q", key, w.Code, seen.path)
		}
	}
}
