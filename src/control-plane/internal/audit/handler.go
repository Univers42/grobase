package audit

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
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
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	if strings.TrimSpace(req.Action) == "" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "action required")
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
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusCreated, ev)
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
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, QueryResponse{TenantID: tenantID, Count: len(events), Events: events})
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
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
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
	shared.WriteJSON(w, http.StatusOK, bundle)
}

func (rt *routes) verify(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	res, err := rt.svc.Verify(r.Context(), tenantID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	// 200 whether intact or broken — the CALLER acts on res.Intact / res.BrokenSeq.
	// A broken chain is a successful verification that REPORTS tampering, not a
	// server error (the gate's load-bearing REJECT asserts intact==false +
	// broken_seq at the tampered link).
	shared.WriteJSON(w, http.StatusOK, res)
}

// tokenOrSelf authorises by either a control-plane service token (admin, any
// tenant) or a matching X-Baas-Tenant-Id / X-Tenant-Id header (a tenant acting
// on its OWN id) — byte-identical to metering.readRoutes.tokenOrSelf. The
// isolation guarantee is enforced twice: here at the edge (a tenant can only ASK
// for its own id) and again in the SQL (tenant_id is always bound), atop the RLS
// policy on tenant_audit_log.
func (rt *routes) tokenOrSelf(w http.ResponseWriter, r *http.Request, id string) bool {
	if shared.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	if id != "" && (r.Header.Get("X-Baas-Tenant-Id") == id || r.Header.Get("X-Tenant-Id") == id) {
		return true
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"service token or matching tenant header required")
	return false
}

// parseWindow reads the optional ?from / ?to (RFC3339 or unix-ms) and ?limit.
func (rt *routes) parseWindow(w http.ResponseWriter, r *http.Request) (time.Time, time.Time, int, bool) {
	q := r.URL.Query()
	from, ok := parseBound(w, q.Get("from"), "from")
	if !ok {
		return time.Time{}, time.Time{}, 0, false
	}
	to, ok := parseBound(w, q.Get("to"), "to")
	if !ok {
		return time.Time{}, time.Time{}, 0, false
	}
	limit := 0
	if raw := strings.TrimSpace(q.Get("limit")); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 0 {
			shared.WriteError(w, http.StatusBadRequest, "validation_error", "invalid limit")
			return time.Time{}, time.Time{}, 0, false
		}
		limit = n
	}
	return from, to, limit, true
}

// parseBound parses an optional ?from / ?to value (empty = unbounded side).
func parseBound(w http.ResponseWriter, raw, field string) (time.Time, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return time.Time{}, true
	}
	if t, err := time.Parse(time.RFC3339, raw); err == nil {
		return t.UTC(), true
	}
	if ms, err := strconv.ParseInt(raw, 10, 64); err == nil && ms >= 0 {
		return time.UnixMilli(ms).UTC(), true
	}
	shared.WriteError(w, http.StatusBadRequest, "validation_error",
		"invalid "+field+": want RFC3339 or unix-ms")
	return time.Time{}, false
}

// decodeJSON reads a JSON body with a small cap (audit events are tiny control
// messages). Unlike abuseguard it does NOT DisallowUnknownFields — a forward
// API client may send extra keys; we only consume the ones we name.
func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 64<<10))
	return dec.Decode(v)
}

// sanitize trims a tenant id to a filename-safe token for Content-Disposition.
func sanitize(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			b.WriteRune(r)
		default:
			b.WriteRune('_')
		}
	}
	if b.Len() == 0 {
		return "tenant"
	}
	return b.String()
}
