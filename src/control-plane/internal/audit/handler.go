package audit

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// Mount registers the tenant-facing audit API onto the shared mux (D3). The
// caller mounts this ONLY when TENANT_AUDIT_ENABLED is truthy (the parity gate),
// exactly like metering.Mount / backup.Mount / abuseguard.Mount. When OFF, none
// of these routes exist and a request 404s — byte-identical to today.
//
// Routes — all scoped to ONE tenant by {id} in the path, authorized by either a
// control-plane service token (admin) OR a matching X-Baas-Tenant-Id /
// X-Tenant-Id header (a tenant acting on its OWN audit log), the SAME
// admin/self pattern GET /v1/tenants/{id}/usage uses:
//
//	POST /v1/audit/tenants/{id}/events          append an event (seal a link)
//	GET  /v1/audit/tenants/{id}/events          query own events (seq order, ?from/&to/&limit)
//	GET  /v1/audit/tenants/{id}/export          portable bundle (events + verify summary)
//	GET  /v1/audit/tenants/{id}/verify          recompute chain, report first broken link
//
// The {id} in the path is re-bound in every SQL WHERE, so cross-tenant read /
// verify is impossible by construction (a tenant can only ASK for its own id at
// the edge, and the query is tenant-scoped underneath). Append is the privileged
// write the control plane makes when a tenant-affecting action occurs; a tenant
// can also self-append (header == path id) so a hosted tenant can record its own
// application-level audit events.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/audit/tenants/{id}/events", rt.append)
	mux.HandleFunc("GET /v1/audit/tenants/{id}/events", rt.query)
	mux.HandleFunc("GET /v1/audit/tenants/{id}/export", rt.export)
	mux.HandleFunc("GET /v1/audit/tenants/{id}/verify", rt.verify)
}

type routes struct {
	svc          *Service
	serviceToken string
}

// AppendRequest is the POST .../events body.
type AppendRequest struct {
	Actor   string          `json:"actor"`
	Action  string          `json:"action"`
	Target  string          `json:"target"`
	Payload json.RawMessage `json:"payload"`
}

func (rt *routes) append(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	var req AppendRequest
	if err := decodeJSON(r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	if strings.TrimSpace(req.Action) == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "action required")
		return
	}
	ev, err := rt.svc.Append(r.Context(), AppendInput{
		TenantID: tenantID,
		Actor:    req.Actor,
		Action:   req.Action,
		Target:   req.Target,
		Payload:  req.Payload,
	})
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, ev)
}

// QueryResponse is the GET .../events body — the tenant's events in chain order.
type QueryResponse struct {
	TenantID string  `json:"tenant_id"`
	Count    int     `json:"count"`
	Events   []Event `json:"events"`
}

func (rt *routes) query(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	from, to, limit, ok := rt.parseWindow(w, r)
	if !ok {
		return
	}
	events, err := rt.svc.List(r.Context(), tenantID, from, to, limit)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, QueryResponse{TenantID: tenantID, Count: len(events), Events: events})
}

// ExportBundle is the GET .../export body — a portable, self-verifiable audit
// bundle: every event PLUS the verify summary, so a consumer can re-run
// VerifyChain offline (the canonical form is the data itself).
type ExportBundle struct {
	Format     string       `json:"format"`
	TenantID   string       `json:"tenant_id"`
	ExportedAt time.Time    `json:"exported_at"`
	Count      int          `json:"count"`
	Verify     VerifyResult `json:"verify"`
	Events     []Event      `json:"events"`
}

func (rt *routes) export(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	events, err := rt.svc.List(r.Context(), tenantID, time.Time{}, time.Time{}, maxListLimit)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	bundle := ExportBundle{
		Format:     "grobase.audit.v1",
		TenantID:   tenantID,
		ExportedAt: time.Now().UTC(),
		Count:      len(events),
		Verify:     VerifyChain(tenantID, events),
		Events:     events,
	}
	w.Header().Set("Content-Disposition", "attachment; filename=\"audit-"+sanitize(tenantID)+".json\"")
	httpx.WriteJSON(w, http.StatusOK, bundle)
}

// verify recomputes the tenant's chain and returns 200 whether intact or broken —
// the CALLER acts on res.Intact / res.BrokenSeq. A broken chain is a successful
// verification that REPORTS tampering, not a server error (the gate's load-bearing
// REJECT asserts intact==false + broken_seq at the tampered link).
func (rt *routes) verify(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	res, err := rt.svc.Verify(r.Context(), tenantID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}
