package scim

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
)

// handler_helpers.go — the SCIM HTTP encode/decode + error-mapping helpers.
// Split out of handler.go to keep each file at ≤5 funcs; behavior is
// byte-identical.

// parseUserNameFilter extracts x from a SCIM filter of the form
//
//	userName eq "x"
//
// (the only filter an IdP needs for the existence check before create). Returns
// found=false for any other/absent filter (an unsupported filter yields an empty
// ListResponse rather than an error, which IdPs tolerate).
func parseUserNameFilter(filter string) (userName string, found bool) {
	f := strings.TrimSpace(filter)
	low := strings.ToLower(f)
	if !strings.HasPrefix(low, "username") {
		return "", false
	}
	rest := strings.TrimSpace(f[len("username"):])
	lowRest := strings.ToLower(rest)
	if !strings.HasPrefix(lowRest, "eq") {
		return "", false
	}
	val := strings.TrimSpace(rest[len("eq"):])
	val = strings.Trim(val, `"`)
	if val == "" {
		return "", false
	}
	return val, true
}

// mapErr maps service errors to SCIM error responses. ErrNotFound => 404 (the
// wall: a cross-tenant id is "not found"). ErrNoOrg => 400. Anything else => 500.
func (rt *routes) mapErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		rt.scimErr(w, http.StatusNotFound, "resource not found")
	case errors.Is(err, ErrNoOrg):
		rt.scimErr(w, http.StatusBadRequest, "SCIM token is not bound to an org; set org_id when issuing the token")
	default:
		rt.scimErr(w, http.StatusInternalServerError, err.Error())
	}
}

// writeSCIM emits a resource/list with the SCIM content type.
func (rt *routes) writeSCIM(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", contentTypeSCIM)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// scimErr emits a SCIM Error envelope (status as a STRING, per RFC 7644 §3.12).
func (rt *routes) scimErr(w http.ResponseWriter, status int, detail string) {
	w.Header().Set("Content-Type", contentTypeSCIM)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(scimError{
		Schemas: []string{schemaError},
		Detail:  detail,
		Status:  strconv.Itoa(status),
	})
}

// decodeJSON reads a JSON body with a sane size cap (mirrors passkeys.decodeJSON).
func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	return dec.Decode(v)
}
