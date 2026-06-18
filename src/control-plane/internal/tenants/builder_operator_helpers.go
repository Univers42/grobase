package tenants

import (
	"net/http"
	"strings"

	ent "github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// buildOperatorRecord validates the optional ceiling + status and assembles the
// entitlement record. ok=false means a 400 was written.
func (b *builderAPI) buildOperatorRecord(w http.ResponseWriter, slug string, req operatorEntitlementRequest) (ent.Record, bool) {
	ceiling, ok := b.optionalCeiling(w, req.CeilingPlan)
	if !ok {
		return ent.Record{}, false
	}
	status, ok := normalizeEntitlementStatus(w, req.Status)
	if !ok {
		return ent.Record{}, false
	}
	return ent.Record{TenantID: slug, Entitlement: req.Entitlement, CeilingPlan: ceiling, Status: status}, true
}

// operatorEntitlementResponse projects an upserted operator record into the
// response body.
func operatorEntitlementResponse(rec ent.Record) map[string]any {
	return map[string]any{
		"tenant_id":    rec.TenantID,
		"ceiling_plan": rec.CeilingPlan,
		"status":       rec.Status,
		"entitlement":  rec.Entitlement,
	}
}

// optionalCeiling trims an OPTIONAL ceiling_plan and validates it against the
// manifest when present (empty is allowed). ok=false means a 400 was written.
func (b *builderAPI) optionalCeiling(w http.ResponseWriter, raw string) (string, bool) {
	ceiling := strings.TrimSpace(raw)
	if ceiling != "" && !b.knownPlan(ceiling) {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error",
			"unknown ceiling_plan "+ceiling+" (not in package manifest)")
		return "", false
	}
	return ceiling, true
}

// normalizeEntitlementStatus defaults an empty status to "active" and rejects
// anything other than active/draft. ok=false means a 400 was written.
func normalizeEntitlementStatus(w http.ResponseWriter, raw string) (string, bool) {
	status := strings.TrimSpace(raw)
	if status == "" {
		status = "active"
	}
	if status != "active" && status != "draft" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "status must be active or draft")
		return "", false
	}
	return status, true
}
