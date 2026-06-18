package provision

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestReconciler() *Reconciler {
	return &Reconciler{
		Tenants: &fakeTenants{},
		Perm:    &fakePerm{roleCreated: true, polCreated: true},
		Mounts:  &fakeMounts{},
		Schemas: &fakeSchemas{},
	}
}

func TestMountRequiresServiceToken(t *testing.T) {
	mux := http.NewServeMux()
	Mount(mux, newTestReconciler(), "tok")

	req := httptest.NewRequest(http.MethodPost, "/v1/provision", strings.NewReader(`{"tenant":"acme"}`))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("no token: code = %d, want 401", rec.Code)
	}
}

func TestMountCreatesTenant201(t *testing.T) {
	mux := http.NewServeMux()
	Mount(mux, newTestReconciler(), "tok")

	body := `{"tenant":"acme","owner_user_id":"00000000-0000-4000-8000-000000000001",
	          "roles":[{"name":"user","policies":[{"resource_type":"*","resource_name":"*","actions":["select"],"effect":"allow"}]}],
	          "engines":[{"engine":"redis","name":"cache","connection_string":"redis://x"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/provision", strings.NewReader(body))
	req.Header.Set("X-Service-Token", "tok")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("code = %d, want 201; body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"outcome":"complete"`) {
		t.Errorf("body missing complete outcome: %s", rec.Body.String())
	}
}

func TestMountBadSlug400(t *testing.T) {
	mux := http.NewServeMux()
	Mount(mux, newTestReconciler(), "tok")

	req := httptest.NewRequest(http.MethodPost, "/v1/provision", strings.NewReader(`{"tenant":"BAD SLUG"}`))
	req.Header.Set("X-Service-Token", "tok")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("code = %d, want 400", rec.Code)
	}
}

func TestMountBusy409(t *testing.T) {
	rc := newTestReconciler()
	rc.Lock = busyLocker{}
	mux := http.NewServeMux()
	Mount(mux, rc, "tok")

	req := httptest.NewRequest(http.MethodPost, "/v1/provision", strings.NewReader(`{"tenant":"acme"}`))
	req.Header.Set("X-Service-Token", "tok")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict {
		t.Fatalf("code = %d, want 409", rec.Code)
	}
}
