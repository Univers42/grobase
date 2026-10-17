package authz

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// maxBodyBytes caps every request body; a model or a 1000-tuple write fits in
// a fraction of it.
const maxBodyBytes = 1 << 20

// readBody reads the capped body and refuses an `app` / `app_id` field before
// anything else sees it: the app is the key's tenant, and a body that names one
// is either a mistake or an attempt to reach another app.
func readBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "request body unreadable or over 1 MiB")
		return nil, false
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(body, &keys); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "body must be a JSON object")
		return nil, false
	}
	for _, forbidden := range []string{"app", "app_id"} {
		if _, found := keys[forbidden]; found {
			httpx.WriteError(w, http.StatusBadRequest, "app_not_accepted",
				"the app is the API key's tenant; do not send '"+forbidden+"'")
			return nil, false
		}
	}
	return body, true
}

// decodeBody reads the body as JSON into dst, rejecting unknown fields.
func decodeBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	body, ok := readBody(w, r)
	if !ok {
		return false
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	err := dec.Decode(dst)
	if err == nil && dec.More() {
		err = errors.New("trailing data after the JSON value")
	}
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return false
	}
	return true
}
