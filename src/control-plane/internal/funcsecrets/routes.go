/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   routes.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:44:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:44:01 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package funcsecrets

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// Mount registers the tenant-facing CRUD routes.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/function-secrets", rt.set)
	mux.HandleFunc("GET /v1/function-secrets", rt.list)
	mux.HandleFunc("DELETE /v1/function-secrets/{key}", rt.remove)
	mux.HandleFunc("GET /internal/v1/function-secrets/resolve", rt.resolve)
}

type routes struct {
	svc          *Service
	serviceToken string
}

func (rt *routes) set(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
	if !ok {
		return
	}
	var req SetRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	meta, err := rt.svc.Set(r.Context(), tenantID, req)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, meta)
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.List(r.Context(), tenantID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) remove(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
	if !ok {
		return
	}
	fn := r.URL.Query().Get("function_name")
	err := rt.svc.Delete(r.Context(), tenantID, fn, r.PathValue("key"))
	switch {
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "function secret not found")
	case err != nil:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	default:
		httpx.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
	}
}
