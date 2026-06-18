package audit

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// tokenOrSelf authorises by either a control-plane service token (admin, any
// tenant) or a matching X-Baas-Tenant-Id / X-Tenant-Id header (a tenant acting
// on its OWN id) — byte-identical to metering.readRoutes.tokenOrSelf. The
// isolation guarantee is enforced twice: here at the edge (a tenant can only ASK
// for its own id) and again in the SQL (tenant_id is always bound), atop the RLS
// policy on tenant_audit_log.
func (rt *routes) tokenOrSelf(w http.ResponseWriter, r *http.Request, id string) bool {
	if serviceauth.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	if id != "" && (r.Header.Get("X-Baas-Tenant-Id") == id || r.Header.Get("X-Tenant-Id") == id) {
		return true
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
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
			httpx.WriteError(w, http.StatusBadRequest, "validation_error", "invalid limit")
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
	httpx.WriteError(w, http.StatusBadRequest, "validation_error",
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
