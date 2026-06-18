package ipguard

import (
	"encoding/json"
	"net/http"
	"strings"
)

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

// decodeJSON reads a JSON body with a small cap (allowlist ops are tiny control
// messages).
func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 16<<10))
	return dec.Decode(v)
}
