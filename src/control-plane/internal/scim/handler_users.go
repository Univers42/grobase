package scim

import (
	"net/http"
	"strings"
)

// handler_users.go — the SCIM IdP read/create routes (POST, GET by id, GET
// list/filter). Split out of handler.go to keep each file at ≤5 funcs; behavior
// is byte-identical.

func (rt *routes) createUser(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	var in SCIMUser
	if err := decodeJSON(r, &in); err != nil {
		rt.scimErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.UserName) == "" {
		rt.scimErr(w, http.StatusBadRequest, "userName is required")
		return
	}
	out, err := rt.svc.CreateUser(r.Context(), b, in)
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	rt.writeSCIM(w, http.StatusCreated, out)
}

func (rt *routes) getUser(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.GetUser(r.Context(), b, r.PathValue("id"))
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	rt.writeSCIM(w, http.StatusOK, out)
}

func (rt *routes) listUsers(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	resources := []SCIMUser{}
	if userName, found := parseUserNameFilter(r.URL.Query().Get("filter")); found {
		u, hit, err := rt.svc.FindByUserName(r.Context(), b, userName)
		if err != nil {
			rt.scimErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if hit {
			resources = append(resources, u)
		}
	}
	rt.writeSCIM(w, http.StatusOK, ListResponse{
		Schemas:      []string{schemaListResponse},
		TotalResults: len(resources),
		StartIndex:   1,
		ItemsPerPage: len(resources),
		Resources:    resources,
	})
}
