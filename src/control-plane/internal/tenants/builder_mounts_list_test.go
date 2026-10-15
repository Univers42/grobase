package tenants

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"sync"
	"testing"
	"time"
)

const mountsPath = "/v1/tenants/me/mounts"

// seedKey mints a well-formed key and answers its verification from the verify
// cache, so self-auth resolves the tenant without postgres behind svc.
func seedKey(t *testing.T, svc *Service, tenant string, scopes ...string) string {
	t.Helper()
	_, key, _, err := newKeyHasher().generateKey()
	if err != nil {
		t.Fatalf("generateKey: %v", err)
	}
	svc.verifyC.put(keyHash(key), VerifyKeyResponse{Valid: true, TenantID: tenant, Scopes: scopes})
	return key
}

type registryCall struct{ method, path, tenant string }

// fakeMountRegistry answers every adapter-registry call with rows and records
// the tenant scope each call asserted.
func fakeMountRegistry(t *testing.T, rows any) (*AdapterRegistry, func() []registryCall) {
	t.Helper()
	var mu sync.Mutex
	var calls []registryCall
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls = append(calls, registryCall{r.Method, r.URL.Path, r.Header.Get("X-Baas-Tenant-Id")})
		mu.Unlock()
		_ = json.NewEncoder(w).Encode(rows)
	}))
	t.Cleanup(srv.Close)
	recorded := func() []registryCall {
		mu.Lock()
		defer mu.Unlock()
		return append([]registryCall(nil), calls...)
	}
	return NewAdapterRegistry(srv.URL, "svc-token"), recorded
}

// serve turns a handler panic into a test failure: a nil dependency then reads
// as a failed assertion instead of a crashed test binary.
func serve(t *testing.T, mux *http.ServeMux, method, path, key string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
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

func TestMountListServesTheCallersOwnMounts(t *testing.T) {
	mounters := []struct {
		name  string
		mount func(*http.ServeMux, BuilderDeps)
	}{
		{"MountMountList", MountMountList},
		{"MountBuilder", MountBuilder},
	}
	healthy := "2026-10-15T00:01:00Z"
	rows := []MountView{
		{ID: "m1", TenantID: "acme", Engine: "postgresql", Name: "main", CreatedAt: "2026-10-15T00:00:00Z", LastHealthyAt: &healthy},
		{ID: "m2", TenantID: "acme", Engine: "redis", Name: "cache", CreatedAt: "2026-10-15T00:00:00Z"},
	}
	for _, m := range mounters {
		t.Run(m.name, func(t *testing.T) {
			svc := &Service{verifyC: testCache(time.Minute, 16)}
			key := seedKey(t, svc, "acme", "read")
			adapter, calls := fakeMountRegistry(t, rows)
			mux := http.NewServeMux()
			m.mount(mux, BuilderDeps{Svc: svc, Adapter: adapter})

			rec := serve(t, mux, http.MethodGet, mountsPath, key)

			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200; body %s", rec.Code, rec.Body)
			}
			var got []MountView
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("decode body %q: %v", rec.Body, err)
			}
			if !reflect.DeepEqual(got, rows) {
				t.Errorf("mounts = %+v, want %+v", got, rows)
			}
			want := []registryCall{{http.MethodGet, "/databases", "acme"}}
			if c := calls(); !reflect.DeepEqual(c, want) {
				t.Errorf("adapter-registry calls = %+v, want %+v", c, want)
			}
		})
	}
}

// The read-only list must not open any builder write path, and keeps the
// builder's auth and "read" scope.
func TestMountMountListRoutesOnlyTheAuthenticatedRead(t *testing.T) {
	svc := &Service{verifyC: testCache(time.Minute, 16)}
	readKey := seedKey(t, svc, "acme", "read")
	writeOnlyKey := seedKey(t, svc, "acme", "write")
	adapter, calls := fakeMountRegistry(t, nil)
	mux := http.NewServeMux()
	MountMountList(mux, BuilderDeps{Svc: svc, Adapter: adapter})

	cases := []struct {
		name, method, path, key string
		want                    int
	}{
		{"no credential", http.MethodGet, mountsPath, "", http.StatusUnauthorized},
		{"credential without read scope", http.MethodGet, mountsPath, writeOnlyKey, http.StatusForbidden},
		{"create stays builder-only", http.MethodPost, mountsPath, readKey, http.StatusMethodNotAllowed},
		{"delete on the collection", http.MethodDelete, mountsPath, readKey, http.StatusMethodNotAllowed},
		{"delete one mount stays builder-only", http.MethodDelete, mountsPath + "/m1", readKey, http.StatusNotFound},
		{"entitlements stay builder-only", http.MethodGet, "/v1/tenants/me/entitlements", readKey, http.StatusNotFound},
		{"builder stays builder-only", http.MethodPost, "/v1/tenants/me/builder", readKey, http.StatusNotFound},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := serve(t, mux, c.method, c.path, c.key)
			if rec.Code != c.want {
				t.Errorf("%s %s = %d, want %d; body %s", c.method, c.path, rec.Code, c.want, rec.Body)
			}
		})
	}
	if c := calls(); len(c) != 0 {
		t.Errorf("rejected requests reached the adapter-registry: %+v", c)
	}
}

func TestMountMountListWithoutAdapterIsUnavailable(t *testing.T) {
	svc := &Service{verifyC: testCache(time.Minute, 16)}
	key := seedKey(t, svc, "acme", "read")
	mux := http.NewServeMux()
	MountMountList(mux, BuilderDeps{Svc: svc})

	if rec := serve(t, mux, http.MethodGet, mountsPath, key); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503; body %s", rec.Code, rec.Body)
	}
}

// The registry row carries the mount's DSN; the list answers the MountView
// projection only, so a credential never leaves through the self-serve route.
func TestMountListAnswersOnlyTheMountViewKeys(t *testing.T) {
	svc := &Service{verifyC: testCache(time.Minute, 16)}
	key := seedKey(t, svc, "acme", "read")
	row := map[string]any{
		"id": "m1", "tenant_id": "acme", "engine": "postgresql", "name": "main",
		"created_at": "2026-10-15T00:00:00Z", "last_healthy_at": nil,
		"connection_string": "postgres://u:p@db/main", "password": "p",
	}
	adapter, _ := fakeMountRegistry(t, []map[string]any{row})
	mux := http.NewServeMux()
	MountMountList(mux, BuilderDeps{Svc: svc, Adapter: adapter})

	rec := serve(t, mux, http.MethodGet, mountsPath, key)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body %s", rec.Code, rec.Body)
	}
	var got []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode body %q: %v", rec.Body, err)
	}
	want := []string{"created_at", "engine", "id", "last_healthy_at", "name", "tenant_id"}
	if len(got) != 1 {
		t.Fatalf("rows = %d, want 1", len(got))
	}
	keys := make([]string, 0, len(got[0]))
	for k := range got[0] {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if !reflect.DeepEqual(keys, want) {
		t.Errorf("keys = %v, want exactly %v", keys, want)
	}
}
