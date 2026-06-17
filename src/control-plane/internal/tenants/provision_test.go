package tenants

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"regexp"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
)

// fakePerm is a minimal provision.PermissionEngine that records the role name
// AssignRole is called with, so a test can pin the slug-namespaced behavior
// without a live DB (seedDefaultRole only touches the perm seam).
type fakePerm struct {
	assignedRole string
	roleID       string
}

func (f *fakePerm) EnsureRole(_ context.Context, slug string, r provision.RoleSpec) (string, bool, error) {
	if f.roleID == "" {
		f.roleID = "role-uuid-1"
	}
	return f.roleID, true, nil
}
func (f *fakePerm) EnsurePolicy(_ context.Context, _ string, _ provision.PolicySpec) (bool, error) {
	return true, nil
}
func (f *fakePerm) AssignRole(_ context.Context, _, roleName string) error {
	f.assignedRole = roleName
	return nil
}
func (f *fakePerm) Decide(_ context.Context, _, _, _, _ string) (bool, error) { return true, nil }

// TestSeedDefaultRoleNamespacesRoleName pins the namespaced behavior change: the
// default seeded role is `<slug>:user`, NOT a bare global "user" (which would
// collide on UNIQUE(roles.name) across tenants). This is the role string that
// ends up in Bootstrap(...).Roles.
func TestSeedDefaultRoleNamespacesRoleName(t *testing.T) {
	fp := &fakePerm{}
	svc := &Service{perm: fp, log: slog.Default()}
	owner := "00000000-0000-4000-8000-000000000001"

	got, err := svc.seedDefaultRole(context.Background(), "acme", owner, "")
	if err != nil {
		t.Fatalf("seedDefaultRole error: %v", err)
	}
	want := "acme:" + provision.D().RoleName // "acme:user"
	if got != want {
		t.Errorf("seeded role = %q, want slug-namespaced %q", got, want)
	}
	if fp.assignedRole != want {
		t.Errorf("AssignRole got %q, want %q", fp.assignedRole, want)
	}
}

// TestProvisionRequestCompileMapping pins the legacy→StackSpec mapping: Mounts→
// Engines, SeedRoles/DefaultRoleName→RoleSpec, DefaultKeyName→KeySpec. Defaults
// are intentionally left to StackSpec.Normalize (Compile only translates shape).
func TestProvisionRequestCompileMapping(t *testing.T) {
	req := ProvisionRequest{
		Tenant:          "acme",
		Name:            "Acme Inc",
		Plan:            "pro",
		OwnerUserID:     "00000000-0000-4000-8000-000000000001",
		DefaultRoleName: "editor",
		DefaultKeyName:  "primary",
		SeedRoles:       true,
		Mounts: []MountSpec{
			{Engine: "postgresql", Name: "main", ConnectionString: "postgres://x", Isolation: "schema_per_tenant"},
			{Engine: "redis", Name: "cache", ConnectionString: "redis://x"},
		},
	}
	spec := req.Compile()

	if spec.Tenant != "acme" || spec.Name != "Acme Inc" || spec.OwnerUserID != req.OwnerUserID {
		t.Errorf("scalar mapping off: %+v", spec)
	}
	// Plan must survive the request→StackSpec boundary (else every tenant
	// silently defaults to free — the bug the live re-bench surfaced).
	if spec.Plan != "pro" {
		t.Errorf("Plan = %q, want pro (dropped at the request boundary)", spec.Plan)
	}
	// DefaultKeyName → one KeySpec.
	if len(spec.Keys) != 1 || spec.Keys[0].Name != "primary" {
		t.Errorf("Keys mapping = %+v, want one named 'primary'", spec.Keys)
	}
	// SeedRoles + DefaultRoleName → one RoleSpec with the baseline policy.
	if len(spec.Roles) != 1 || spec.Roles[0].Name != "editor" {
		t.Fatalf("Roles mapping = %+v, want one named 'editor'", spec.Roles)
	}
	if len(spec.Roles[0].Policies) != 1 {
		t.Errorf("role should carry the baseline policy, got %d", len(spec.Roles[0].Policies))
	}
	// Mounts → Engines (order + fields preserved).
	if len(spec.Engines) != 2 {
		t.Fatalf("Engines mapping = %+v, want 2", spec.Engines)
	}
	if spec.Engines[0].Engine != "postgresql" || spec.Engines[0].Name != "main" ||
		spec.Engines[0].ConnectionString != "postgres://x" || spec.Engines[0].Isolation != "schema_per_tenant" {
		t.Errorf("engine[0] mapping off: %+v", spec.Engines[0])
	}
	if spec.Engines[1].Engine != "redis" || spec.Engines[1].Name != "cache" {
		t.Errorf("engine[1] mapping off: %+v", spec.Engines[1])
	}

	// SeedRoles=false → no roles mapped.
	noRoles := ProvisionRequest{Tenant: "acme"}.Compile()
	if len(noRoles.Roles) != 0 {
		t.Errorf("SeedRoles=false must map zero roles, got %d", len(noRoles.Roles))
	}
}

