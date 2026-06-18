package entitlements

import (
	"context"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
)

// fakeLoader is a Loader returning a single canned row (or ErrNotFound), so
// Resolve is provable without a live database. It counts reads so the disabled-
// resolver parity test can assert the store is never touched.
type fakeLoader struct {
	rec  *Record // nil → ErrNotFound (the parity path)
	err  error   // optional read error (fail-open path)
	hits int
}

func (f *fakeLoader) Load(ctx context.Context, slug string) (Record, error) {
	f.hits++
	if f.err != nil {
		return Record{}, f.err
	}
	if f.rec == nil {
		return Record{}, ErrNotFound
	}
	return *f.rec, nil
}

func loadManifest(t *testing.T) *packages.Manifest {
	t.Helper()
	m, err := packages.Load()
	if err != nil {
		t.Fatalf("load manifest: %v", err)
	}
	return m
}

// TestResolveNoRowParity: BUILDER_ENABLED on but no entitlement row → exactly
// manifest.For(plan). This is the core parity guarantee.
func TestResolveNoRowParity(t *testing.T) {
	m := loadManifest(t)
	r := NewResolver(m, &fakeLoader{rec: nil}, true, nil)

	name, pkg := r.Resolve(context.Background(), "t1", "pro")
	wantName, wantPkg := m.For("pro")
	if name != wantName {
		t.Errorf("no-row name = %q, want %q (parity)", name, wantName)
	}
	if pkg.Limits.RPS != wantPkg.Limits.RPS || pkg.PoolPolicy.MaxMounts != wantPkg.PoolPolicy.MaxMounts {
		t.Errorf("no-row pkg must equal manifest.For(pro): got rps=%d mounts=%d", pkg.Limits.RPS, pkg.PoolPolicy.MaxMounts)
	}
}

// TestResolveDisabledParity: a disabled resolver never reads the store and always
// returns manifest.For — byte-parity even if a row exists.
func TestResolveDisabledParity(t *testing.T) {
	m := loadManifest(t)
	fl := &fakeLoader{rec: &Record{
		TenantID: "t1", Status: "active",
		Entitlement: CustomEntitlement{Limits: &EntitlementLimits{RPS: u32(9999)}},
	}}
	r := NewResolver(m, fl, false /* disabled */, nil)

	name, pkg := r.Resolve(context.Background(), "t1", "pro")
	wantName, wantPkg := m.For("pro")
	if name != wantName || pkg.Limits.RPS != wantPkg.Limits.RPS {
		t.Errorf("disabled resolver must be parity: got name=%q rps=%d", name, pkg.Limits.RPS)
	}
	if fl.hits != 0 {
		t.Errorf("disabled resolver must NOT read the store, did %d reads", fl.hits)
	}
}

// TestResolveDraftParity: a non-active (draft) row is not in force → parity.
func TestResolveDraftParity(t *testing.T) {
	m := loadManifest(t)
	fl := &fakeLoader{rec: &Record{
		TenantID: "t1", Status: "draft",
		Entitlement: CustomEntitlement{Limits: &EntitlementLimits{RPS: u32(50)}},
	}}
	r := NewResolver(m, fl, true, nil)

	_, pkg := r.Resolve(context.Background(), "t1", "pro")
	_, wantPkg := m.For("pro")
	if pkg.Limits.RPS != wantPkg.Limits.RPS {
		t.Errorf("draft row must not apply: got rps=%d want %d (parity)", pkg.Limits.RPS, wantPkg.Limits.RPS)
	}
}

// TestResolveReadErrorFailsOpen: a store read error resolves the named tier
// (fail-OPEN to the paid plan, never fail-CLOSED), and never widens past it.
func TestResolveReadErrorFailsOpen(t *testing.T) {
	m := loadManifest(t)
	fl := &fakeLoader{err: context.DeadlineExceeded}
	r := NewResolver(m, fl, true, nil)

	_, pkg := r.Resolve(context.Background(), "t1", "essential")
	_, ess := m.For("essential")
	if pkg.Limits.RPS != ess.Limits.RPS {
		t.Errorf("read error must fall back to manifest.For(essential), got rps=%d want %d", pkg.Limits.RPS, ess.Limits.RPS)
	}
}

