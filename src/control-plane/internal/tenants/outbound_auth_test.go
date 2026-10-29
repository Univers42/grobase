package tenants

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// verifyingServer answers 200 only when the request passes the same
// serviceauth check the adapter-registry and data plane run on their side.
func verifyingServer(t *testing.T, token string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !serviceauth.VerifyServiceRequest(r, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// In hmac mode the receivers reject a plain X-Service-Token, so every outbound
// call must carry a signature the receiver accepts, in both modes.
func TestOutboundCallsAuthenticateInBothModes(t *testing.T) {
	for _, mode := range []string{"", "hmac"} {
		t.Run("mode="+mode, func(t *testing.T) {
			t.Setenv("SERVICE_TOKEN_MODE", mode)
			ctx := context.Background()

			ar := NewAdapterRegistry(verifyingServer(t, "tok").URL, "tok")
			if deleted, err := ar.deleteMount(ctx, "t-acme", "db1"); err != nil || !deleted {
				t.Fatalf("deleteMount = (%v, %v), want (true, nil)", deleted, err)
			}
			if status, _, err := ar.patchMount(ctx, "t-acme", "db1", []byte(`{"name":"n"}`)); err != nil || status != http.StatusOK {
				t.Fatalf("patchMount = (%v, %v), want (200, nil)", status, err)
			}

			dp := NewDataPlane(verifyingServer(t, "tok").URL, "tok")
			if err := dp.evictVerify(ctx); err != nil {
				t.Fatalf("evictVerify: %v", err)
			}
		})
	}
}

// patchCall is one recorded adapter-registry call including the VERBATIM
// request body bytes.
type patchCall struct{ method, path, tenant, body string }

// scriptedRegistry answers every adapter-registry call with a fixed
// (status, body) and records each call's method, path, tenant scope and raw
// body bytes.
func scriptedRegistry(t *testing.T, status int, respBody string) (*AdapterRegistry, func() []patchCall) {
	t.Helper()
	var mu sync.Mutex
	var calls []patchCall
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		calls = append(calls, patchCall{r.Method, r.URL.Path, r.Header.Get("X-Baas-Tenant-Id"), string(body)})
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(respBody))
	}))
	t.Cleanup(srv.Close)
	recorded := func() []patchCall {
		mu.Lock()
		defer mu.Unlock()
		return append([]patchCall(nil), calls...)
	}
	return NewAdapterRegistry(srv.URL, "svc-token"), recorded
}

// serveBody is serve with a raw request body, so a PATCH can be forwarded
// byte-for-byte; a handler panic reads as a failure, not a crashed binary.
func serveBody(t *testing.T, mux *http.ServeMux, method, path, key, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if key != "" {
		req.Header.Set("X-API-Key", key)
	}
	rec := httptest.NewRecorder()
	defer func() {
		if p := recover(); p != nil {
			t.Fatalf("%s %s panicked: %v", method, path, p)
		}
	}()
	mux.ServeHTTP(rec, req)
	return rec
}

// patchMux wires MountBuilder over a scripted registry with one write-scoped
// "acme" key, the shared setup of every patchMount route test below.
func patchMux(t *testing.T, regStatus int, regBody string) (*http.ServeMux, string, func() []patchCall) {
	t.Helper()
	svc := &Service{verifyC: testCache(time.Minute, 16)}
	key := seedKey(t, svc, "acme", "write")
	adapter, calls := scriptedRegistry(t, regStatus, regBody)
	mux := http.NewServeMux()
	MountBuilder(mux, BuilderDeps{Svc: svc, Adapter: adapter})
	return mux, key, calls
}

// The body reaches the registry as the EXACT bytes the caller sent (odd
// spacing and unknown fields included) over PATCH /databases/{id}, and the
// registry's 200 answer is relayed back.
func TestPatchMountForwardsTheBodyVerbatim(t *testing.T) {
	answer := `{"id":"` + mountUUID + `","name":"renamed"}`
	mux, key, calls := patchMux(t, http.StatusOK, answer)

	body := `{ "name":  "renamed", "unknown_field": {"a": [1, 2]} }`
	rec := serveBody(t, mux, http.MethodPatch, mountsPath+"/"+mountUUID, key, body)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body %s", rec.Code, rec.Body)
	}
	var got, want map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode body %q: %v", rec.Body, err)
	}
	if err := json.Unmarshal([]byte(answer), &want); err != nil {
		t.Fatalf("decode answer %q: %v", answer, err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("relayed body = %v, want %v", got, want)
	}
	wantCalls := []patchCall{{http.MethodPatch, "/databases/" + mountUUID, "acme", body}}
	if c := calls(); !reflect.DeepEqual(c, wantCalls) {
		t.Errorf("adapter-registry calls = %+v, want %+v", c, wantCalls)
	}
}

