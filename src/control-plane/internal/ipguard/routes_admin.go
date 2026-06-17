package ipguard

import (
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// CheckRequest is the POST /v1/ipguard/check body — what an edge plugin sends.
type CheckRequest struct {
	TenantID string `json:"tenant_id"`
	IP       string `json:"ip"`
}

// check is the EDGE decision. Service-token only (an internal plugin/gateway
// calls it, never a tenant directly). It returns 200 + {allow:true/false}; the
// EDGE acts on `allow` (forward vs 403). A 200 with allow=false is a successful
// decision that REPORTS a block, not a server error — the gate's load-bearing
// REJECT asserts allow==false for an out-of-range IP.
func (rt *routes) check(w http.ResponseWriter, r *http.Request) {
	if !shared.VerifyServiceRequest(r, rt.serviceToken) {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
		return
	}
	var req CheckRequest
	if err := decodeJSON(r, &req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	// The edge passes the resolved client IP explicitly; if it instead forwards
	// the raw X-Forwarded-For chain we take the LEFT-MOST entry (the original
	// client), the same convention an ip-restriction plugin uses.
	ip := strings.TrimSpace(req.IP)
	if ip == "" {
		ip = clientIPFromHeaders(r)
	}
	dec, err := rt.svc.Allowed(r.Context(), req.TenantID, ip)
	if err != nil {
		writeCheckError(w, err)
		return
	}
	shared.WriteJSON(w, http.StatusOK, dec)
}

// writeCheckError maps an edge-check service error to its HTTP status.
func writeCheckError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrEmptyTenant):
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "tenant_id required")
	case errors.Is(err, ErrBadIP):
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "invalid client IP")
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	rt.writeList(w, r.Context(), tenantID)
}

func (rt *routes) add(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	rt.doAdd(w, r, tenantID, actorFromRequest(r))
}

func (rt *routes) remove(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	rt.doRemove(w, r.Context(), tenantID, r.PathValue("ruleId"))
}
