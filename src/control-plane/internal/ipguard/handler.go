package ipguard

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// keyResolver maps a tenant API key (cleartext) → its owning tenant, for the
// self-serve CRUD path. *tenants.Service satisfies it via VerifyKey (the
// single-source verifier). Passing the interface (not the concrete type) keeps
// ipguard fakeable in tests; tenants does NOT import ipguard, so there is no
// import cycle. A nil resolver disables only the self-serve routes (the edge
// check + admin CRUD still work). This mirrors backup.keyResolver exactly.
type keyResolver interface {
	VerifyKey(ctx context.Context, raw string) (tenants.VerifyKeyResponse, error)
}

// Mount registers the IP-allowlist edge-check + admin CRUD onto the shared mux
// (D2e). The caller mounts this ONLY when TENANT_IP_ALLOWLIST_ENABLED is truthy
// (the parity gate), exactly like audit.Mount / abuseguard.Mount. When OFF, none
// of these routes exist and a request 404s — byte-identical to today.
//
// Routes:
//
//	POST   /v1/ipguard/check                     edge decision (service-token only)
//	GET    /v1/tenants/{id}/ip-allowlist         list a tenant's rules (admin or self header)
//	POST   /v1/tenants/{id}/ip-allowlist         add a rule       (admin or self header)
//	DELETE /v1/tenants/{id}/ip-allowlist/{ruleId} remove a rule   (admin or self header)
//
// The {id} in every CRUD route is re-bound in the SQL WHERE, so a tenant can
// never read or mutate another tenant's allowlist (it can only ASK for its own id
// at the edge, and the query is tenant-scoped underneath), atop the RLS policy on
// tenant_ip_allowlist.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/ipguard/check", rt.check)
	mux.HandleFunc("GET /v1/tenants/{id}/ip-allowlist", rt.list)
	mux.HandleFunc("POST /v1/tenants/{id}/ip-allowlist", rt.add)
	mux.HandleFunc("DELETE /v1/tenants/{id}/ip-allowlist/{ruleId}", rt.remove)
}

// MountSelfServe registers the credential-resolved self-serve allowlist routes
// (/v1/tenants/me/ip-allowlist). The caller mounts this ONLY when the feature
// flag (and, by main.go's choice, TENANT_SELFSERVE_ENABLED) is truthy. resolver
// maps a tenant API key → its owning tenant; there is NO path id, so cross-tenant
// access is impossible by construction (the key resolves to exactly one tenant).
func MountSelfServe(mux *http.ServeMux, svc *Service, resolver keyResolver) {
	rt := &routes{svc: svc, resolver: resolver}
	mux.HandleFunc("GET /v1/tenants/me/ip-allowlist", rt.meList)
	mux.HandleFunc("POST /v1/tenants/me/ip-allowlist", rt.meAdd)
	mux.HandleFunc("DELETE /v1/tenants/me/ip-allowlist/{ruleId}", rt.meRemove)
}

type routes struct {
	svc          *Service
	serviceToken string
	resolver     keyResolver
}

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
		switch {
		case errors.Is(err, ErrEmptyTenant):
			shared.WriteError(w, http.StatusBadRequest, "validation_error", "tenant_id required")
		case errors.Is(err, ErrBadIP):
			shared.WriteError(w, http.StatusBadRequest, "validation_error", "invalid client IP")
		default:
			shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		}
		return
	}
	shared.WriteJSON(w, http.StatusOK, dec)
}

// ListResponse is the GET .../ip-allowlist body.
type ListResponse struct {
	TenantID string `json:"tenant_id"`
	Count    int    `json:"count"`
	Rules    []Rule `json:"rules"`
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	rt.writeList(w, r.Context(), tenantID)
}

