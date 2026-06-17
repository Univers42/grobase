package orgs

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// provision_read.go — the read-side org-project handlers (list projects + usage
// rollup), companions to the write-side createProject in provision.go.

// listProjects returns the projects attached to an org.
func (rt *routes) listProjects(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapProjectRead); !ok {
		return
	}
	out, err := rt.svc.ListProjects(r.Context(), orgID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

// usage returns the per-org usage rollup over member projects (D1.5). It reads
// the read-only public.org_usage_rollup view (migration 044), which SUMs the
// per-project tenant_usage rows — per-project qty preserved, never re-metered.
func (rt *routes) usage(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapBillingRead); !ok {
		return
	}
	out, err := rt.svc.OrgUsageRollup(r.Context(), orgID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}
