/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   reconcile_test.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:53:34 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:53:35 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package provision

import (
	"context"
	"errors"
	"testing"
)

// ── Fakes (counting calls so we can assert ZERO downstream writes on re-run) ──

type fakeTenants struct {
	exists      bool
	created     int
	createdPlan string
	failGet     bool
	failCreate  bool
	keyExists   bool
	issued      int
	failIssue   bool
}

func (f *fakeTenants) GetTenant(_ context.Context, slug string) (TenantInfo, bool, error) {
	if f.failGet {
		return TenantInfo{}, false, errors.New("db down")
	}
	if f.exists {
		return TenantInfo{Slug: slug, Name: slug}, true, nil
	}
	return TenantInfo{}, false, nil
}

func (f *fakeTenants) CreateTenant(_ context.Context, slug, name, _, plan string) (TenantInfo, error) {
	if f.failCreate {
		return TenantInfo{}, errors.New("create failed")
	}
	f.created++
	f.createdPlan = plan
	f.exists = true
	return TenantInfo{Slug: slug, Name: name, Plan: plan}, nil
}

func (f *fakeTenants) ActiveKeyExists(_ context.Context, _, _ string) (bool, error) {
	return f.keyExists, nil
}

func (f *fakeTenants) IssueAPIKey(_ context.Context, _ string, k KeySpec) (KeyInfo, error) {
	if f.failIssue {
		return KeyInfo{}, errors.New("issue failed")
	}
	f.issued++
	f.keyExists = true
	return KeyInfo{ID: "key-1", Name: k.Name, Key: "secret"}, nil
}

type fakePerm struct {
	roleID      string
	roleCreated bool
	ensureRole  int
	ensurePol   int
	assign      int
	failRole    bool
	polCreated  bool
}

func (p *fakePerm) EnsureRole(_ context.Context, _ string, _ RoleSpec) (string, bool, error) {
	if p.failRole {
		return "", false, errors.New("role failed")
	}
	p.ensureRole++
	id := p.roleID
	if id == "" {
		id = "role-uuid-1"
	}
	return id, p.roleCreated, nil
}

func (p *fakePerm) EnsurePolicy(_ context.Context, _ string, _ PolicySpec) (bool, error) {
	p.ensurePol++
	return p.polCreated, nil
}
func (p *fakePerm) AssignRole(_ context.Context, _, _ string) error { p.assign++; return nil }
func (p *fakePerm) Decide(_ context.Context, _, _, _, _ string) (bool, error) {
	return true, nil
}

type fakeMounts struct {
	calls  int
	status string
	fail   bool
}

func (m *fakeMounts) RegisterMount(_ context.Context, _ string, _ EngineSpec) (string, string, error) {
	if m.fail {
		return "", "", errors.New("mount failed")
	}
	m.calls++
	st := m.status
	if st == "" {
		st = "created"
	}
	return "mount-1", st, nil
}

type fakeSchemas struct {
	calls int
	fail  bool
}

func (s *fakeSchemas) EnsureSchema(_ context.Context, _ string, _ EngineSpec) (string, error) {
	if s.fail {
		return "", errors.New("schema failed")
	}
	s.calls++
	return "tenant_acme", nil
}

func baseSpec() StackSpec {
	return StackSpec{
		Tenant:      "acme",
		OwnerUserID: "00000000-0000-4000-8000-000000000001",
		Keys:        []KeySpec{{Name: "default", Scopes: []string{"read", "write"}}},
		Roles: []RoleSpec{{
			Name:     "user",
			Policies: []PolicySpec{{ResourceType: "*", ResourceName: "*", Actions: []string{"select"}, Effect: "allow"}},
		}},
		Engines: []EngineSpec{{Engine: "postgresql", Name: "main", ConnectionString: "postgres://x", Isolation: "schema_per_tenant"}},
	}
}

func statusFor(rs []ResourceResult, kind string) ResourceResult {
	for _, r := range rs {
		if r.Kind == kind {
			return r
		}
	}
	return ResourceResult{}
}

