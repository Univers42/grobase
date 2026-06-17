package provision

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Handle decodes a StackSpec, validates, reconciles and writes the mapped HTTP
// response. It is the single request→reconcile→status seam, reused by both the
// standalone Mount below and the tenants-package delegation (so route ownership
// stays in one place — see tenants.Mount). Returns nothing; it owns the
// ResponseWriter.
func Handle(ctx context.Context, w http.ResponseWriter, body json.RawMessage, rc *Reconciler) {
	var spec StackSpec
	if err := json.Unmarshal(body, &spec); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return
	}
	spec.Normalize()
	if err := spec.Validate(); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	out, err := rc.Reconcile(ctx, spec)
	switch {
	case errors.Is(err, ErrBusy):
		shared.WriteError(w, http.StatusConflict, "conflict", err.Error())
		return
	case err != nil:
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	shared.WriteJSON(w, HTTPStatus(out.Outcome, out.APIKey != nil), out)
}

// Mount wires POST /v1/provision onto mux, service-token gated. tenant-control
// keeps route ownership in tenants.Mount to avoid a duplicate registration, so
// this standalone Mount is provided for callers that want the seam on its own
// mux (and is exercised by the handler tests).
func Mount(mux *http.ServeMux, rc *Reconciler, serviceToken string) {
	mux.HandleFunc("POST /v1/provision", func(w http.ResponseWriter, r *http.Request) {
		if !shared.VerifyServiceRequest(r, serviceToken) {
			shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
			return
		}
		body, err := readBody(w, r)
		if err != nil {
			shared.WriteError(w, http.StatusBadRequest, "bad_request", "invalid body")
			return
		}
		Handle(r.Context(), w, body, rc)
	})
}

// readBody decodes the request body under a hard size cap (MaxBytesReader), so
// an oversized/streamed payload is rejected before it can exhaust memory (DoS
// guard). The cap is the centralized MaxRequestBodyBytes.
func readBody(w http.ResponseWriter, r *http.Request) (json.RawMessage, error) {
	r.Body = http.MaxBytesReader(w, r.Body, MaxRequestBodyBytes)
	var raw json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&raw); err != nil {
		return nil, err
	}
	return raw, nil
}
