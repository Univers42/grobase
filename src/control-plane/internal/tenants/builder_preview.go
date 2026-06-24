/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   builder_preview.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:58:32 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:58:33 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"encoding/json"
	"net/http"

	ent "github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
)

// previewRequest is the POST /me/builder body: a hypothetical custom entitlement
// the tenant wants to preview WITHOUT persisting.
type previewRequest struct {
	Entitlement ent.CustomEntitlement `json:"entitlement"`
}

// previewResponse returns the effective (clamped) package + any compose-time
// violations + the mount budget (max_mounts vs how many the tenant already has).
type previewResponse struct {
	TenantID    string        `json:"tenant_id"`
	Plan        string        `json:"plan"`
	CeilingPlan string        `json:"ceiling_plan"`
	Effective   effectiveView `json:"effective"`
	Violations  []string      `json:"violations"`
	MountBudget mountBudget   `json:"mount_budget"`
}

// persistEntitlement upserts a within-ceiling custom entitlement, preserving the
// operator's ceiling_plan (loadOrEmpty keeps it). A tenant may NEVER set its own
// ceiling_plan — it is never read from the request body. ok=false means a 500
// was written.
func (b *builderAPI) persistEntitlement(w http.ResponseWriter, r *http.Request, tenantID string, custom ent.CustomEntitlement) (ent.Record, bool) {
	rec := b.loadOrEmpty(r.Context(), tenantID)
	rec.TenantID = tenantID
	rec.Entitlement = custom
	rec.Status = "active"
	if err := b.store.Upsert(r.Context(), rec); err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return ent.Record{}, false
	}
	return rec, true
}

// preview is a DRY-RUN: it clamps the submitted entitlement to the ceiling and
// returns the effective package, the compose-time violations (what ValidateWithin
// would reject), and the mount budget — WITHOUT writing anything. [scope: read]
func (b *builderAPI) preview(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := b.selfAuthScope(w, r, "read")
	if !ok {
		return
	}
	var req previewRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	t, err := b.ss.svc.FindOne(r.Context(), tenantID)
	if b.ss.handleLookup(w, err) {
		return
	}
	ceiling, ceilingName := b.ceilingFor(r.Context(), tenantID, t.Plan)
	eff := b.effectiveFor(req.Entitlement, ceiling, ceilingName)
	httpx.WriteJSON(w, http.StatusOK, previewResponse{
		TenantID:    tenantID,
		Plan:        t.Plan,
		CeilingPlan: ceilingName,
		Effective:   eff,
		Violations:  validationViolations(req.Entitlement, ceiling),
		MountBudget: b.mountBudget(r, tenantID, eff.MaxMounts),
	})
}

// validationViolations returns the compose-time violations (what ValidateWithin
// would reject) as a non-nil slice.
func validationViolations(custom ent.CustomEntitlement, ceiling packages.Package) []string {
	violations := []string{}
	if vErr := packages.ValidateWithin(custom.ToPackage(), ceiling); vErr != nil {
		violations = append(violations, vErr.Error())
	}
	return violations
}

// knownPlan reports whether plan is a real manifest tier (direct key or alias),
// mirroring selfServe.knownPlan so an unknown ceiling_plan is rejected rather
// than silently resolving to the default tier.
func (b *builderAPI) knownPlan(plan string) bool {
	if _, ok := b.manifest.Packages[plan]; ok {
		return true
	}
	if alias, ok := b.manifest.Aliases[plan]; ok {
		if _, ok := b.manifest.Packages[alias]; ok {
			return true
		}
	}
	return false
}
