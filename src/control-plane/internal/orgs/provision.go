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
	pr, ok := rt.decodeProvisionRequest(w, r)
	if !ok {
		return
	}
	out, ok := rt.reconcileOrgProject(w, r, pr)
	if !ok {
		return
	}
	// (3) The ONE additive control-plane write: link the project to its org.
	rt.attachProvisioned(r, out, orgID)
	shared.WriteJSON(w, provision.HTTPStatus(out.Outcome, out.APIKey != nil), out)
}

// reconcileOrgProject runs the EXISTING reconciler — byte-identical to the
// /v1/provision call — and maps its error to the right status (ErrBusy -> 409,
// else 400). ok=false means a response was already written.
func (rt *routes) reconcileOrgProject(w http.ResponseWriter, r *http.Request,
	pr tenants.ProvisionRequest) (provision.ReconcileResult, bool) {
	out, err := rt.reconciler.Reconcile(r.Context(), pr.Compile())
	switch {
	case errors.Is(err, provision.ErrBusy):
		shared.WriteError(w, http.StatusConflict, "conflict", err.Error())
		return provision.ReconcileResult{}, false
	case err != nil:
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return provision.ReconcileResult{}, false
	}
	return out, true
}

// decodeProvisionRequest caps + decodes the body, converts the org request to the
// EXISTING declarative ProvisionRequest, and runs its Validate — no new
// provisioning shape, no new defaults. ok=false means a response was already
// written. The org route is a thin authorization wrapper over the same input
// contract /v1/provision uses.
func (rt *routes) decodeProvisionRequest(w http.ResponseWriter, r *http.Request) (tenants.ProvisionRequest, bool) {
	// Cap the body before decoding (DoS guard) — same centralized cap as
	// /v1/provision (the provision payload carries unbounded mount arrays).
	r.Body = http.MaxBytesReader(w, r.Body, provision.MaxRequestBodyBytes)
	var req CreateProjectRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return tenants.ProvisionRequest{}, false
	}
	pr := req.toProvisionRequest()
	if err := pr.Validate(); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return tenants.ProvisionRequest{}, false
	}
	return pr, true
}

// toProvisionRequest converts the org-scoped CreateProjectRequest into the
// EXISTING tenants.ProvisionRequest verbatim (same fields, same mount shape).
func (req CreateProjectRequest) toProvisionRequest() tenants.ProvisionRequest {
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
	return pr
}

// attachProvisioned stamps tenants.org_id for the freshly reconciled project. The
// data plane never reads this column, so this changes no request path. Logged, not
// fatal: a stamp failure leaves an org-less but otherwise valid project (better
// than failing a successful provision).
func (rt *routes) attachProvisioned(r *http.Request, out provision.ReconcileResult, orgID string) {
	if out.Tenant.Slug == "" {
		return
	}
	if aerr := rt.svc.AttachProjectToOrg(r.Context(), out.Tenant.Slug, orgID); aerr != nil {
		rt.svc.log.Warn("attach project to org failed (project provisioned org-less)",
			"org", orgID, "project", out.Tenant.Slug, "err", aerr)
	}
}
