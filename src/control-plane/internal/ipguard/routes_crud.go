/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   routes_crud.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:07 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:09 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package ipguard

import (
	"context"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// ListResponse is the GET .../ip-allowlist body.
type ListResponse struct {
	TenantID string `json:"tenant_id"`
	Count    int    `json:"count"`
	Rules    []Rule `json:"rules"`
}

// AddRequest is the POST .../ip-allowlist body.
type AddRequest struct {
	CIDR string `json:"cidr"`
	Note string `json:"note"`
}

// ── shared CRUD bodies (admin + self share the SAME tenant-bound calls) ────────

func (rt *routes) writeList(w http.ResponseWriter, ctx context.Context, tenantID string) {
	rules, err := rt.svc.List(ctx, tenantID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, ListResponse{TenantID: tenantID, Count: len(rules), Rules: rules})
}

func (rt *routes) doAdd(w http.ResponseWriter, r *http.Request, tenantID, actor string) {
	var req AddRequest
	if err := decodeJSON(r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	rule, err := rt.svc.Add(r.Context(), AddInput{TenantID: tenantID, CIDR: req.CIDR, Note: req.Note, CreatedBy: actor})
	if err != nil {
		if errors.Is(err, ErrBadCIDR) {
			httpx.WriteError(w, http.StatusBadRequest, "validation_error", "invalid cidr (want an IP or CIDR network, e.g. 10.0.0.0/8)")
			return
		}
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, rule)
}

func (rt *routes) doRemove(w http.ResponseWriter, ctx context.Context, tenantID, ruleID string) {
	removed, err := rt.svc.Remove(ctx, tenantID, ruleID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	if !removed {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "no such allowlist rule for this tenant")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// tokenOrSelf authorises a CRUD request by either a control-plane service token
// (admin, any tenant) or a matching X-Baas-Tenant-Id / X-Tenant-Id header (a
// tenant acting on its OWN id) — byte-identical to audit.routes.tokenOrSelf.
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
