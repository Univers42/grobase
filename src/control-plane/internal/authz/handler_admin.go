package authz

import (
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func (rt *routes) putModel(w http.ResponseWriter, r *http.Request) {
	app, ok := rt.app(w, r, ScopeWrite)
	if !ok {
		return
	}
	body, ok := readBody(w, r)
	if !ok {
		return
	}
	if err := rt.Svc.PutModel(r.Context(), app, body); err != nil {
		rt.fail(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (rt *routes) getModel(w http.ResponseWriter, r *http.Request) {
	app, ok := rt.app(w, r, ScopeWrite)
	if !ok {
		return
	}
	raw, err := rt.Svc.GetModel(r.Context(), app)
	if err != nil {
		if errors.Is(err, ErrNoModel) {
			httpx.WriteError(w, http.StatusNotFound, "no_model", "no model has been PUT for this app")
			return
		}
		rt.fail(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(raw)
}

func (rt *routes) postTuples(w http.ResponseWriter, r *http.Request) {
	app, ok := rt.app(w, r, ScopeWrite)
	if !ok {
		return
	}
	var req TuplesRequest
	if !decodeBody(w, r, &req) {
		return
	}
	changed, err := rt.Svc.ReplaceTuples(r.Context(), app, req)
	if err != nil {
		rt.fail(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"changed": changed})
}
