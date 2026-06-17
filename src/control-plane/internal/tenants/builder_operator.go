package tenants

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	ent "github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// operatorCeilingRequest sets a per-tenant ceiling_plan (a sales deal). The
// operator IS the ceiling authority, so this is NOT clamped to the tenant's plan.
type operatorCeilingRequest struct {
	CeilingPlan string `json:"ceiling_plan"`
}

// operatorEntitlementRequest mints a custom entitlement for a tenant WITHOUT the
// self-serve clamp (the operator is the ceiling authority). It may also set the
// ceiling_plan in the same call (the deal + its envelope together).
type operatorEntitlementRequest struct {
	CeilingPlan string                `json:"ceiling_plan"`
	Status      string                `json:"status"`
	Entitlement ent.CustomEntitlement `json:"entitlement"`
}

// operatorSetCeiling raises/sets a tenant's ceiling_plan above its named tier
// (a custom deal). Service-token gated; the operator bypasses the self-serve
// clamp on WRITE. The resolve-time Clamp still applies on READ (so the EFFECTIVE
// package is clamped to THIS ceiling, never higher). [auth: service token]
func (b *builderAPI) operatorSetCeiling(w http.ResponseWriter, r *http.Request) {
	slug, ok := b.operatorSlug(w, r)
	if !ok {
		return
	}
	var req operatorCeilingRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	ceiling, ok := b.requireCeiling(w, req.CeilingPlan)
	if !ok {
		return
	}
	if !b.requireTenantExists(w, r, slug) {
		return
	}
	if err := b.store.SetCeiling(r.Context(), slug, ceiling); err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"tenant_id": slug, "ceiling_plan": ceiling})
}

// requireCeiling trims a REQUIRED ceiling_plan and validates it against the
// manifest. ok=false means a 400 was written.
func (b *builderAPI) requireCeiling(w http.ResponseWriter, raw string) (string, bool) {
	ceiling := strings.TrimSpace(raw)
	if ceiling == "" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "ceiling_plan is required")
		return "", false
	}
	if !b.knownPlan(ceiling) {
		shared.WriteError(w, http.StatusBadRequest, "validation_error",
			"unknown ceiling_plan "+ceiling+" (not in package manifest)")
		return "", false
	}
	return ceiling, true
}

// operatorSlug gates an operator route on the service token and returns the path
// {id}. ok=false means a 401 was already written.
func (b *builderAPI) operatorSlug(w http.ResponseWriter, r *http.Request) (string, bool) {
	if !b.validServiceToken(r) {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
		return "", false
	}
	return r.PathValue("id"), true
}

// requireTenantExists verifies the tenant exists (a write on a missing tenant is
// a no-op trap). ok=false means a 404/500 was already written.
func (b *builderAPI) requireTenantExists(w http.ResponseWriter, r *http.Request, slug string) bool {
	_, err := b.ss.svc.FindOne(r.Context(), slug)
	if err == nil {
		return true
	}
	if errors.Is(err, ErrNotFound) {
		shared.WriteError(w, http.StatusNotFound, "not_found", "tenant not found")
		return false
	}
	shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	return false
}

// operatorUpsertEntitlement mints/replaces a tenant's custom entitlement (+
// optional ceiling_plan) WITHOUT ValidateWithin — the operator may write a row
// the tenant could not. The resolve-time Clamp still bounds the EFFECTIVE package
// to the (operator-set) ceiling, so even the operator's row can never make the
// stamp exceed the ceiling it itself declares. [auth: service token]
func (b *builderAPI) operatorUpsertEntitlement(w http.ResponseWriter, r *http.Request) {
	slug, ok := b.operatorSlug(w, r)
	if !ok {
		return
	}
	var req operatorEntitlementRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if !b.requireTenantExists(w, r, slug) {
		return
	}
	rec, ok := b.buildOperatorRecord(w, slug, req)
	if !ok {
		return
	}
	if err := b.store.Upsert(r.Context(), rec); err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, operatorEntitlementResponse(rec))
}
