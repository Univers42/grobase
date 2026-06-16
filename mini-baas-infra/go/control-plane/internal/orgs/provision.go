package orgs

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// provision.go — D1.4: org-scoped project provisioning. The heart of the
// no-rewrite discipline. It does NOT reimplement provisioning; it AUTHORIZES
// (RBAC capability gate), then DELEGATES to the EXISTING reconciler verbatim, and
// finally stamps tenants.org_id (the one additive write).
//
// The provisioned project is an ordinary tenant: the StackSpec, the reconciler,
// the per-mount ABAC seeding, and the RequestIdentity the resulting project's
// data requests carry are all unchanged. The data plane cannot tell the project
// belongs to an org — THAT is the parity guarantee (m103 arm C2 proves it).

// createProject provisions a project (=tenant) owned by an org. The ONLY
// differences from POST /v1/provision are (1) the capability gate before the
// call and (2) the org_id stamp after it.
func (rt *routes) createProject(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")

	// (1) LOAD-BEARING REJECT: a role lacking project:create (e.g. viewer) → 403,
	// and a non-member → 404 (cross-org isolation). Checked BEFORE any reconcile.
	if _, _, ok := rt.requireCapability(w, r, orgID, CapProjectCreate); !ok {
		return
	}
	if rt.reconciler == nil {
		shared.WriteError(w, http.StatusNotImplemented, "not_implemented",
			"org-scoped provisioning requires a reconciler (ADAPTER_REGISTRY_URL / data plane wiring)")
		return
	}

	// Cap the body before decoding (DoS guard) — same centralized cap as
	// /v1/provision (the provision payload carries unbounded mount arrays).
	r.Body = http.MaxBytesReader(w, r.Body, provision.MaxRequestBodyBytes)
	var req CreateProjectRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}

	// Convert to the EXISTING declarative ProvisionRequest and reuse its Validate
	// + Compile — no new provisioning shape, no new defaults. The org route is a
	// thin authorization wrapper over the same input contract /v1/provision uses.
	pr := tenants.ProvisionRequest{
		Tenant:          req.Tenant,
		Name:            req.Name,
		Plan:            req.Plan,
		OwnerUserID:     req.OwnerUserID,
		DefaultRoleName: req.DefaultRoleName,
		DefaultKeyName:  req.DefaultKeyName,
		SeedRoles:       req.SeedRoles,
	}
	for _, m := range req.Mounts {
		pr.Mounts = append(pr.Mounts, tenants.MountSpec{
			Engine:           m.Engine,
			Name:             m.Name,
			ConnectionString: m.ConnectionString,
			Isolation:        m.Isolation,
		})
	}
	if err := pr.Validate(); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}

	// (2) THE EXISTING RECONCILER — byte-identical to the /v1/provision call.
	out, err := rt.reconciler.Reconcile(r.Context(), pr.Compile())
	switch {
	case errors.Is(err, provision.ErrBusy):
		shared.WriteError(w, http.StatusConflict, "conflict", err.Error())
		return
	case err != nil:
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}

	// (3) The ONE additive control-plane write: link the project to its org. The
	// data plane never reads this column, so this changes no request path. Logged,
	// not fatal: a stamp failure leaves an org-less but otherwise valid project
	// (better than failing a successful provision).
	if out.Tenant.Slug != "" {
		if aerr := rt.svc.AttachProjectToOrg(r.Context(), out.Tenant.Slug, orgID); aerr != nil {
			rt.svc.log.Warn("attach project to org failed (project provisioned org-less)",
				"org", orgID, "project", out.Tenant.Slug, "err", aerr)
		}
	}

	shared.WriteJSON(w, provision.HTTPStatus(out.Outcome, out.APIKey != nil), out)
}

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