// AddRequest is the POST .../ip-allowlist body.
type AddRequest struct {
	CIDR string `json:"cidr"`
	Note string `json:"note"`
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

// ── self-serve (/v1/tenants/me/ip-allowlist) — credential-resolved tenant ──────

func (rt *routes) meList(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := rt.selfTenant(w, r)
	if !ok {
		return
	}
	rt.writeList(w, r.Context(), tenantID)
}

func (rt *routes) meAdd(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := rt.selfTenant(w, r)
	if !ok {
		return
	}
	rt.doAdd(w, r, tenantID, "api-key")
}

func (rt *routes) meRemove(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := rt.selfTenant(w, r)
	if !ok {
		return
	}
	rt.doRemove(w, r.Context(), tenantID, r.PathValue("ruleId"))
}

// ── shared CRUD bodies (admin + self share the SAME tenant-bound calls) ────────

func (rt *routes) writeList(w http.ResponseWriter, ctx context.Context, tenantID string) {
	rules, err := rt.svc.List(ctx, tenantID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, ListResponse{TenantID: tenantID, Count: len(rules), Rules: rules})
}

func (rt *routes) doAdd(w http.ResponseWriter, r *http.Request, tenantID, actor string) {
	var req AddRequest
	if err := decodeJSON(r, &req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	rule, err := rt.svc.Add(r.Context(), AddInput{TenantID: tenantID, CIDR: req.CIDR, Note: req.Note, CreatedBy: actor})
	if err != nil {
		if errors.Is(err, ErrBadCIDR) {
			shared.WriteError(w, http.StatusBadRequest, "validation_error", "invalid cidr (want an IP or CIDR network, e.g. 10.0.0.0/8)")
			return
		}
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusCreated, rule)
}

func (rt *routes) doRemove(w http.ResponseWriter, ctx context.Context, tenantID, ruleID string) {
	removed, err := rt.svc.Remove(ctx, tenantID, ruleID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	if !removed {
		shared.WriteError(w, http.StatusNotFound, "not_found", "no such allowlist rule for this tenant")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// tokenOrSelf authorises a CRUD request by either a control-plane service token
// (admin, any tenant) or a matching X-Baas-Tenant-Id / X-Tenant-Id header (a
// tenant acting on its OWN id) — byte-identical to audit.routes.tokenOrSelf.
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

// selfTenant resolves the caller's OWN tenant from a tenant API key (X-API-Key
// or Authorization: Bearer mbk_...). There is no path id, so the key is the ONLY
// tenant a request can touch. A nil resolver (not wired) ⇒ 501.
func (rt *routes) selfTenant(w http.ResponseWriter, r *http.Request) (string, bool) {
	if rt.resolver == nil {
		shared.WriteError(w, http.StatusNotImplemented, "not_configured", "self-serve allowlist not configured")
		return "", false
	}
	raw := shared.APIKeyFromRequest(r)
	if raw == "" {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
			"X-API-Key or Authorization: Bearer <api-key> required")
		return "", false
	}
	out, err := rt.resolver.VerifyKey(r.Context(), raw)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return "", false
	}
	if !out.Valid || out.TenantID == "" {
		shared.WriteError(w, http.StatusUnauthorized, "invalid_key", "API key is not valid")
		return "", false
	}
	return out.TenantID, true
}

// clientIPFromHeaders extracts the original client IP from the forwarded chain
// the edge stamps: the LEFT-MOST X-Forwarded-For entry (the original client),
// then X-Real-IP, then the direct peer. This is the same convention an
// ip-restriction plugin uses when no explicit IP is supplied in the body.
func clientIPFromHeaders(r *http.Request) string {
	if xff := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); xff != "" {
		if i := strings.IndexByte(xff, ','); i >= 0 {
			return strings.TrimSpace(xff[:i])
		}
		return xff
	}
	if xr := strings.TrimSpace(r.Header.Get("X-Real-IP")); xr != "" {
		return xr
	}
	host := r.RemoteAddr
	if i := strings.LastIndexByte(host, ':'); i >= 0 {
		host = host[:i]
	}
	return strings.TrimSpace(host)
}

// actorFromRequest records WHO added a rule for the audit `created_by` column.
func actorFromRequest(r *http.Request) string {
	if t := r.Header.Get("X-Baas-Tenant-Id"); t != "" {
		return "self:" + t
	}
	if t := r.Header.Get("X-Tenant-Id"); t != "" {
		return "self:" + t
	}
	return "admin"
}

// apiKeyFromRequest extracts a tenant API key from X-API-Key or from an
// `Authorization: Bearer mbk_...` header (mirrors tenants.apiKeyFromRequest). A
// JWT Bearer (no mbk_ prefix) is left untouched so the two never collide.

// decodeJSON reads a JSON body with a small cap (allowlist ops are tiny control
// messages).
func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 16<<10))
	return dec.Decode(v)
}