func TestReconcileFreshCreatesEverything(t *testing.T) {
	ft, fp, fm, fs := &fakeTenants{}, &fakePerm{roleCreated: true, polCreated: true}, &fakeMounts{}, &fakeSchemas{}
	rc := &Reconciler{Tenants: ft, Perm: fp, Mounts: fm, Schemas: fs}

	res, err := rc.Reconcile(context.Background(), baseSpec())
	if err != nil {
		t.Fatalf("Reconcile error: %v", err)
	}
	if res.Outcome != OutcomeComplete {
		t.Fatalf("outcome = %q, want complete; resources=%+v", res.Outcome, res.Resources)
	}
	if ft.created != 1 || ft.issued != 1 || fp.ensureRole != 1 || fp.ensurePol != 1 || fp.assign != 1 || fm.calls != 1 || fs.calls != 1 {
		t.Fatalf("downstream call counts off: %+v %+v %+v %+v", ft, fp, fm, fs)
	}
	if statusFor(res.Resources, "tenant").Status != StatusCreated {
		t.Errorf("tenant status = %q, want created", statusFor(res.Resources, "tenant").Status)
	}
	if res.APIKey == nil || res.APIKey.Key != "secret" {
		t.Error("expected fresh API key with cleartext secret")
	}
	if HTTPStatus(res.Outcome, res.APIKey != nil) != 201 {
		t.Error("fresh complete + fresh key should map to 201")
	}
}

func TestReconcileThreadsPlanIntoCreateTenant(t *testing.T) {
	ft, fp, fm, fs := &fakeTenants{}, &fakePerm{roleCreated: true, polCreated: true}, &fakeMounts{}, &fakeSchemas{}
	rc := &Reconciler{Tenants: ft, Perm: fp, Mounts: fm, Schemas: fs}

	spec := baseSpec()
	spec.Plan = "pro" // the requested billing plan must reach CreateTenant
	if _, err := rc.Reconcile(context.Background(), spec); err != nil {
		t.Fatalf("Reconcile error: %v", err)
	}
	if ft.createdPlan != "pro" {
		t.Fatalf("CreateTenant got plan %q, want \"pro\" (plan was silently dropped)", ft.createdPlan)
	}
}

func TestReconcileRerunIsNoOpWithZeroWrites(t *testing.T) {
	// Pre-converged state: tenant + key already exist, role/policy report exists.
	ft := &fakeTenants{exists: true, keyExists: true}
	fp := &fakePerm{roleCreated: false, polCreated: false}
	fm := &fakeMounts{status: "exists"}
	fs := &fakeSchemas{}
	rc := &Reconciler{Tenants: ft, Perm: fp, Mounts: fm, Schemas: fs}

	res, err := rc.Reconcile(context.Background(), baseSpec())
	if err != nil {
		t.Fatalf("Reconcile error: %v", err)
	}
	if res.Outcome != OutcomeComplete {
		t.Fatalf("outcome = %q, want complete", res.Outcome)
	}
	// ZERO writes: no tenant create, no key issue.
	if ft.created != 0 {
		t.Errorf("tenant created %d times on re-run, want 0", ft.created)
	}
	if ft.issued != 0 {
		t.Errorf("key issued %d times on re-run, want 0", ft.issued)
	}
	if res.APIKey != nil {
		t.Error("re-run must not surface a new key secret")
	}
	// Every resource must be NoOp/exists.
	for _, r := range res.Resources {
		if r.Action != string(ActionNoOp) && r.Status != StatusExists {
			t.Errorf("resource %s action=%q status=%q, want noop/exists", r.Kind, r.Action, r.Status)
		}
	}
	if HTTPStatus(res.Outcome, false) != 200 {
		t.Error("converged re-run should map to 200")
	}
}

func TestReconcileTenantFailureIsFatal(t *testing.T) {
	ft := &fakeTenants{failGet: true}
	rc := &Reconciler{Tenants: ft, Perm: &fakePerm{}, Mounts: &fakeMounts{}, Schemas: &fakeSchemas{}}
	res, err := rc.Reconcile(context.Background(), baseSpec())
	if err != nil {
		t.Fatalf("unexpected transport error: %v", err)
	}
	if res.Outcome != OutcomeFailed {
		t.Fatalf("outcome = %q, want failed", res.Outcome)
	}
	if HTTPStatus(res.Outcome, false) != 500 {
		t.Error("failed tenant step should map to 500")
	}
}

