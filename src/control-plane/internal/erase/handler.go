/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:42:59 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package erase

import (
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// Mount registers the admin hard-erase route onto the shared mux (Track-D D4.4):
//
//	POST /v1/tenants/{id}/erase   -> 200 {id, tenant_id, scope, rows_purged, ...}
//
// It requires a control-plane service token (mirroring backup.requireServiceToken
// — a hard-erase is the most destructive control-plane operation, never reachable
// by a tenant credential or a JWT). The tenant id is read from the path via
// r.PathValue("id") (Go 1.22 net/http mux, same as backup/metering/audit).
//
// FLAG-GATED OFF = PARITY: main.go calls Mount ONLY when HARD_ERASE_ENABLED is
// truthy. When the flag is OFF (the default) Mount is never called, so this route
// is not registered on the mux and a request 404s — byte-identical to today,
// where a teardown is SOFT-DELETE only (DELETE /v1/tenants/{id}). This is the
// exact discipline of backup.Mount / audit.Mount: additive, opt-in, zero
// baseline change; the proven-parity state is the route NOT existing.
//
// Hard-erase is MVP-scoped to the two destructible isolation models
// (schema_per_tenant, shared_rls); db_per_tenant and tenant_owned are rejected
// 400 "isolation not supported for hard-erase (deferred)" (ErrUnsupportedScope).
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/tenants/{id}/erase", rt.requireServiceToken(rt.erase))
}

type routes struct {
	svc          *Service
	serviceToken string
}

// requireServiceToken gates a handler behind the control-plane service token,
// byte-identical to backup.routes.requireServiceToken / tenants'
// requireServiceToken — hard-erase is a privileged control-plane operation.
func (rt *routes) requireServiceToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !serviceauth.VerifyServiceRequest(r, rt.serviceToken) {
			httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
			return
		}
		next(w, r)
	}
}

// erase PROVABLY destroys the tenant's data, then writes a tamper-evident D3
// audit receipt + an erasure_receipts row. The principal is recorded as
// "service" (the only authorized caller is a control-plane service token); a
// future signed-admin-identity header could refine requested_by.
func (rt *routes) erase(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	receipt, err := rt.svc.Erase(r.Context(), tenantID, "service")
	if rt.handleErr(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, receipt)
}

// handleErr maps the erase service's sentinel errors to HTTP status codes,
// mirroring backup.handleBackupErr. Returns true when an error was written.
//
//	ErrUnsupportedScope -> 400 (db_per_tenant / tenant_owned out of MVP scope)
//	ErrNoMount          -> 404 (no registered mount to erase)
//	anything else       -> 500
func (rt *routes) handleErr(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrUnsupportedScope):
		httpx.WriteError(w, http.StatusBadRequest, "scope_unsupported", ErrUnsupportedScope.Error())
	case errors.Is(err, ErrNoMount):
		httpx.WriteError(w, http.StatusNotFound, "not_found", ErrNoMount.Error())
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