func TestAdapterRegistryRegister(t *testing.T) {
	cases := []struct {
		name       string
		statusCode int
		body       string
		wantStatus string
		wantID     string
		wantErr    bool
	}{
		// On 409 the register recovers the existing mount id via GET /databases
		// (idempotency — re-provision must still return a usable db_id).
		{"created", http.StatusCreated, `{"id":"abc","engine":"redis","name":"r"}`, "created", "abc", false},
		{"conflict_is_idempotent", http.StatusConflict, `{"error":"conflict"}`, "exists", "existing-id", false},
		{"server_error", http.StatusInternalServerError, `{"error":"boom"}`, "", "", true},
		{"validation_error", http.StatusBadRequest, `{"error":"validation_error"}`, "", "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				// Mounts must be scoped by the tenant slug (the query path's key).
				if r.Header.Get("X-Baas-Tenant-Id") != "t-acme" {
					t.Errorf("missing/incorrect X-Baas-Tenant-Id: %q", r.Header.Get("X-Baas-Tenant-Id"))
				}
				// Conflict-recovery lookup: list the tenant's mounts by name.
				if r.Method == http.MethodGet && r.URL.Path == "/databases" {
					_, _ = w.Write([]byte(`[{"id":"existing-id","name":"r"}]`))
					return
				}
				if r.Method != http.MethodPost || r.URL.Path != "/databases" {
					t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
				}
				w.WriteHeader(c.statusCode)
				_, _ = w.Write([]byte(c.body))
			}))
			defer srv.Close()

			ar := NewAdapterRegistry(srv.URL, "tok")
			id, status, err := ar.register(context.Background(), "t-acme",
				MountSpec{Engine: "redis", Name: "r", ConnectionString: "redis://x:6379"})

			if c.wantErr != (err != nil) {
				t.Fatalf("err = %v, wantErr = %v", err, c.wantErr)
			}
			if c.wantErr {
				return
			}
			if status != c.wantStatus {
				t.Errorf("status = %q, want %q", status, c.wantStatus)
			}
			if id != c.wantID {
				t.Errorf("id = %q, want %q", id, c.wantID)
			}
		})
	}
}

func TestNewAdapterRegistryTrimsTrailingSlash(t *testing.T) {
	ar := NewAdapterRegistry("http://adapter-registry-go:3021/", "tok")
	if ar.baseURL != "http://adapter-registry-go:3021" {
		t.Fatalf("baseURL = %q, want trailing slash trimmed", ar.baseURL)
	}
}

// TestTenantSchemaMatchesRust pins the Go schema derivation to the SAME vectors
// asserted by the Rust `DatabaseMount::tenant_schema` tests (mount.rs). If these
// two drift, schema_per_tenant breaks silently — so keep both in lockstep.
func TestTenantSchemaMatchesRust(t *testing.T) {
	cases := map[string]string{
		"acme":                                 "tenant_acme",
		"t-Acme_2":                             "tenant_t_acme_2",
		"00000000-0000-4000-8000-000000000003": "tenant_00000000_0000_4000_8000_000000000003",
		"---":                                  "", // sanitizes to empty
	}
	// Any non-empty output MUST match the safe schema-name shape so it can never
	// carry an injection vector when interpolated into CREATE SCHEMA DDL.
	safe := regexp.MustCompile(`^tenant_[a-z0-9_]+$`)
	for in, want := range cases {
		got := tenantSchema(in)
		if got != want {
			t.Errorf("tenantSchema(%q) = %q, want %q", in, got, want)
		}
		if got != "" && !safe.MatchString(got) {
			t.Errorf("tenantSchema(%q) = %q, must match %s", in, got, safe.String())
		}
	}
	// Adversarial inputs must also sanitize to the safe shape (or empty).
	for _, in := range []string{"a; DROP SCHEMA public", "x'--", "Tab\tCo", "пример", "a/b\\c"} {
		got := tenantSchema(in)
		if got != "" && !safe.MatchString(got) {
			t.Errorf("tenantSchema(%q) = %q escaped the safe charset", in, got)
		}
	}
}

func TestDataPlaneEnsureSchema(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/admin/migrate" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if r.Header.Get("X-Service-Token") != "tok" {
			t.Errorf("missing service token header")
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"name":"x","status":"applied","statements_run":1}`))
	}))
	defer srv.Close()

	dp := NewDataPlane(srv.URL, "tok")
	if err := dp.ensureSchema(context.Background(), "t-acme", "tenant_t_acme",
		MountSpec{Engine: "postgresql", Name: "db", ConnectionString: "postgres://x"}); err != nil {
		t.Fatalf("ensureSchema returned error: %v", err)
	}

	// 5xx must surface as an error.
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"boom"}`))
	}))
	defer bad.Close()
	dp2 := NewDataPlane(bad.URL, "tok")
	if err := dp2.ensureSchema(context.Background(), "t-acme", "tenant_t_acme",
		MountSpec{Engine: "postgresql", Name: "db", ConnectionString: "postgres://x"}); err == nil {
		t.Fatal("expected error on 5xx, got nil")
	}
}
