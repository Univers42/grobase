/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handlers.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:40:57 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:40:58 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package branching

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

const msgInvalidJSON = "invalid JSON"

// createBranchRequest is the POST body. name is REQUIRED (the branch label,
// validated to a safe [a-z0-9_] identifier); mount narrows the isolation lookup
// (empty = whole-tenant first mount).
type createBranchRequest struct {
	Name  string `json:"name"`
	Mount string `json:"mount"`
}

// createBranch clones a schema_per_tenant mount into a fresh branch schema and
// records a row in public.tenant_branches. Returns 201 with the branch row. A
// deferred isolation model is rejected 400, an invalid branch name 400, a
// duplicate name 409 — all BEFORE any clone work for the rejects.
func (rt *routes) createBranch(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req createBranchRequest
	if r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
			return
		}
	}
	row, err := rt.svc.CreateBranch(r.Context(), id, strings.TrimSpace(req.Mount), req.Name)
	if rt.handleErr(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, row)
}

// listBranches returns the tenant's branch rows, newest first.
func (rt *routes) listBranches(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.ListBranches(r.Context(), r.PathValue("id"))
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// dropBranch drops the {branchId} branch belonging to {id}. The service validates
// (load-bearing) the branch row's tenant_id matches {id} BEFORE dropping anything:
// a mismatch (or unknown id) yields ErrNotFound -> 404, so a caller can never drop
// another tenant's branch even if it guessed the id.
func (rt *routes) dropBranch(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	branchID := r.PathValue("branchId")
	if err := rt.svc.DropBranch(r.Context(), id, branchID); err != nil {
		if rt.handleErr(w, err) {
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}