// TestResolveAppliesCustomWithinCeiling: an active row narrowing within the plan
// is applied (rps lowered, max_mounts lowered).
func TestResolveAppliesCustomWithinCeiling(t *testing.T) {
	m := loadManifest(t)
	fl := &fakeLoader{rec: &Record{
		TenantID: "t1", Status: "active",
		Entitlement: CustomEntitlement{
			Limits:    &EntitlementLimits{RPS: u32(250)},
			MaxMounts: intp(3),
		},
	}}
	r := NewResolver(m, fl, true, nil)

	_, pkg := r.Resolve(context.Background(), "t1", "pro") // pro rps 400, mounts 10
	if pkg.Limits.RPS != 250 {
		t.Errorf("custom rps 250 within pro 400 must apply, got %d", pkg.Limits.RPS)
	}
	if pkg.PoolPolicy.MaxMounts != 3 {
		t.Errorf("custom max_mounts 3 within pro 10 must apply, got %d", pkg.PoolPolicy.MaxMounts)
	}
}

// TestResolveClampOnDowngradeBackstop: the LOAD-BEARING backstop. An entitlement
// written when the tenant was on pro (rps 400, schema_ddl ON, mounts 10) is
// stored, then the tenant is downgraded to essential (rps 200, schema_ddl OFF,
// mounts 2). Resolve must CLAMP the stale over-ceiling row DOWN — never trust it.
func TestResolveClampOnDowngradeBackstop(t *testing.T) {
	m := loadManifest(t)
	fl := &fakeLoader{rec: &Record{
		TenantID: "t1", Status: "active",
		Entitlement: CustomEntitlement{
			Limits:       &EntitlementLimits{RPS: u32(400)},   // pro-era, above essential 200
			Capabilities: map[string]bool{"schema_ddl": true}, // pro-era ON, essential OFF
			MaxMounts:    intp(10),                            // pro-era, above essential 2
		},
	}}
	r := NewResolver(m, fl, true, nil)

	name, pkg := r.Resolve(context.Background(), "t1", "essential")
	_, ess := m.For("essential")
	if name != "essential" {
		t.Errorf("ceiling name should be essential, got %q", name)
	}
	if pkg.Limits.RPS != ess.Limits.RPS {
		t.Errorf("stale over-ceiling rps must clamp to essential %d, got %d (BACKSTOP FAILED)", ess.Limits.RPS, pkg.Limits.RPS)
	}
	if pkg.Capabilities["schema_ddl"] {
		t.Error("stale schema_ddl=true must clamp to essential OFF (BACKSTOP FAILED — capability widened past ceiling)")
	}
	if pkg.PoolPolicy.MaxMounts > ess.PoolPolicy.MaxMounts {
		t.Errorf("stale over-ceiling max_mounts must clamp to essential %d, got %d (BACKSTOP FAILED)", ess.PoolPolicy.MaxMounts, pkg.PoolPolicy.MaxMounts)
	}
}

// TestResolveCeilingPlanWins: an operator ceiling_plan raises the ceiling above
// the tenant's own plan (a sales deal), so a custom value between the two tiers
// is honored.
func TestResolveCeilingPlanWins(t *testing.T) {
	m := loadManifest(t)
	fl := &fakeLoader{rec: &Record{
		TenantID: "t1", Status: "active",
		CeilingPlan: "pro",                                                        // operator deal: ceiling is pro even though plan is essential
		Entitlement: CustomEntitlement{Limits: &EntitlementLimits{RPS: u32(350)}}, // > essential 200, < pro 400
	}}
	r := NewResolver(m, fl, true, nil)

	name, pkg := r.Resolve(context.Background(), "t1", "essential")
	if name != "pro" {
		t.Errorf("ceiling name should be the operator ceiling_plan pro, got %q", name)
	}
	if pkg.Limits.RPS != 350 {
		t.Errorf("rps 350 within the pro ceiling (400) must apply, got %d", pkg.Limits.RPS)
	}
}

func u32(v uint32) *uint32 { return &v }
func intp(v int) *int      { return &v }
