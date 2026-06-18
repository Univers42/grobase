package scim

import "net/http"

// handler_users_mutations.go — the SCIM IdP mutate routes (PUT replace, PATCH,
// DELETE). Split out of handler.go to keep each file at ≤5 funcs; behavior is
// byte-identical.

func (rt *routes) replaceUser(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	var in SCIMUser
	if err := decodeJSON(r, &in); err != nil {
		rt.scimErr(w, http.StatusBadRequest, err.Error())
		return
	}
	out, err := rt.svc.ReplaceUser(r.Context(), b, r.PathValue("id"), in)
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	rt.writeSCIM(w, http.StatusOK, out)
}

func (rt *routes) patchUser(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	var p PatchOp
	if err := decodeJSON(r, &p); err != nil {
		rt.scimErr(w, http.StatusBadRequest, err.Error())
		return
	}
	out, err := rt.svc.PatchUser(r.Context(), b, r.PathValue("id"), p)
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	rt.writeSCIM(w, http.StatusOK, out)
}

func (rt *routes) deleteUser(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	if err := rt.svc.DeleteUser(r.Context(), b, r.PathValue("id")); err != nil {
		rt.mapErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
