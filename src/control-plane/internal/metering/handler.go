package metering

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Mount registers the metering read-back route onto the shared mux (B1c).
//
// This mirrors internal/webhooks/handler.go and internal/functriggers/handler.go
// EXACTLY: Go 1.22 net/http ServeMux "GET /v1/..." patterns with a {id} path
// param, and the SAME admin/self auth + tenant-scoping that GET /v1/tenants/{id}
// uses (tenants.tokenOrSelf): a control-plane service token authorises any
// tenant, otherwise the caller may only read its OWN tenant when a matching
// X-Baas-Tenant-Id / X-Tenant-Id header equals the {id} in the path.
//
// Read-only and purely additive: it queries public.tenant_usage (migration 040).
// No new flag gates the READ path — when metering is OFF the table is simply
// empty and the endpoint returns empty aggregates, so route addition changes no
// existing path (that IS the parity story). Adding the route never creates,
// emits, or schedules anything.
func Mount(mux *http.ServeMux, db *shared.Postgres, serviceToken string) {
	rt := &readRoutes{reader: &Reader{db: pgPool{db: db}}, serviceToken: serviceToken}
	mux.HandleFunc("GET /v1/tenants/{id}/usage", rt.usage)
}

type readRoutes struct {
	reader       *Reader
	serviceToken string
}

// usage returns the summed per-metric usage for one tenant over an optional
// [from,to) window, optionally narrowed to a single metric. Every byte of the
// response is derived from public.tenant_usage rows the SQL scoped to this
// tenant — the read NEVER trusts a self-reported total.
func (rt *readRoutes) usage(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}

	q := r.URL.Query()
	metric := strings.TrimSpace(q.Get("metric"))

	from, ok := parseWindowBound(w, q.Get("from"), "from")
	if !ok {
		return
	}
	to, ok := parseWindowBound(w, q.Get("to"), "to")
	if !ok {
		return
	}

	out, err := rt.reader.Aggregate(r.Context(), tenantID, metric, from, to)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

// tokenOrSelf authorises read of a tenant's usage by either a control-plane
// service token (admin) or a tenant-self assertion via X-Baas-Tenant-Id (a
// tenant reading its own usage) — byte-identical to tenants.routes.tokenOrSelf,
// which guards GET /v1/tenants/{id}. The self arm goes through
// shared.TenantSelfMatch: when TENANT_HEADER_IDENTITY_HMAC is set a forged
// header alone cannot authorize (a valid X-Baas-Identity-Auth signature over the
// asserted id is required); OFF (default) it is the unchanged `header == id`
// check. The ISOLATION guarantee is now enforced THREE ways: the optional HMAC
// at the edge, the edge id-match (a tenant can only ASK for its own id), and the
// SQL (tenant_id is always bound in the WHERE), atop the RLS policy on the table.
func (rt *readRoutes) tokenOrSelf(w http.ResponseWriter, r *http.Request, id string) bool {
	if shared.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	if shared.TenantSelfMatch(r, rt.serviceToken, id) {
		return true
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"service token or matching tenant header required")
	return false
}

// parseWindowBound parses an optional ?from / ?to value. An empty value is a
// valid "unbounded" side (zero time). A present value is accepted as either an
// RFC3339 timestamp or a unix-millisecond integer; anything else is a 400 so a
// malformed filter is never silently ignored.
func parseWindowBound(w http.ResponseWriter, raw, field string) (time.Time, bool) {
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