func TestReconcilePartialFailureBlocksDependentsNotRolledBack(t *testing.T) {
	// Role ensure fails → its policy must be BLOCKED, not attempted, and the
	// tenant/key that already succeeded are NOT rolled back.
	ft := &fakeTenants{}
	fp := &fakePerm{failRole: true}
	fm := &fakeMounts{}
	fs := &fakeSchemas{}
	rc := &Reconciler{Tenants: ft, Perm: fp, Mounts: fm, Schemas: fs}

	res, err := rc.Reconcile(context.Background(), baseSpec())
	if err != nil {
		t.Fatalf("Reconcile error: %v", err)
	}
	if res.Outcome != OutcomePartial {
		t.Fatalf("outcome = %q, want partial", res.Outcome)
	}
	if statusFor(res.Resources, "role").Status != StatusError {
		t.Errorf("role status = %q, want error", statusFor(res.Resources, "role").Status)
	}
	if statusFor(res.Resources, "policy").Status != StatusBlocked {
		t.Errorf("policy status = %q, want blocked", statusFor(res.Resources, "policy").Status)
	}
	if fp.ensurePol != 0 {
		t.Error("blocked policy must not issue a downstream write")
	}
	// Forward-only: tenant + key still created (no rollback).
	if ft.created != 1 || ft.issued != 1 {
		t.Errorf("partial failure rolled back prior steps: created=%d issued=%d", ft.created, ft.issued)
	}
	// Re-run with the role now succeeding fixes the gap (retryable).
	fp.failRole = false
	res2, _ := rc.Reconcile(context.Background(), baseSpec())
	if res2.Outcome != OutcomeComplete {
		t.Errorf("retry outcome = %q, want complete (partial failure must be retryable)", res2.Outcome)
	}
}

func TestReconcileDbPerTenantIsUnsupportedNotSilent(t *testing.T) {
	spec := baseSpec()
	spec.Engines = []EngineSpec{{Engine: "postgresql", Name: "main", ConnectionString: "postgres://x", Isolation: "db_per_tenant"}}
	fm := &fakeMounts{}
	rc := &Reconciler{Tenants: &fakeTenants{}, Perm: &fakePerm{}, Mounts: fm, Schemas: &fakeSchemas{}}

	res, err := rc.Reconcile(context.Background(), spec)
	if err != nil {
		t.Fatalf("Reconcile error: %v", err)
	}
	m := statusFor(res.Resources, "mount")
	if m.Status != StatusUnsupported {
		t.Errorf("db_per_tenant mount status = %q, want unsupported", m.Status)
	}
	if fm.calls != 0 {
		t.Error("unsupported isolation must NOT call the mount client (no silent register)")
	}
	if res.Outcome != OutcomePartial {
		t.Errorf("outcome = %q, want partial (unsupported is surfaced)", res.Outcome)
	}
}

func TestReconcileAdvisoryLockBusyReturns409Signal(t *testing.T) {
	rc := &Reconciler{Tenants: &fakeTenants{}, Perm: &fakePerm{}, Lock: busyLocker{}}
	_, err := rc.Reconcile(context.Background(), baseSpec())
	if !errors.Is(err, ErrBusy) {
		t.Fatalf("err = %v, want ErrBusy", err)
	}
}

type busyLocker struct{}

func (busyLocker) TryLock(_ context.Context, _ string) (func(), bool, error) {
	return nil, false, nil
}

func TestReconcileNonUUIDOwnerSkipsAssign(t *testing.T) {
	spec := baseSpec()
	spec.OwnerUserID = "not-a-uuid"
	fp := &fakePerm{}
	rc := &Reconciler{Tenants: &fakeTenants{}, Perm: fp, Mounts: &fakeMounts{}, Schemas: &fakeSchemas{}}
	if _, err := rc.Reconcile(context.Background(), spec); err != nil {
		t.Fatalf("Reconcile error: %v", err)
	}
	if fp.assign != 0 {
		t.Error("non-UUID owner must not trigger a role assignment")
	}
	if fp.ensureRole != 1 {
		t.Error("role should still be ensured even without an assignable owner")
	}
}
