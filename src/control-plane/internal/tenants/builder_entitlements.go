package tenants

import (
	"encoding/json"
	"net/http"

	ent "github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
)

// entitlementsResponse is the GET /me/entitlements body: the stored custom
// entitlement (or empty), the ceiling, and the effective package preview.
type entitlementsResponse struct {
	TenantID    string                `json:"tenant_id"`
	Plan        string                `json:"plan"`
	CeilingPlan string                `json:"ceiling_plan"`
	Status      string                `json:"status"`
	Custom      ent.CustomEntitlement `json:"custom"`
	Effective   effectiveView         `json:"effective"`
}

// effectiveView is the clamped EFFECTIVE package projected for the tenant — the
// same shape the data plane is stamped with, plus the raw capability_overrides
// mask (the load-bearing artifact a tenant/operator can diff against the tier).
type effectiveView struct {
	Package             string          `json:"package"`
	Engines             []string        `json:"engines"`
	Capabilities        map[string]bool `json:"capabilities"`
	Limits              packages.Limits `json:"limits"`
	MaxMounts           int             `json:"max_mounts"`
	Addons              []string        `json:"addons"`
	SecurityMode        string          `json:"security_mode"`
	CapabilityOverrides map[string]any  `json:"capability_overrides"`
}

// effectiveFor clamps the custom entitlement to the ceiling and projects the
// effective view (the SAME Clamp the resolver applies at /connect time).
func (b *builderAPI) effectiveFor(custom ent.CustomEntitlement, ceiling packages.Package, ceilingName string) effectiveView {
	eff := packages.Clamp(custom.ToPackage(), ceiling)
	return effectiveView{
		Package:             ceilingName,
		Engines:             eff.Engines,
		Capabilities:        eff.Capabilities,
		Limits:              eff.Limits,
		MaxMounts:           eff.PoolPolicy.MaxMounts,
		Addons:              eff.Addons,
		SecurityMode:        eff.SecurityMode,
		CapabilityOverrides: eff.CapabilityOverrides(),
	}
}

// getEntitlements returns the caller's stored custom entitlement + the effective
// (clamped) package. [scope: read]
func (b *builderAPI) getEntitlements(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := b.selfAuthScope(w, r, "read")
	if !ok {
		return
	}
	t, err := b.ss.svc.FindOne(r.Context(), tenantID)
	if b.ss.handleLookup(w, err) {
		return
	}
	rec := b.loadOrEmpty(r.Context(), tenantID)
	ceiling, ceilingName := b.ceilingFor(r.Context(), tenantID, t.Plan)
	httpx.WriteJSON(w, http.StatusOK, b.entitlementsResponse(tenantID, t.Plan, rec, ceiling, ceilingName))
}

// entitlementsResponse projects a stored record + ceiling into the GET/PATCH
// response body (the clamped effective package alongside the raw custom row).
func (b *builderAPI) entitlementsResponse(tenantID, plan string, rec ent.Record, ceiling packages.Package, ceilingName string) entitlementsResponse {
	return entitlementsResponse{
		TenantID:    tenantID,
		Plan:        plan,
		CeilingPlan: rec.CeilingPlan,
		Status:      rec.Status,
		Custom:      rec.Entitlement,
		Effective:   b.effectiveFor(rec.Entitlement, ceiling, ceilingName),
	}
}

// patchEntitlements is the COMPOSE-time gate. A tenant submits a custom
// entitlement; ValidateWithin checks it against the ceiling and rejects an
// over-ceiling request with 403 entitlement_exceeds_ceiling BEFORE persisting.
// Within-ceiling requests are UPSERT'd. The resolve-time Clamp is still the
// backstop — but this gives the tenant a clean, immediate error. [scope: admin]
func (b *builderAPI) patchEntitlements(w http.ResponseWriter, r *http.Request) {
	tenantID, custom, ok := b.authPatchEntitlement(w, r)
	if !ok {
		return
	}
	t, err := b.ss.svc.FindOne(r.Context(), tenantID)
	if b.ss.handleLookup(w, err) {
		return
	}
	ceiling, ceilingName := b.ceilingFor(r.Context(), tenantID, t.Plan)
	// COMPOSE-time privilege-boundary gate: a clean 403 naming the offending axis.
	if vErr := packages.ValidateWithin(custom.ToPackage(), ceiling); vErr != nil {
		httpx.WriteError(w, http.StatusForbidden, "entitlement_exceeds_ceiling", vErr.Error())
		return
	}
	rec, ok := b.persistEntitlement(w, r, tenantID, custom)
	if !ok {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, b.entitlementsResponse(tenantID, t.Plan, rec, ceiling, ceilingName))
}

// authPatchEntitlement self-auths, requires admin scope (composing the backend
// is an account-admin action like PATCH /me {plan}, so a read/write-only key
// cannot widen the entitlement), and decodes the custom entitlement body.
// ok=false means a 401/403/400 was already written.
func (b *builderAPI) authPatchEntitlement(w http.ResponseWriter, r *http.Request) (string, ent.CustomEntitlement, bool) {
	tenantID, scopes, ok := b.ss.selfAuth(w, r)
	if !ok {
		return "", ent.CustomEntitlement{}, false
	}
	if !b.ss.requireScope(w, scopes, "admin") {
		return "", ent.CustomEntitlement{}, false
	}
	var custom ent.CustomEntitlement
	if err := json.NewDecoder(r.Body).Decode(&custom); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return "", ent.CustomEntitlement{}, false
	}
	return tenantID, custom, true
}