// The registry's 400/403/409 answers are already safe {error,message} JSON;
// the handler relays status and body untouched.
func TestPatchMountRelaysTheRegistrysSafeBodies(t *testing.T) {
	cases := []struct {
		status int
		body   string
	}{
		{http.StatusBadRequest, `{"error":"validation_error","message":"unknown field"}`},
		{http.StatusForbidden, `{"error":"mount_denied","message":"engine over tier"}`},
		{http.StatusConflict, `{"error":"conflict","message":"name already used"}`},
	}
	for _, c := range cases {
		t.Run(http.StatusText(c.status), func(t *testing.T) {
			mux, key, _ := patchMux(t, c.status, c.body)

			rec := serveBody(t, mux, http.MethodPatch, mountsPath+"/"+mountUUID, key, `{"name":"renamed"}`)

			if rec.Code != c.status {
				t.Fatalf("status = %d, want %d; body %s", rec.Code, c.status, rec.Body)
			}
			var got, want map[string]any
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("decode body %q: %v", rec.Body, err)
			}
			if err := json.Unmarshal([]byte(c.body), &want); err != nil {
				t.Fatalf("decode scripted body %q: %v", c.body, err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Errorf("body = %v, want the registry body %v passed through", got, want)
			}
		})
	}
}

// A 404 from the caller-scoped registry is the tenant-level not_found, and an
// unexpected status becomes a 502 — the registry body is never relayed in
// either mapped answer.
func TestPatchMountMapsRegistryFailures(t *testing.T) {
	cases := []struct {
		name       string
		regStatus  int
		wantStatus int
		wantErr    string
		wantMsg    string
	}{
		{"404 is not_found", http.StatusNotFound, http.StatusNotFound, "not_found", "no such mount for this tenant"},
		{"500 is a 502", http.StatusInternalServerError, http.StatusBadGateway, "adapter_error", "adapter-registry returned 500"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			mux, key, _ := patchMux(t, c.regStatus, `{"error":"boom","message":"postgres://u:p@db/x"}`)

			rec := serveBody(t, mux, http.MethodPatch, mountsPath+"/"+mountUUID, key, `{"name":"renamed"}`)

			if rec.Code != c.wantStatus {
				t.Fatalf("status = %d, want %d; body %s", rec.Code, c.wantStatus, rec.Body)
			}
			var got map[string]any
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("decode body %q: %v", rec.Body, err)
			}
			if got["error"] != c.wantErr || got["message"] != c.wantMsg {
				t.Errorf("body = %v, want error=%q message=%q", got, c.wantErr, c.wantMsg)
			}
			if strings.Contains(rec.Body.String(), "boom") || strings.Contains(rec.Body.String(), "postgres://") {
				t.Errorf("registry body leaked into the mapped answer: %s", rec.Body)
			}
		})
	}
}

// A transport failure surfaces as 502 adapter_error, like deleteMount.
func TestPatchMountRegistryDownIs502(t *testing.T) {
	svc := &Service{verifyC: testCache(time.Minute, 16)}
	key := seedKey(t, svc, "acme", "write")
	srv := httptest.NewServer(http.NotFoundHandler())
	srv.Close()
	mux := http.NewServeMux()
	MountBuilder(mux, BuilderDeps{Svc: svc, Adapter: NewAdapterRegistry(srv.URL, "svc-token")})

	rec := serveBody(t, mux, http.MethodPatch, mountsPath+"/"+mountUUID, key, `{"name":"renamed"}`)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502; body %s", rec.Code, rec.Body)
	}
	var got map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil || got["error"] != "adapter_error" {
		t.Errorf("body = %s (%v), want adapter_error", rec.Body, err)
	}
}

// A non-UUID {mountId} is refused by the handler itself — the registry is
// never called.
func TestPatchMountRefusesANonUUIDBeforeTheRegistry(t *testing.T) {
	mux, key, calls := patchMux(t, http.StatusOK, `{}`)

	rec := serveBody(t, mux, http.MethodPatch, mountsPath+"/m1", key, `{"name":"renamed"}`)

	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404; body %s", rec.Code, rec.Body)
	}
	if c := calls(); len(c) != 0 {
		t.Errorf("refused request reached the adapter-registry: %+v", c)
	}
}

// The read-only list surface never gains the write route: PATCH stays
// builder-only and never reaches the registry through MountMountList.
func TestMountMountListDoesNotRoutePatch(t *testing.T) {
	svc := &Service{verifyC: testCache(time.Minute, 16)}
	key := seedKey(t, svc, "acme", "write")
	adapter, calls := scriptedRegistry(t, http.StatusOK, `{}`)
	mux := http.NewServeMux()
	MountMountList(mux, BuilderDeps{Svc: svc, Adapter: adapter})

	rec := serveBody(t, mux, http.MethodPatch, mountsPath+"/"+mountUUID, key, `{"name":"renamed"}`)

	if rec.Code != http.StatusNotFound && rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("status = %d, want 404 or 405; body %s", rec.Code, rec.Body)
	}
	if c := calls(); len(c) != 0 {
		t.Errorf("unrouted PATCH reached the adapter-registry: %+v", c)
	}
}
