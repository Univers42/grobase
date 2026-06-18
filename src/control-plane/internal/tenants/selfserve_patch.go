package tenants

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// patchRequest is the PATCH /v1/tenants/me body. Only `plan` is self-service;
// name/status/metadata are admin-only and deliberately NOT exposed here.
type patchRequest struct {
	Plan string `json:"plan"`
}

// patch changes the caller's own plan to another manifest tier. [scope: admin]
//
// The new plan must exist in the package manifest (a direct package key OR a
// legacy alias) — an unknown plan is a 400 rather than a silent downgrade. When
// BILLING_ENABLED is set we also reflect the new plan into
// public.tenant_billing.plan so the billing map stays consistent.
func (ss *selfServe) patch(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !ss.requireScope(w, scopes, "admin") {
		return
	}
	plan, ok := ss.decodePlan(w, r)
	if !ok {
		return
	}
	t, err := ss.svc.Update(r.Context(), tenantID, UpdateTenantRequest{Plan: &plan})
	if ss.handleLookup(w, err) {
		return
	}
	if ss.billing {
		ss.syncBillingPlan(r, tenantID, plan)
	}
	pkgName, _ := ss.manifest.For(t.Plan)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"tenant":  meTenant{ID: t.ID, UUID: t.UUID, Slug: t.ID, Name: t.Name, Plan: t.Plan, Status: t.Status},
		"package": pkgName,
	})
}

// decodePlan decodes and validates the requested plan. For() falls back to the
// default package for an unknown plan, so we check membership EXPLICITLY (direct
// key or legacy alias) instead of trusting For() to reject — otherwise "garbage"
// would silently resolve to the default tier. ok=false means a 400 was written.
func (ss *selfServe) decodePlan(w http.ResponseWriter, r *http.Request) (string, bool) {
	var req patchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return "", false
	}
	plan := strings.TrimSpace(req.Plan)
	if plan == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "plan is required")
		return "", false
	}
	if !ss.knownPlan(plan) {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error",
			"unknown plan "+plan+" (not in package manifest)")
		return "", false
	}
	return plan, true
}

// syncBillingPlan keeps the billing map's plan column in sync. Best-effort: a
// failure does not roll back the tenant plan change (the tenants row is the
// source of truth for entitlements); it is logged via the service logger.
//
// TODO(B4b): the LIVE Stripe subscription update (swapping the customer's
// subscription item to the new price) is a SEPARATE flag-gated step and is
// intentionally NOT performed here in B4a — this only updates the local
// tenant->plan map; no external Stripe call is made.
func (ss *selfServe) syncBillingPlan(r *http.Request, tenantID, plan string) {
	if err := ss.svc.updateBillingPlan(r.Context(), tenantID, plan); err != nil {
		ss.svc.log.Warn("tenant_billing plan sync failed (continuing)", "tenant", tenantID, "err", err)
	}
}

// knownPlan reports whether plan is a real manifest tier (direct package key or
// a legacy alias) — used to reject an unknown plan instead of letting For()
// silently fall back to the default package.
func (ss *selfServe) knownPlan(plan string) bool {
	if _, ok := ss.manifest.Packages[plan]; ok {
		return true
	}
	if alias, ok := ss.manifest.Aliases[plan]; ok {
		if _, ok := ss.manifest.Packages[alias]; ok {
			return true
		}
	}
	return false
}

// handleLookup maps a service lookup error to the right status, mirroring
// routes.handleLookup so the /me surface returns the same error shapes.
func (ss *selfServe) handleLookup(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "tenant not found")
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
