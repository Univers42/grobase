package funcsecrets

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

const (
	testShared = "shared-0c1d"
	testScoped = "scoped-9a7e"
)

// devil F1 (b)2, 2026-10-30: resolve accepts the scoped or the shared token and
// refuses everything else, including the old fail-open (no shared token, any caller).
func TestResolveAuthorized(t *testing.T) {
	cases := []struct {
		name           string
		shared, scoped string
		header         string
		sendHeader     bool
		want           bool
	}{
		{"scoped", testShared, testScoped, testScoped, true, true},
		{"shared until the cutover", testShared, testScoped, testShared, true, true},
		{"shared with no scoped token", testShared, "", testShared, true, true},
		{"scoped with no shared token", "", testScoped, testScoped, true, true},
		{"wrong token", testShared, testScoped, "nope", true, false},
		{"no header", testShared, testScoped, "", false, false},
		{"both tokens empty", "", "", "", true, false},
		{"both empty, any header", "", "", "anything", true, false},
		{"empty header, scoped unset", testShared, "", "", true, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rt := &routes{serviceToken: c.shared, scopedToken: c.scoped}
			req := httptest.NewRequest(http.MethodGet, "/internal/v1/function-secrets/resolve?tenant=t1", nil)
			if c.sendHeader {
				req.Header.Set("X-Internal-Service-Token", c.header)
			}
			if got := rt.resolveAuthorized(req); got != c.want {
				t.Fatalf("resolveAuthorized = %v, want %v", got, c.want)
			}
		})
	}
}

// A refused caller gets 401 before the service is touched (svc is nil here).
func TestResolveRefusesBeforeLookup(t *testing.T) {
	mux := http.NewServeMux()
	Mount(mux, nil, "", "")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/internal/v1/function-secrets/resolve?tenant=t1", nil)
	req.Header.Set("X-Internal-Service-Token", "")
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("resolve with no tokens configured = %d, want 401", rec.Code)
	}
}
