/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service_gate_test.go                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 17:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 17:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// gatedRequest builds a register call the gate sees; the body is invalid JSON so a
// request that passes the gate stops at 400 before the service (nil here) is reached.
func gatedRequest(signed bool) *http.Request {
	body := []byte("{")
	r := httptest.NewRequest(http.MethodPost, "/databases", bytes.NewReader(body))
	r.Header.Set("X-Baas-Tenant-Id", "tenant-1")
	if signed {
		serviceauth.SignRequest(r, testToken, body)
	}
	return r
}

func serveGated(t *testing.T, stage string, signed bool) int {
	t.Helper()
	t.Setenv(serviceGateEnv, stage)
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "")
	mux := http.NewServeMux()
	Mount(mux, nil, testToken, nil)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, gatedRequest(signed))
	return w.Code
}

func TestServiceGateStages(t *testing.T) {
	cases := []struct {
		stage  string
		signed bool
		want   int
	}{
		{"", false, http.StatusBadRequest},
		{"bogus", false, http.StatusBadRequest},
		{"shadow", false, http.StatusBadRequest},
		{"enforce", false, http.StatusUnauthorized},
		{"ENFORCE", true, http.StatusBadRequest},
		{"enforce", true, http.StatusBadRequest},
	}
	for _, c := range cases {
		if got := serveGated(t, c.stage, c.signed); got != c.want {
			t.Errorf("stage=%q signed=%v: status %d, want %d", c.stage, c.signed, got, c.want)
		}
	}
}

// Every gated route answers 401 unsigned under enforce; /connect keeps its own guard.
func TestServiceGateCoversReadRoutes(t *testing.T) {
	t.Setenv(serviceGateEnv, "enforce")
	mux := http.NewServeMux()
	Mount(mux, nil, testToken, nil)
	for _, path := range []string{"/databases", "/databases/x", "/databases/x/descriptor", "/databases/x/connect"} {
		r := httptest.NewRequest(http.MethodGet, path, nil)
		r.Header.Set("X-Baas-Tenant-Id", "tenant-1")
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		if w.Code != http.StatusUnauthorized {
			t.Errorf("GET %s unsigned under enforce: %d, want 401", path, w.Code)
		}
	}
}

// N5: with identity HMAC off, a service-signed caller carrying only a tenant header
// passes both guards /connect applies, as data-plane-server and query-router do.
func TestConnectGuardsPassWithoutIdentityHMAC(t *testing.T) {
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "")
	rt := &routes{serviceToken: testToken}
	r := httptest.NewRequest(http.MethodGet, "/databases/x/connect", nil)
	r.Header.Set("X-Tenant-Id", "user-1")
	serviceauth.SignRequest(r, testToken, nil)
	if !rt.validServiceToken(r) {
		t.Fatal("signed /connect rejected by the service guard")
	}
	if got, ok := rt.requireUser(httptest.NewRecorder(), r); !ok || got != "user-1" {
		t.Fatalf("requireUser = %q/%v, want user-1/true", got, ok)
	}
}

func TestServiceGateShadowLogNamesRouteNotSecrets(t *testing.T) {
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	defer slog.SetDefault(prev)
	r := gatedRequest(false)
	r.Header.Set("X-Service-Token", "wrong-secret-value")
	t.Setenv(serviceGateEnv, "shadow")
	mux := http.NewServeMux()
	Mount(mux, nil, testToken, nil)
	mux.ServeHTTP(httptest.NewRecorder(), r)
	out := buf.String()
	if !strings.Contains(out, serviceGateLogMsg) || !strings.Contains(out, "POST /databases") {
		t.Fatalf("shadow log missing message or route: %q", out)
	}
	if strings.Contains(out, "wrong-secret-value") || strings.Contains(out, testToken) {
		t.Fatalf("shadow log leaked a token: %q", out)
	}
}
